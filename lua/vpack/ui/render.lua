local M = {}

local namespace = vim.api.nvim_create_namespace("vpack.ui")
local PADDING = 2

local function with_padding(line, padding)
  return string.rep(" ", padding) .. line
end

local function header_line(items)
  local total = #items
  local active = vim.iter(items):fold(0, function(acc, item)
    return acc + (item.active and 1 or 0)
  end)

  return string.format("Vpack  %d plugins (%d active)", total, active)
end

local function format_item(item)
  local status = item.active and "●" or "○"
  local revision = item.rev and item.rev:sub(1, 7) or "-------"
  return string.format("%s %s  %s", status, item.short_name, revision)
end

local function detail_lines(item)
  if not item then
    return {
      "Details",
      "  No package selected.",
    }
  end

  local source = item.spec and (item.spec.src or item.spec.url) or "-"

  return {
    string.format("  source  %s", source),
    string.format("  path    %s", item.path or "-"),
    string.format("  state   %s", item.active and "active" or "inactive"),
    string.format("  commit  %s", item.rev and item.rev:sub(1, 7) or "-------"),
  }
end

---@param buf integer
---@param snapshot table
function M.render(buf, snapshot)
  local padding = PADDING

  local items = snapshot.items or {}
  local lines = {
    with_padding(header_line(items), padding),
    "",
    with_padding(
      "[<CR>] details  [r] refresh  [u] update  [U] update all  [d] delete  [X] clean  [l] log  [q] quit",
      padding
    ),
    "",
  }

  if vim.tbl_isempty(items) then
    table.insert(lines, with_padding("No managed packages found.", padding))
  else
    for _, item in ipairs(items) do
      table.insert(lines, with_padding(format_item(item), padding))

      if snapshot.details_open and snapshot.current and snapshot.current.name == item.name then
        for _, line in ipairs(detail_lines(item)) do
          table.insert(lines, with_padding(line, padding))
        end
      end
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, namespace, "Title", 0, padding, -1)
  vim.api.nvim_buf_add_highlight(buf, namespace, "Comment", 1, padding, -1)

  local row = 3
  for _, item in ipairs(items) do
    row = row + 1
    vim.api.nvim_buf_add_highlight(buf, namespace, "Identifier", row - 1, padding + 2, -1)

    if snapshot.details_open and snapshot.current and snapshot.current.name == item.name then
      for _ = 1, 4 do
        row = row + 1
        vim.api.nvim_buf_add_highlight(buf, namespace, "Comment", row - 1, padding, -1)
      end
    end
  end

  vim.bo[buf].modifiable = false
end

return M
