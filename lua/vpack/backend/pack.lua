local M = {}

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
  if vim.pack and type(vim.pack.update) == "function" then
    return vim.pack.update({ target })
  end
end

function M.update_all()
  if vim.pack and type(vim.pack.update) == "function" then
    return vim.pack.update()
  end
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
