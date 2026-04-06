local M = {}

local namespace = vim.api.nvim_create_namespace("vpack.ui")
local PADDING = 2
local ITEM_INDENT = 2
local DETAIL_INDENT = 4

local function with_padding(line, padding)
  return string.rep(" ", padding) .. line
end

local function format_item(item)
  local status = item.active and "●" or "○"
  local revision = item.rev and item.rev:sub(1, 7) or "-------"
  return string.format("%s %s  %s", status, item.short_name, revision)
end

local function summary_line(items)
  local total = #items
  local active = vim.iter(items):fold(0, function(acc, item)
    return acc + (item.active and 1 or 0)
  end)

  return string.format("%d plugins (%d active)", total, active)
end

local function section_title(name, items)
  return string.format("%s (%d)", name, #items)
end

local function detail_lines(item)
  if not item then
    return {
      string.rep(" ", DETAIL_INDENT) .. "No package selected.",
    }
  end

  local source = item.spec and (item.spec.src or item.spec.url) or "-"

  return {
    string.format("%ssource  %s", string.rep(" ", DETAIL_INDENT), source),
    string.format("%spath    %s", string.rep(" ", DETAIL_INDENT), item.path or "-"),
    string.format("%sstate   %s", string.rep(" ", DETAIL_INDENT), item.active and "active" or "inactive"),
    string.format("%scommit  %s", string.rep(" ", DETAIL_INDENT), item.rev and item.rev:sub(1, 7) or "-------"),
  }
end

---@param buf integer
---@param snapshot table
function M.render(buf, snapshot)
  local padding = PADDING

  local items = snapshot.items or {}
  local loaded = {}
  local unloaded = {}
  local index_by_name = {}

  for index, item in ipairs(items) do
    index_by_name[item.name] = index

    if item.active then
      table.insert(loaded, item)
    else
      table.insert(unloaded, item)
    end
  end

  local row_map = {}
  local lines = {
    with_padding(summary_line(items), padding),
    with_padding(
      "[<CR>] details  [r] refresh  [u] update  [U] update all  [d] delete  [X] clean  [l] log  [q] quit",
      padding
    ),
    "",
  }

  if vim.tbl_isempty(items) then
    table.insert(lines, with_padding("No managed packages found.", padding))
  else
    local function append_section(name, section_items)
      if vim.tbl_isempty(section_items) then
        return
      end

      table.insert(lines, with_padding(section_title(name, section_items), padding))

      for _, item in ipairs(section_items) do
        table.insert(lines, with_padding(format_item(item), padding + ITEM_INDENT))
        row_map[#lines] = index_by_name[item.name]

        if snapshot.details_open and snapshot.current and snapshot.current.name == item.name then
          for _, line in ipairs(detail_lines(item)) do
            table.insert(lines, with_padding(line, padding + ITEM_INDENT))
            row_map[#lines] = index_by_name[item.name]
          end
        end
      end

      table.insert(lines, "")
    end

    append_section("Loaded", loaded)
    append_section("Unloaded", unloaded)
  end

  while lines[#lines] == "" do
    table.remove(lines)
  end

  snapshot.row_map = row_map

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, namespace, "Title", 0, padding, -1)
  vim.api.nvim_buf_add_highlight(buf, namespace, "Comment", 1, padding, -1)

  for row, line in ipairs(lines) do
    local lnum = row - 1

    if line:find("^%s*Loaded %(%d+%)") or line:find("^%s*Unloaded %(%d+%)") then
      vim.api.nvim_buf_add_highlight(buf, namespace, "Title", lnum, padding, -1)
    elseif row_map[row] then
      vim.api.nvim_buf_add_highlight(buf, namespace, "Identifier", lnum, padding + 2, -1)
    elseif line:find("^%s+source") or line:find("^%s+path") or line:find("^%s+state") or line:find("^%s+commit") then
      vim.api.nvim_buf_add_highlight(buf, namespace, "Comment", lnum, padding, -1)
    end
  end

  vim.bo[buf].modifiable = false
end

return M
