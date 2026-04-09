local M = {}

local env = require("vpack.backend.env")

local DEFAULT_UPDATE_TIMEOUT_MS = 3 * 60 * 1000

local function can_update()
  return vim.pack and type(vim.pack.update) == "function"
end

local function parse_async_result(stdout)
  local marker = stdout and stdout:match("VPACK_RESULT:(.-)\n")
  if not marker or marker == "" then
    return nil
  end

  local ok, decoded = pcall(vim.json.decode, marker)
  if ok and type(decoded) == "table" then
    return decoded
  end
end

local function is_timed_out(result)
  return result and result.code == 124
end

local function result_error(result, fallback)
  local message = vim.trim(result.stderr or "")
  if message == "" then
    message = vim.trim(result.stdout or "")
  end

  if is_timed_out(result) then
    if message ~= "" then
      return message .. " (timed out)"
    end

    return fallback .. " (timed out)"
  end

  if message ~= "" then
    return message
  end

  return fallback
end

local function run_update_async(targets, callback)
  callback = callback or function() end

  if not can_update() then
    callback({ ok = false, error = "vim.pack.update is unavailable" })
    return
  end

  local names_expr = "nil"
  if targets then
    names_expr = string.format("vim.json.decode(%q)", vim.json.encode(targets))
  end

  local command = string.format(
    "lua local changed, changed_lookup, failed = {}, {}, {} local current_name = nil local function remember_changed(name) if name and not changed_lookup[name] then changed_lookup[name] = true changed[#changed + 1] = name end end vim.api.nvim_create_autocmd('PackChanged', { callback = function(ev) if ev.data and ev.data.kind == 'update' and current_name then remember_changed(current_name) end end }) local names = %s if not names then names = {} local packages = vim.pack.get() or {} if vim.islist(packages) then for index, item in ipairs(packages) do local name = item.name or (item.spec and (item.spec.name or item.spec.src or item.spec.url)) or item.path or tostring(index) names[#names + 1] = name end else for name, _ in pairs(packages) do names[#names + 1] = name end end end for _, name in ipairs(names) do current_name = name local ok, err = pcall(vim.pack.update, { name }, { force = true }) if not ok then failed[name] = tostring(err) end current_name = nil end print('VPACK_RESULT:' .. vim.json.encode({ changed_names = changed, failed_names = failed }))",
    names_expr
  )

  vim.system({ vim.v.progpath, "--headless", "-c", command, "-c", "qa" }, {
    text = true,
    timeout = DEFAULT_UPDATE_TIMEOUT_MS,
    env = env.non_interactive(),
  }, function(result)
    local ok = result.code == 0

    local parsed = parse_async_result(result.stdout)

    callback({
      ok = ok,
      names = targets,
      changed_names = parsed and parsed.changed_names or nil,
      failed_names = parsed and parsed.failed_names or nil,
      timed_out = is_timed_out(result),
      error = ok and nil or result_error(result, "Update failed"),
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
