local M = {
  buf = nil,
  win = nil,
  lines = {},
}

local namespace = vim.api.nvim_create_namespace("vpack.log")

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
  vim.bo[buf].filetype = "log"

  M.buf = buf
  return buf
end

local function highlight_lines(buf, lines)
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)

  for index, line in ipairs(lines) do
    local _, time_end = line:find("^%S+")
    if time_end then
      vim.api.nvim_buf_add_highlight(buf, namespace, "Comment", index - 1, 0, time_end)
    end

    if line:find("ERROR", 1, true) then
      vim.api.nvim_buf_add_highlight(buf, namespace, "DiagnosticError", index - 1, 0, -1)
    elseif line:find("WARN", 1, true) then
      vim.api.nvim_buf_add_highlight(buf, namespace, "DiagnosticWarn", index - 1, 0, -1)
    elseif line:find("INFO", 1, true) then
      vim.api.nvim_buf_add_highlight(buf, namespace, "DiagnosticInfo", index - 1, 0, -1)
    end
  end
end

local function render(buf)
  local lines = vim.deepcopy(M.lines)
  if vim.tbl_isempty(lines) then
    lines = { "No log entries" }
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  highlight_lines(buf, lines)
  vim.bo[buf].modifiable = false
end

function M.close()
  if M.win and vim.api.nvim_win_is_valid(M.win) then
    vim.api.nvim_win_close(M.win, true)
  end

  M.win = nil
end

---@param opts table
---@return { buf: integer, win: integer }?
function M.open(opts)
  local path = opts.path

  if vim.fn.filereadable(path) == 0 then
    return nil
  end

  M.close()

  M.lines = vim.fn.readfile(path)
  local buf = ensure_buffer()
  local ui = vim.api.nvim_list_uis()[1]
  local total_width = ui and ui.width or vim.o.columns
  local total_height = ui and ui.height or (vim.o.lines - 2)
  local width = resolve_size(opts.width or 0.8, total_width, 40)
  local height = resolve_size(opts.height or 0.6, total_height, 10)
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
    title = " Vpack Log ",
    title_pos = "center",
  })

  vim.wo[M.win].number = false
  vim.wo[M.win].relativenumber = false
  vim.wo[M.win].cursorline = false
  vim.wo[M.win].wrap = false

  render(buf)

  vim.keymap.set("n", "q", function()
    M.close()
  end, { buffer = buf, silent = true, nowait = true, desc = "Close log" })
  vim.keymap.set("n", "G", function()
    if M.win and vim.api.nvim_win_is_valid(M.win) then
      local line_count = vim.api.nvim_buf_line_count(buf)
      vim.api.nvim_win_set_cursor(M.win, { line_count, 0 })
    end
  end, { buffer = buf, silent = true, nowait = true, desc = "Bottom of log" })

  return { buf = buf, win = M.win }
end

return M
