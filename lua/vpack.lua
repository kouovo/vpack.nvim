local M = {}

local config = require("vpack.config")
local state = require("vpack.state")
local actions = require("vpack.ui.actions")
local updates = require("vpack.backend.updates")
local render = require("vpack.ui.render")
local window = require("vpack.ui.window")
local uv = vim.uv or vim.loop

local augroup = vim.api.nvim_create_augroup("vpack.events", { clear = true })

M.config = config.values

local UPDATE_PREVIEW_LIMIT = 5
local CHECK_REFRESH_DEBOUNCE_MS = 50
local SPINNER_INTERVAL_MS = 100
local PROGRESS_TTL_MS = 1600

local refresh_timer
local spinner_timer
local progress_timer
local auto_check_pending = false

local function sync_cursor_from_window()
  local win = window.get_win()
  if win and vim.api.nvim_win_is_valid(win) then
    local cursor = vim.api.nvim_win_get_cursor(win)
    state.set_cursor(cursor[1])
  end
end

local function has_spinner_activity()
  local snapshot = state.get()

  if snapshot.progress and snapshot.progress.status == "running" then
    return true
  end

  for _, item in ipairs(snapshot.items or {}) do
    if item.operation_info and item.operation_info.kind == "update" and item.operation_info.status == "updating" then
      return true
    end

    if item.update_info and item.update_info.status == "checking" then
      return true
    end
  end

  return false
end

local function cancel_progress_timer()
  if progress_timer then
    progress_timer:stop()
    progress_timer:close()
    progress_timer = nil
  end
end

local function schedule_progress_clear(progress)
  cancel_progress_timer()

  progress = progress or state.get_progress()
  if not progress then
    return
  end

  local created_at = progress.created_at
  progress_timer = uv.new_timer()
  progress_timer:start(PROGRESS_TTL_MS, 0, function()
    cancel_progress_timer()

    vim.schedule(function()
      local current = state.get_progress()
      if not current or current.created_at ~= created_at then
        return
      end

      state.clear_progress()
      M.render()
    end)
  end)
end

local function format_check_summary(summary)
  summary = summary or {}

  if (summary.total or 0) == 0 then
    return "no loaded packages"
  end

  local parts = {}
  if (summary.available or 0) > 0 then
    table.insert(parts, string.format("%d available", summary.available))
  end
  if (summary.current or 0) > 0 then
    table.insert(parts, string.format("%d up to date", summary.current))
  end
  if (summary.unsupported or 0) > 0 then
    table.insert(parts, string.format("%d no upstream", summary.unsupported))
  end
  if (summary.error or 0) > 0 then
    table.insert(parts, string.format("%d failed", summary.error))
  end

  if vim.tbl_isempty(parts) then
    return string.format("%d checked", summary.total)
  end

  return table.concat(parts, ", ")
end

local function update_check_progress(message)
  local snapshot = state.get()
  local total = 0
  local done = 0
  local current_item

  for _, item in ipairs(snapshot.items or {}) do
    if item.active then
      local info = item.update_info
      total = total + 1

      if info and info.status ~= "queued" and info.status ~= "checking" then
        done = done + 1
      elseif info and info.status == "checking" and not current_item then
        current_item = item.short_name or item.name
      end
    end
  end

  state.update_progress({
    message = message or "Checking updates",
    done = done,
    total = total,
    current_item = current_item,
  })
end

local function stop_spinner()
  if spinner_timer then
    spinner_timer:stop()
    spinner_timer:close()
    spinner_timer = nil
  end
end

local function ensure_spinner()
  if not window.is_valid() or not has_spinner_activity() then
    stop_spinner()
    return
  end

  if spinner_timer then
    return
  end

  spinner_timer = uv.new_timer()
  spinner_timer:start(SPINNER_INTERVAL_MS, SPINNER_INTERVAL_MS, function()
    vim.schedule(function()
      if not window.is_valid() or not has_spinner_activity() then
        stop_spinner()
        return
      end

      sync_cursor_from_window()
      state.tick_spinner()
      M.render()
    end)
  end)
end

local function schedule_check_refresh()
  if refresh_timer then
    return
  end

  refresh_timer = uv.new_timer()
  refresh_timer:start(CHECK_REFRESH_DEBOUNCE_MS, 0, function()
    local timer = refresh_timer
    refresh_timer = nil
    if timer then
      timer:stop()
      timer:close()
    end

    vim.schedule(function()
      if not window.is_valid() then
        return
      end

      sync_cursor_from_window()
      state.refresh()
      if state.get_progress() and state.get_progress().kind == "check" and state.get_progress().status == "running" then
        update_check_progress()
      end
      M.render()
    end)
  end)
end

---@param opts table?
function M.setup(opts)
  M.config = config.setup(opts)
  M.setup_autocmds()
  return M.config
end

function M.open()
  state.refresh()

  local view = window.open(M.config.window)
  M.render()
  actions.attach(view.buf)

  auto_check_pending = true
  vim.schedule(function()
    if auto_check_pending and window.is_valid() then
      auto_check_pending = false
      M.check_updates()
    end
  end)

  local line_count = vim.api.nvim_buf_line_count(view.buf)
  local row = math.min(math.max(1, state.get_cursor()), line_count)
  vim.api.nvim_win_set_cursor(view.win, { row, 0 })

  return view
end

function M.render()
  if not window.is_valid() then
    return
  end

  local buf = window.get_buf()
  local win = window.get_win()

  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  render.render(buf, state.get())
  ensure_spinner()

  if win and vim.api.nvim_win_is_valid(win) then
    local line_count = vim.api.nvim_buf_line_count(buf)
    local row = math.min(math.max(1, state.get_cursor()), line_count)
    vim.api.nvim_win_set_cursor(win, { row, 0 })
  end
end

function M.refresh(opts)
  opts = opts or {}
  state.refresh()

  if opts.mark_current then
    state.mark_updates_current(opts.mark_current)
  end

  M.render()

  if opts.check ~= false then
    M.check_updates()
  end

  return state.get()
end

function M.check_updates(opts)
  opts = opts or {}
  auto_check_pending = false

  local loaded = vim
    .iter(state.get().items)
    :filter(function(item)
      return item.active
    end)
    :totable()

  local started = updates.check_loaded(loaded, {
    force = opts.force,
    max_commits = UPDATE_PREVIEW_LIMIT,
    timeout_ms = opts.timeout_ms,
    on_change = function()
      schedule_check_refresh()
    end,
    on_complete = function(summary)
      M.finish_check_progress(summary)
      if opts.on_complete then
        opts.on_complete(summary)
      end
    end,
  }) or 0

  if started > 0 and window.is_valid() then
    cancel_progress_timer()
    state.set_progress("check", {
      status = "running",
      message = "Checking updates",
      done = 0,
      total = #loaded,
    })
    sync_cursor_from_window()
    state.refresh()
    update_check_progress()
    M.render()
  end

  return started
end

function M.finish_check_progress(summary)
  if not state.get_progress() or state.get_progress().kind ~= "check" then
    return
  end

  state.update_progress({
    status = (summary and (summary.error or 0) > 0) and "error" or "done",
    message = "Check complete",
    done = summary and summary.total or state.get_progress().total or 0,
    total = summary and summary.total or state.get_progress().total or 0,
    current_item = nil,
    summary = format_check_summary(summary),
  })
  M.render()
  schedule_progress_clear(state.get_progress())
end

function M.on_pack_changed()
  vim.schedule(function()
    if window.is_valid() then
      M.refresh()
    end
  end)
end

function M.setup_autocmds()
  if M._autocmds_registered then
    return
  end

  vim.api.nvim_create_autocmd("PackChanged", {
    group = augroup,
    callback = function()
      M.on_pack_changed()
    end,
  })

  M._autocmds_registered = true
end

function M.close()
  stop_spinner()
  cancel_progress_timer()
  auto_check_pending = false
  if refresh_timer then
    refresh_timer:stop()
    refresh_timer:close()
    refresh_timer = nil
  end
  updates.reset()
  window.close()
  state.reset()
end

return M
