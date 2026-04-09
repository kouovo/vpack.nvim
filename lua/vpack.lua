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
local CHECK_REFRESH_DEBOUNCE_MS = 20
local SPINNER_INTERVAL_MS = 100

local refresh_timer
local spinner_timer

local function sync_cursor_from_window()
  local win = window.get_win()
  if win and vim.api.nvim_win_is_valid(win) then
    local cursor = vim.api.nvim_win_get_cursor(win)
    state.set_cursor(cursor[1])
  end
end

local function has_spinner_activity()
  local snapshot = state.get()

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
  M.check_updates()

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

function M.refresh()
  state.refresh()

  M.render()
  M.check_updates()

  return state.get()
end

function M.check_updates(opts)
  opts = opts or {}

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
    on_complete = opts.on_complete,
  }) or 0

  if started > 0 and window.is_valid() then
    sync_cursor_from_window()
    state.refresh()
    M.render()
  end

  return started
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
