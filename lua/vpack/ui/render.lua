local M = {}

local namespace = vim.api.nvim_create_namespace("vpack.ui")
local PADDING = 2
local ITEM_INDENT = 2
local DETAIL_INDENT = 4
local SPINNER_FRAMES = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }

local function with_padding(line, padding)
  return string.rep(" ", padding) .. line
end

local function spinner_frame(tick)
  return SPINNER_FRAMES[((tick or 1) - 1) % #SPINNER_FRAMES + 1]
end

local function format_item(item, tick)
  local status = item.active and "●" or "○"
  local revision = item.rev and item.rev:sub(1, 7) or "-------"
  local update_info = item.update_info
  local operation_info = item.operation_info
  local suffix = ""

  if operation_info and operation_info.kind == "update" then
    if operation_info.status == "updating" then
      suffix = string.format(" [updating %s]", spinner_frame(tick))
    elseif operation_info.status == "updated" then
      suffix = " [updated]"
    elseif operation_info.status == "no_changes" then
      suffix = " [no changes]"
    elseif operation_info.status == "error" then
      suffix = " [update failed]"
    end
  elseif update_info then
    if update_info.status == "queued" then
      suffix = " [queued]"
    elseif update_info.status == "checking" then
      suffix = string.format(" [checking %s]", spinner_frame(tick))
    elseif update_info.status == "current" then
      suffix = " [up-to-date]"
    elseif update_info.status == "unsupported" then
      suffix = " [no upstream]"
    elseif update_info.status == "error" then
      suffix = " [check failed]"
    end
  end

  if update_info and update_info.status == "available" then
    local target = update_info.target_rev and update_info.target_rev:sub(1, 7) or "-------"
    local pending = update_info.pending_count or #update_info.commits or 0
    return string.format("%s %s  %s → %s (+%d)%s", status, item.short_name, revision, target, pending, suffix)
  end

  return string.format("%s %s  %s%s", status, item.short_name, revision, suffix)
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

  local lines = {
    string.format("%ssource  %s", string.rep(" ", DETAIL_INDENT), source),
    string.format("%spath    %s", string.rep(" ", DETAIL_INDENT), item.path or "-"),
    string.format("%sstate   %s", string.rep(" ", DETAIL_INDENT), item.active and "active" or "inactive"),
    string.format("%scommit  %s", string.rep(" ", DETAIL_INDENT), item.rev and item.rev:sub(1, 7) or "-------"),
  }

  local update_info = item.update_info
  local operation_info = item.operation_info

  if operation_info and operation_info.kind == "update" then
    local label = operation_info.status
    if operation_info.status == "error" and operation_info.message then
      label = operation_info.message
    end

    table.insert(lines, string.format("%saction  %s", string.rep(" ", DETAIL_INDENT), label))
  end

  if not update_info or not item.active then
    return lines
  end

  if update_info.status == "checking" then
    table.insert(lines, string.format("%supdate  checking...", string.rep(" ", DETAIL_INDENT)))
    return lines
  end

  if update_info.status == "queued" then
    table.insert(lines, string.format("%supdate  queued", string.rep(" ", DETAIL_INDENT)))
    return lines
  end

  if update_info.status == "current" then
    table.insert(lines, string.format("%supdate  up-to-date", string.rep(" ", DETAIL_INDENT)))
    return lines
  end

  if update_info.status == "unsupported" then
    table.insert(
      lines,
      string.format("%supdate  %s", string.rep(" ", DETAIL_INDENT), update_info.message or "unsupported")
    )
    return lines
  end

  if update_info.status == "error" then
    table.insert(
      lines,
      string.format("%supdate  %s", string.rep(" ", DETAIL_INDENT), update_info.message or "check failed")
    )
    return lines
  end

  if update_info.status == "available" then
    local remaining_count = update_info.remaining_count
    if remaining_count == nil then
      remaining_count = math.max((update_info.pending_count or 0) - #(update_info.commits or {}), 0)
    end

    table.insert(lines, string.format("%supdate  available", string.rep(" ", DETAIL_INDENT)))
    table.insert(
      lines,
      string.format(
        "%starget  %s",
        string.rep(" ", DETAIL_INDENT),
        update_info.target_rev and update_info.target_rev:sub(1, 7) or "-------"
      )
    )
    table.insert(
      lines,
      string.format(
        "%sahead   %d commits",
        string.rep(" ", DETAIL_INDENT),
        update_info.pending_count or #update_info.commits or 0
      )
    )

    if update_info.commits and not vim.tbl_isempty(update_info.commits) then
      table.insert(lines, string.format("%schanges", string.rep(" ", DETAIL_INDENT)))

      for _, commit in ipairs(update_info.commits) do
        table.insert(lines, string.format("%s  %s", string.rep(" ", DETAIL_INDENT), commit))
      end
    end

    if remaining_count > 0 then
      table.insert(lines, string.format("%s  ... and %d more", string.rep(" ", DETAIL_INDENT), remaining_count))
    end
  end

  return lines
end

---@param buf integer
---@param snapshot table
function M.render(buf, snapshot)
  local padding = PADDING

  local items = snapshot.items or {}
  local updates_available = {}
  local loaded = {}
  local unloaded = {}
  local index_by_name = {}
  local selected_row

  for index, item in ipairs(items) do
    index_by_name[item.name] = index

    if item.active and item.update_info and item.update_info.status == "available" then
      table.insert(updates_available, item)
    elseif item.active then
      table.insert(loaded, item)
    else
      table.insert(unloaded, item)
    end
  end

  local row_map = {}
  local lines = {
    with_padding(summary_line(items), padding),
    with_padding(
      "[<CR>] details  [r] refresh  [c] check  [u] update  [U] update all  [d] delete  [X] clean  [l] log  [q] quit",
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
        table.insert(lines, with_padding(format_item(item, snapshot.spinner_tick), padding + ITEM_INDENT))
        row_map[#lines] = index_by_name[item.name]

        if not selected_row and snapshot.selected_name == item.name then
          selected_row = #lines
        end

        if snapshot.details_open and snapshot.current and snapshot.current.name == item.name then
          for _, line in ipairs(detail_lines(item)) do
            table.insert(lines, with_padding(line, padding + ITEM_INDENT))
            row_map[#lines] = index_by_name[item.name]
          end
        end
      end

      table.insert(lines, "")
    end

    append_section("Updates available", updates_available)
    append_section("Loaded", loaded)
    append_section("Unloaded", unloaded)
  end

  while lines[#lines] == "" do
    table.remove(lines)
  end

  snapshot.row_map = row_map

  if selected_row then
    snapshot.cursor = selected_row
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(buf, namespace, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, namespace, "Title", 0, padding, -1)
  vim.api.nvim_buf_add_highlight(buf, namespace, "Comment", 1, padding, -1)

  for row, line in ipairs(lines) do
    local lnum = row - 1

    if
      line:find("^%s*Updates available %(%d+%)")
      or line:find("^%s*Loaded %(%d+%)")
      or line:find("^%s*Unloaded %(%d+%)")
    then
      vim.api.nvim_buf_add_highlight(buf, namespace, "Title", lnum, padding, -1)
    elseif row_map[row] then
      vim.api.nvim_buf_add_highlight(buf, namespace, "Identifier", lnum, padding + 2, -1)
    elseif
      line:find("^%s+source")
      or line:find("^%s+path")
      or line:find("^%s+state")
      or line:find("^%s+commit")
      or line:find("^%s+action")
      or line:find("^%s+update")
      or line:find("^%s+target")
      or line:find("^%s+ahead")
      or line:find("^%s+changes")
    then
      vim.api.nvim_buf_add_highlight(buf, namespace, "Comment", lnum, padding, -1)
    end
  end

  vim.bo[buf].modifiable = false
end

return M
