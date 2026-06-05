local M = {}

local backend = require("vpack.backend.pack")
local state = require("vpack.state")
local uv = vim.uv or vim.loop

local FINISHED_STATUS_TTL_MS = 1200
local FINISHED_PROGRESS_TTL_MS = 1600
local operation_timers = {}
local progress_timer

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "vpack" })
end

local function try_backend(action, on_error)
  local ok, err = pcall(action)
  if ok then
    return true
  end

  notify(on_error(err), vim.log.levels.ERROR)
  return false
end

local function map(buf, lhs, rhs, desc)
  vim.keymap.set("n", lhs, rhs, {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = desc,
  })
end

local function sync_cursor_from_window()
  local window = require("vpack.ui.window")
  local win = window.get_win()

  if win and vim.api.nvim_win_is_valid(win) then
    local cursor = vim.api.nvim_win_get_cursor(win)
    state.set_cursor(cursor[1])
  end
end

local function render_current_view()
  require("vpack").render()
end

local function cancel_progress_timer()
  if progress_timer then
    progress_timer:stop()
    progress_timer:close()
    progress_timer = nil
  end
end

local function schedule_progress_clear(generation)
  cancel_progress_timer()

  local progress = state.get_progress()
  if not progress then
    return
  end

  local created_at = progress.created_at
  progress_timer = uv.new_timer()
  progress_timer:start(FINISHED_PROGRESS_TTL_MS, 0, function()
    cancel_progress_timer()

    vim.schedule(function()
      if generation ~= state.get_generation() then
        return
      end

      local current = state.get_progress()
      if not current or current.created_at ~= created_at then
        return
      end

      state.clear_progress()
      render_current_view()
    end)
  end)
end

local function cancel_operation_timer(name)
  local timer = operation_timers[name]
  if timer then
    timer:stop()
    timer:close()
    operation_timers[name] = nil
  end
end

local function schedule_operation_clear(names, generation)
  for _, name in ipairs(names or {}) do
    cancel_operation_timer(name)

    local timer = uv.new_timer()
    operation_timers[name] = timer
    timer:start(FINISHED_STATUS_TTL_MS, 0, function()
      cancel_operation_timer(name)
      vim.schedule(function()
        if generation ~= state.get_generation() then
          return
        end

        state.set_operation({ name }, nil)
        render_current_view()
      end)
    end)
  end
end

local function split_result_names(requested, changed, failed)
  local changed_lookup = {}
  local failed_lookup = {}
  local changed_names = changed or requested or {}
  local failed_names = {}

  for name, message in pairs(failed or {}) do
    failed_lookup[name] = message or true
    table.insert(failed_names, name)
  end

  for _, name in ipairs(changed_names) do
    changed_lookup[name] = true
  end

  local unchanged = {}
  for _, name in ipairs(requested or {}) do
    if not changed_lookup[name] and not failed_lookup[name] then
      table.insert(unchanged, name)
    end
  end

  return changed_names, unchanged, failed_names, failed_lookup
end

local function format_check_summary(summary)
  summary = summary or {}

  if (summary.total or 0) == 0 then
    return "Check complete: no loaded packages"
  end

  local parts = {}

  if (summary.available or 0) > 0 then
    local label = summary.available == 1 and "update" or "updates"
    table.insert(parts, string.format("%d %s available", summary.available, label))
  end

  if (summary.current or 0) > 0 then
    table.insert(parts, string.format("%d up-to-date", summary.current))
  end

  if (summary.unsupported or 0) > 0 then
    table.insert(parts, string.format("%d unsupported", summary.unsupported))
  end

  if (summary.error or 0) > 0 then
    local label = string.format("%d failed", summary.error)
    if (summary.timed_out or 0) > 0 then
      label = string.format("%s (%d timed out)", label, summary.timed_out)
    end
    table.insert(parts, label)
  end

  if vim.tbl_isempty(parts) then
    return string.format("Check complete: %d checked", summary.total)
  end

  return "Check complete: " .. table.concat(parts, ", ")
end

local function collect_available_updates(items)
  local available = {}
  local missing_checks = false
  local checks_running = false

  for _, item in ipairs(items or {}) do
    if item.active then
      local info = item.update_info

      if info and info.status == "available" then
        table.insert(available, item.name)
      elseif not info then
        missing_checks = true
      elseif info.status == "queued" or info.status == "checking" then
        checks_running = true
      end
    end
  end

  return available, missing_checks, checks_running
end

local function on_async_update_complete(result, names, success_message, error_message, generation)
  vim.schedule(function()
    if generation ~= state.get_generation() then
      return
    end

    if result and result.ok then
      local changed_names, unchanged_names, failed_names, failed_lookup =
        split_result_names(names, result.changed_names, result.failed_names)

      if not vim.tbl_isempty(changed_names) then
        state.set_operation(changed_names, {
          kind = "update",
          status = "updated",
        })
        schedule_operation_clear(changed_names, generation)
      end

      if not vim.tbl_isempty(unchanged_names) then
        state.set_operation(unchanged_names, {
          kind = "update",
          status = "no_changes",
        })
        schedule_operation_clear(unchanged_names, generation)
      end

      if not vim.tbl_isempty(failed_names) then
        for _, name in ipairs(failed_names) do
          state.set_operation({ name }, {
            kind = "update",
            status = "error",
            message = failed_lookup[name],
          })
        end
        schedule_operation_clear(failed_names, generation)
      end

      if not vim.tbl_isempty(failed_names) then
        notify("Some package updates failed", vim.log.levels.WARN)
      else
        notify(vim.tbl_isempty(changed_names) and "No package changes found" or success_message)
      end
      state.update_progress({
        status = vim.tbl_isempty(failed_names) and "done" or "error",
        message = vim.tbl_isempty(failed_names) and success_message or "Update finished with errors",
        done = #(names or {}),
        total = #(names or {}),
        current_item = nil,
        summary = vim.tbl_isempty(failed_names)
            and string.format("%d package%s processed", #(names or {}), #(names or {}) == 1 and "" or "s")
          or string.format("%d failed", #failed_names),
      })
      schedule_progress_clear(generation)
      require("vpack").refresh({ check = false })
      require("vpack").check_updates({ force = true })
      return
    end

    state.update_progress({
      status = "error",
      message = error_message,
      done = #(names or {}),
      total = #(names or {}),
      current_item = nil,
      summary = result and result.error or nil,
    })
    schedule_progress_clear(generation)
    state.set_operation(names, {
      kind = "update",
      status = "error",
      message = result and result.error or error_message,
    })
    schedule_operation_clear(names, generation)
    render_current_view()
    notify(error_message .. (result and result.error and (": " .. result.error) or ""), vim.log.levels.ERROR)
  end)
end

function M.close()
  require("vpack").close()
end

function M.refresh()
  require("vpack").refresh()
end

function M.check_updates()
  sync_cursor_from_window()

  local loaded = vim
    .iter(state.get().items)
    :filter(function(item)
      return item.active
    end)
    :totable()

  if vim.tbl_isempty(loaded) then
    notify("No loaded packages to check")
    return
  end

  local started = require("vpack").check_updates({
    force = true,
    manual = true,
    on_complete = function(summary)
      notify(format_check_summary(summary), (summary.error or 0) > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
    end,
  })

  if started == 0 then
    notify("Loaded package checks are already in progress")
    return
  end

  notify("Checking loaded packages")
end

function M.toggle_details()
  sync_cursor_from_window()
  state.toggle_details()
  require("vpack").render()
end

function M.update_current()
  sync_cursor_from_window()

  local current = state.peek_current()
  if not current then
    notify("No package selected", vim.log.levels.WARN)
    return
  end

  local operation = state.get_operation(current.name)
  if operation and operation.kind == "update" and operation.status == "updating" then
    notify(string.format("%s is already updating", current.name), vim.log.levels.INFO)
    return
  end

  local generation = state.get_generation()

  state.set_operation({ current.name }, {
    kind = "update",
    status = "updating",
  })
  cancel_progress_timer()
  state.set_progress("update", {
    status = "running",
    message = string.format("Updating %s", current.short_name or current.name),
    done = 0,
    total = 1,
    current_item = current.short_name or current.name,
  })
  render_current_view()
  notify(string.format("Updating %s", current.name))

  if type(backend.update_async) == "function" then
    backend.update_async(current.name, function(result)
      on_async_update_complete(
        result,
        { current.name },
        string.format("Updated %s", current.name),
        string.format("Failed to update %s", current.name),
        generation
      )
    end)
    return
  end

  local ok = try_backend(function()
    backend.update(current.name)
  end, function(err)
    return string.format("Failed to update %s: %s", current.name, err)
  end)

  if ok then
    state.set_operation({ current.name }, {
      kind = "update",
      status = "updated",
    })
    state.update_progress({
      status = "done",
      message = string.format("Updated %s", current.short_name or current.name),
      done = 1,
      total = 1,
      current_item = nil,
    })
    schedule_progress_clear(generation)
    require("vpack").refresh({ check = false })
    require("vpack").check_updates({ force = true })
  else
    state.update_progress({
      status = "error",
      message = string.format("Failed to update %s", current.short_name or current.name),
      done = 1,
      total = 1,
      current_item = nil,
    })
    schedule_progress_clear(generation)
    state.set_operation({ current.name }, nil)
    render_current_view()
  end
end

function M.update_all()
  local names, missing_checks, checks_running = collect_available_updates(state.get().items)

  if state.has_active_operation("update") then
    notify("An update is already running", vim.log.levels.INFO)
    return
  end

  if vim.tbl_isempty(names) then
    if checks_running then
      notify("Update checks are still running", vim.log.levels.INFO)
      return
    end

    if missing_checks then
      notify("Checking updates before update all", vim.log.levels.INFO)
      local started = require("vpack").check_updates({
        force = true,
        manual = true,
        on_complete = function()
          vim.schedule(M.update_all)
        end,
      })

      if started == 0 then
        notify("Loaded package checks are already in progress", vim.log.levels.INFO)
      end

      return
    end

    if vim.tbl_isempty(names) then
      notify("No updates available", vim.log.levels.INFO)
      return
    end
  end

  local generation = state.get_generation()

  if not vim.tbl_isempty(names) then
    state.set_operation(names, {
      kind = "update",
      status = "updating",
    })
  end

  cancel_progress_timer()
  state.set_progress("update", {
    status = "running",
    message = string.format("Updating %d available package%s", #names, #names == 1 and "" or "s"),
    done = 0,
    total = #names,
  })

  render_current_view()
  notify(string.format("Updating %d available package%s", #names, #names == 1 and "" or "s"))

  if type(backend.update_all_async) == "function" then
    backend.update_all_async(function(result)
      on_async_update_complete(result, names, "Updated all packages", "Failed to update packages", generation)
    end, names)
    return
  end

  local ok = try_backend(function()
    backend.update_all(names)
  end, function(err)
    return string.format("Failed to update packages: %s", err)
  end)

  if ok then
    state.set_operation(names, {
      kind = "update",
      status = "updated",
    })
    state.update_progress({
      status = "done",
      message = "Updated all packages",
      done = #names,
      total = #names,
      current_item = nil,
    })
    schedule_progress_clear(generation)
    require("vpack").refresh({ check = false })
    require("vpack").check_updates({ force = true })
  else
    state.update_progress({
      status = "error",
      message = "Failed to update packages",
      done = #names,
      total = #names,
      current_item = nil,
    })
    schedule_progress_clear(generation)
    state.set_operation(names, nil)
    render_current_view()
  end
end

function M.delete_current()
  sync_cursor_from_window()

  local current = state.peek_current()
  if not current then
    notify("No package selected", vim.log.levels.WARN)
    return
  end

  if current.active then
    notify(string.format("Cannot delete active package %s", current.name), vim.log.levels.WARN)
    return
  end

  local ok = try_backend(function()
    backend.delete(current.name)
  end, function(err)
    return string.format("Failed to delete %s: %s", current.name, err)
  end)

  if not ok then
    return
  end

  notify(string.format("Deleted %s", current.name))
  require("vpack").refresh()
end

function M.clean()
  local names = vim
    .iter(state.get().items)
    :filter(function(item)
      return not item.active
    end)
    :map(function(item)
      return item.name
    end)
    :totable()

  if vim.tbl_isempty(names) then
    notify("No inactive packages to clean", vim.log.levels.INFO)
    return
  end

  local ok = try_backend(function()
    backend.clean(names)
  end, function(err)
    return string.format("Failed to clean packages: %s", err)
  end)

  if not ok then
    return
  end

  notify(string.format("Cleaned %d packages", #names))
  require("vpack").refresh()
end

function M.show_log()
  local view = require("vpack.ui.log").open(require("vpack").config.log)

  if not view then
    notify("nvim-pack.log not found", vim.log.levels.WARN)
    return nil
  end

  return view
end

function M.attach(buf)
  if vim.b[buf].vpack_actions_attached then
    return
  end

  vim.b[buf].vpack_actions_attached = true

  map(buf, "q", M.close, "Close vpack")
  map(buf, "<CR>", M.toggle_details, "Toggle details")
  map(buf, "r", M.refresh, "Refresh vpack")
  map(buf, "c", M.check_updates, "Check package updates")
  map(buf, "u", M.update_current, "Update package")
  map(buf, "U", M.update_all, "Update all packages")
  map(buf, "d", M.delete_current, "Delete package")
  map(buf, "X", M.clean, "Clean non-active packages")
  map(buf, "l", M.show_log, "Show pack log")
end

return M
