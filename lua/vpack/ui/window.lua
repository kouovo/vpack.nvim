local M = {
  buf = nil,
  win = nil,
}

local function resolve_size(value, total, minimum)
  if type(value) == "number" and value > 0 and value <= 1 then
    return math.max(minimum, math.floor(total * value))
  end

  return math.max(minimum, value or minimum)
end

local function ensure_buffer()
  if M.buf and vim.api.nvim_buf_is_valid(M.buf) then
    return M.buf
  end

  local buf = vim.api.nvim_create_buf(false, true)

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "vpack"

  M.buf = buf
  return buf
end

---@param opts table?
---@return { buf: integer, win: integer }
function M.open(opts)
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    return { buf = M.buf, win = M.win }
  end

  opts = opts or {}

  local buf = ensure_buffer()
  local ui = vim.api.nvim_list_uis()[1]
  local total_width = ui and ui.width or vim.o.columns
  local total_height = ui and ui.height or (vim.o.lines - 2)
  local width = resolve_size(opts.width or 0.8, total_width, 40)
  local height = resolve_size(opts.height or 0.8, total_height, 10)
  local row = math.max(0, math.floor((total_height - height) / 2))
  local col = math.max(0, math.floor((total_width - width) / 2))

  M.win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = opts.border or "rounded",
    width = width,
    height = height,
    row = row,
    col = col,
    title = " Vpack ",
    title_pos = "center",
  })

  vim.wo[M.win].number = false
  vim.wo[M.win].relativenumber = false
  vim.wo[M.win].cursorline = true
  vim.wo[M.win].signcolumn = "no"
  vim.wo[M.win].foldcolumn = "0"
  vim.wo[M.win].spell = false
  vim.wo[M.win].wrap = false

  return { buf = buf, win = M.win }
end

function M.close()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end

  M.win = nil
end

function M.is_valid()
  return M.win and vim.api.nvim_win_is_valid(M.win) or false
end

function M.get_buf()
  return M.buf
end

function M.get_win()
  return M.win
end

return M
