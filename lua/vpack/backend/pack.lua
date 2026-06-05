local M = {}

local function can_update()
  return vim.pack and type(vim.pack.update) == "function"
end

local function run_update_async(targets, callback)
  callback = callback or function() end

  if not can_update() then
    callback({ ok = false, error = "vim.pack.update is unavailable" })
    return
  end

  vim.schedule(function()
    local changed = {}
    local changed_lookup = {}
    local failed = {}

    local function remember_changed(name)
      if name and not changed_lookup[name] then
        changed_lookup[name] = true
        table.insert(changed, name)
      end
    end

    local current_name
    local augroup = vim.api.nvim_create_augroup("vpack.update", { clear = true })
    vim.api.nvim_create_autocmd("PackChanged", {
      group = augroup,
      callback = function(ev)
        if ev.data and ev.data.kind == "update" and current_name then
          remember_changed(current_name)
        end
      end,
    })

    for _, name in ipairs(targets or {}) do
      current_name = name
      local ok, err = pcall(vim.pack.update, { name }, { force = true })
      if not ok then
        failed[name] = tostring(err)
      end
      current_name = nil
    end

    pcall(vim.api.nvim_del_augroup_by_id, augroup)

    callback({
      ok = vim.tbl_isempty(failed),
      names = targets,
      changed_names = changed,
      failed_names = failed,
      error = vim.tbl_isempty(failed) and nil or "Update failed",
    })
  end)
end

local function is_pack_available()
  return vim.pack and type(vim.pack.get) == "function"
end

local function get_short_name(name, item)
  local source = item.spec and (item.spec.src or item.spec.url)
  local candidate = source or name
  return candidate:match("/([^/]+)$") or candidate
end

local function normalize(name, item)
  return {
    name = name,
    short_name = get_short_name(name, item),
    active = item.active == true,
    path = item.path,
    rev = item.rev,
    spec = item.spec or {},
    tags = item.tags or {},
    branches = item.branches or {},
  }
end

---@return table[]
function M.list()
  if not is_pack_available() then
    return {}
  end

  local ok, packages = pcall(vim.pack.get)
  if not ok or type(packages) ~= "table" then
    return {}
  end

  local items = {}

  if vim.islist(packages) then
    for index, item in ipairs(packages) do
      local name = item.name
      if not name and item.spec then
        name = item.spec.name or item.spec.src or item.spec.url
      end

      name = name or item.path or tostring(index)
      table.insert(items, normalize(name, item))
    end
  else
    for name, item in pairs(packages) do
      table.insert(items, normalize(name, item))
    end
  end

  table.sort(items, function(left, right)
    return left.short_name < right.short_name
  end)

  return items
end

function M.update(target)
  if can_update() then
    return vim.pack.update({ target })
  end
end

function M.update_async(target, callback)
  return run_update_async({ target }, callback)
end

function M.update_all(targets)
  if can_update() then
    return targets and not vim.tbl_isempty(targets) and vim.pack.update(targets) or vim.pack.update()
  end
end

function M.update_all_async(callback, targets)
  return run_update_async(targets, callback)
end

function M.delete(target)
  if vim.pack and type(vim.pack.del) == "function" then
    return vim.pack.del({ target })
  end
end

function M.clean(targets)
  if not targets or vim.tbl_isempty(targets) then
    return
  end

  if vim.pack and type(vim.pack.del) == "function" then
    return vim.pack.del(targets)
  end
end

return M
