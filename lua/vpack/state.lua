local backend = require("vpack.backend.pack")

local FIRST_ITEM_LINE = 4
local DETAIL_LINE_COUNT = 4

local M = {
  snapshot = {
    items = {},
    cursor = FIRST_ITEM_LINE,
    expanded = {},
    busy = false,
    error = nil,
    details_open = false,
    current = nil,
  },
}

local function current_index()
  if not M.snapshot.current then
    return nil
  end

  for index, item in ipairs(M.snapshot.items) do
    if item.name == M.snapshot.current.name then
      return index
    end
  end

  return nil
end

local function row_to_index(row)
  local items = M.snapshot.items

  if vim.tbl_isempty(items) then
    return nil
  end

  local row_map = M.snapshot.row_map or {}
  if row_map[row] then
    return row_map[row]
  end

  for offset = 1, #items + DETAIL_LINE_COUNT + 8 do
    if row_map[row + offset] then
      return row_map[row + offset]
    end

    if row_map[row - offset] then
      return row_map[row - offset]
    end
  end

  local index = row - FIRST_ITEM_LINE + 1
  local expanded_index = M.snapshot.details_open and current_index() or nil

  if expanded_index then
    local expanded_row = FIRST_ITEM_LINE + expanded_index - 1
    local detail_end = expanded_row + DETAIL_LINE_COUNT

    if row > expanded_row and row <= detail_end then
      index = expanded_index
    elseif row > detail_end then
      index = index - DETAIL_LINE_COUNT
    end
  end

  return math.min(math.max(index, 1), #items)
end

local function clamp_cursor(row)
  local items = M.snapshot.items

  if vim.tbl_isempty(items) then
    return FIRST_ITEM_LINE
  end

  local row_map = M.snapshot.row_map or {}
  if not vim.tbl_isempty(row_map) then
    local mapped = row_to_index(row)
    if mapped then
      for mapped_row, item_index in pairs(row_map) do
        if item_index == mapped then
          return mapped_row
        end
      end
    end
  end

  local last_item_line = FIRST_ITEM_LINE + #items - 1
  return math.min(math.max(row, FIRST_ITEM_LINE), last_item_line)
end

---@return table
function M.refresh()
  M.snapshot.items = backend.list()
  M.snapshot.row_map = M.snapshot.row_map or {}
  M.snapshot.cursor = clamp_cursor(M.snapshot.cursor)

  if M.snapshot.details_open then
    local selected = M.peek_current()
    if selected then
      M.snapshot.current = selected
    end
  elseif M.snapshot.current and not M.peek_current() then
    M.snapshot.current = nil
  end

  return M.snapshot
end

---@param row integer
---@return table?
function M.set_cursor(row)
  M.snapshot.cursor = clamp_cursor(row)
  return M.peek_current()
end

---@return table?
function M.peek_current()
  local items = M.snapshot.items

  if vim.tbl_isempty(items) then
    return nil
  end

  local index = row_to_index(M.snapshot.cursor)
  if not index then
    return nil
  end

  return items[index]
end

---@return table?
function M.get_current()
  return M.snapshot.current
end

---@return table?
function M.toggle_details()
  local selected = M.peek_current()

  if not selected then
    M.snapshot.details_open = false
    M.snapshot.current = nil
    return nil
  end

  if M.snapshot.details_open and M.snapshot.current and M.snapshot.current.name == selected.name then
    M.snapshot.details_open = false
    M.snapshot.current = nil
    return nil
  end

  M.snapshot.details_open = true
  M.snapshot.current = selected
  return M.snapshot.current
end

function M.reset()
  M.snapshot.cursor = FIRST_ITEM_LINE
  M.snapshot.current = nil
  M.snapshot.details_open = false
  M.snapshot.error = nil
  M.snapshot.busy = false
  M.snapshot.row_map = {}
end

---@return integer
function M.get_cursor()
  return M.snapshot.cursor
end

---@return table
function M.get()
  return M.snapshot
end

return M
