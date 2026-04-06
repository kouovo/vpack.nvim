local M = {}

local config = require("vpack.config")
local state = require("vpack.state")
local actions = require("vpack.ui.actions")
local render = require("vpack.ui.render")
local window = require("vpack.ui.window")

local augroup = vim.api.nvim_create_augroup("vpack.events", { clear = true })

M.config = config.values

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
  vim.api.nvim_win_set_cursor(view.win, { state.get_cursor(), 0 })

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

  if win and vim.api.nvim_win_is_valid(win) then
    local line_count = vim.api.nvim_buf_line_count(buf)
    local row = math.min(math.max(1, state.get_cursor()), line_count)
    vim.api.nvim_win_set_cursor(win, { row, 0 })
  end
end

function M.refresh()
  state.refresh()

  M.render()

  return state.get()
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
  window.close()
  state.reset()
end

return M
