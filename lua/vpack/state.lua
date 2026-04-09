local backend = require("vpack.backend.pack")
local updates = require("vpack.backend.updates")

local FIRST_ITEM_LINE = 4

local M = {
  snapshot = {
    items = {},
    cursor = FIRST_ITEM_LINE,
    expanded = {},
    busy = false,
    error = nil,
    details_open = false,
    current = nil,
    selected_name = nil,
    operations = {},
    generation = 0,
    spinner_tick = 1,
  },
}

local function apply_operations(items)
  for _, item in ipairs(items or {}) do
    item.operation_info = M.snapshot.operations[item.name]
  end
end

local function nearest_mapped_row(row)
  local row_map = M.snapshot.row_map or {}
  local nearest_row
  local nearest_index
  local nearest_distance

  for mapped_row, item_index in pairs(row_map) do
    local distance = math.abs(mapped_row - row)

    if
      not nearest_distance
      or distance < nearest_distance
      or (distance == nearest_distance and mapped_row < nearest_row)
    then
      nearest_row = mapped_row
      nearest_index = item_index
      nearest_distance = distance
    end
  end

  return nearest_row, nearest_index
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

  local _, nearest_index = nearest_mapped_row(row)
  if nearest_index then
    return nearest_index
  end

  local index = row - FIRST_ITEM_LINE + 1
  return math.min(math.max(index, 1), #items)
end

local function clamp_cursor(row)
  local items = M.snapshot.items

  if vim.tbl_isempty(items) then
    return FIRST_ITEM_LINE
  end

  local row_map = M.snapshot.row_map or {}
  if not vim.tbl_isempty(row_map) then
    local mapped_row = nearest_mapped_row(row)
    if mapped_row then
      return mapped_row
    end
  end

  local last_item_line = FIRST_ITEM_LINE + #items - 1
  return math.min(math.max(row, FIRST_ITEM_LINE), last_item_line)
end

---@return table
function M.refresh()
  local previous = M.peek_current()
  M.snapshot.selected_name = previous and previous.name or nil

  M.snapshot.items = updates.decorate(backend.list())
  apply_operations(M.snapshot.items)
  M.snapshot.row_map = M.snapshot.row_map or {}
  M.snapshot.cursor = clamp_cursor(M.snapshot.cursor)

  if M.snapshot.details_open then
    local selected = nil

    if M.snapshot.selected_name then
      selected = vim.iter(M.snapshot.items):find(function(item)
        return item.name == M.snapshot.selected_name
      end)
    end

    selected = selected or M.peek_current()
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
  local current = M.peek_current()
  M.snapshot.selected_name = current and current.name or nil
  return current
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
  M.snapshot.generation = M.snapshot.generation + 1
  M.snapshot.cursor = FIRST_ITEM_LINE
  M.snapshot.current = nil
  M.snapshot.selected_name = nil
  M.snapshot.details_open = false
  M.snapshot.error = nil
  M.snapshot.busy = false
  M.snapshot.operations = {}
  M.snapshot.spinner_tick = 1
  M.snapshot.row_map = {}
end

---@param names string[]
---@param info table?
function M.set_operation(names, info)
  if not names or vim.tbl_isempty(names) then
    return
  end

  for _, name in ipairs(names) do
    if info then
      M.snapshot.operations[name] = vim.tbl_extend("force", {}, info)
    else
      M.snapshot.operations[name] = nil
    end
  end

  apply_operations(M.snapshot.items)
end

---@param name string
---@return table?
function M.get_operation(name)
  return M.snapshot.operations[name]
end

---@param kind string
---@return boolean
function M.has_active_operation(kind)
  for _, operation in pairs(M.snapshot.operations) do
    if operation.kind == kind and operation.status == "updating" then
      return true
    end
  end

  return false
end

---@return integer
function M.get_generation()
  return M.snapshot.generation
end

function M.tick_spinner()
  M.snapshot.spinner_tick = (M.snapshot.spinner_tick % 10) + 1
  return M.snapshot.spinner_tick
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
