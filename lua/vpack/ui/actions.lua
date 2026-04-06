local M = {}

local backend = require("vpack.backend.pack")
local state = require("vpack.state")

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "vpack" })
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

function M.close()
  require("vpack").close()
end

function M.refresh()
  require("vpack").refresh()
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

  backend.update(current.name)
  notify(string.format("Updating %s", current.name))
  require("vpack").refresh()
end

function M.update_all()
  backend.update_all()
  notify("Updating all packages")
  require("vpack").refresh()
end

function M.delete_current()
  sync_cursor_from_window()

  local current = state.peek_current()
  if not current then
    notify("No package selected", vim.log.levels.WARN)
    return
  end

  backend.delete(current.name)
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

  backend.clean(names)
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
  map(buf, "u", M.update_current, "Update package")
  map(buf, "U", M.update_all, "Update all packages")
  map(buf, "d", M.delete_current, "Delete package")
  map(buf, "X", M.clean, "Clean non-active packages")
  map(buf, "l", M.show_log, "Show pack log")
end

return M
