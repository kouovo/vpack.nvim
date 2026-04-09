local M = {}

local env = require("vpack.backend.env")
local uv = vim.uv or vim.loop
local DEFAULT_MAX_COMMITS = 5
local DEFAULT_TTL_MS = 5 * 60 * 1000
local MAX_CONCURRENT_CHECKS = 10
local DEFAULT_GIT_TIMEOUT_MS = 60 * 1000

local cache = {}
local running = {}
local queue = {}
local running_count = 0
local session = 0
local last_check_at

local function now_ms()
  return uv.now()
end

local function trim(value)
  return vim.trim(value or "")
end

local function empty_summary()
  return {
    total = 0,
    available = 0,
    current = 0,
    unsupported = 0,
    error = 0,
    timed_out = 0,
  }
end

local function is_timed_out(result)
  return result and result.code == 124
end

local function summarize(summary, info)
  if info.status == "available" then
    summary.available = summary.available + 1
  elseif info.status == "current" then
    summary.current = summary.current + 1
  elseif info.status == "unsupported" then
    summary.unsupported = summary.unsupported + 1
  elseif info.status == "error" then
    summary.error = summary.error + 1
    if info.timed_out then
      summary.timed_out = summary.timed_out + 1
    end
  end
end

local function safe_invoke(callback, ...)
  if not callback then
    return
  end

  local ok, err = pcall(callback, ...)
  if ok then
    return
  end

  vim.schedule(function()
    vim.notify(string.format("vpack callback failed: %s", err), vim.log.levels.ERROR, { title = "vpack" })
  end)
end

local function watchdog_timeout_ms(timeout_ms)
  local slack = math.max(25, math.min(250, math.floor(timeout_ms / 4)))
  return timeout_ms + slack
end

local run_git

local function split_lines(value)
  local lines = {}

  for line in (value .. "\n"):gmatch("(.-)\n") do
    if line ~= "" then
      table.insert(lines, line)
    end
  end

  return lines
end

local function error_message(result, fallback)
  if is_timed_out(result) then
    return fallback .. " (timed out)"
  end

  local message = trim(result.stderr)
  if message ~= "" then
    return message
  end

  message = trim(result.stdout)
  if message ~= "" then
    return message
  end

  return fallback
end

local function is_version_range(version)
  return type(version) == "table" and type(version.has) == "function"
end

local function find_matching_tag(tags, version_range)
  local best_tag
  local best_version

  for _, tag in ipairs(tags) do
    local parsed = vim.version.parse(tag)
    if parsed then
      local ok, matches = pcall(version_range.has, version_range, parsed)
      if ok and matches and (not best_version or parsed > best_version) then
        best_tag = tag
        best_version = parsed
      end
    end
  end

  return best_tag
end

local function resolve_target_ref(item, timeout_ms, callback)
  local version = item.spec and item.spec.version

  if version == nil then
    return run_git(item.path, { "rev-parse", "--abbrev-ref", "origin/HEAD" }, timeout_ms, function(result)
      if result.code ~= 0 then
        callback(nil, {
          status = "error",
          message = error_message(result, "Failed to resolve default branch"),
          timed_out = is_timed_out(result),
        })
        return
      end

      local ref = trim(result.stdout)
      if ref == "" then
        callback(nil, {
          status = "unsupported",
          message = "No default branch ref",
        })
        return
      end

      callback({ ref = ref, label = ref:gsub("^origin/", "") })
    end)
  end

  if type(version) == "string" then
    local remote_ref = "refs/remotes/origin/" .. version

    return run_git(item.path, { "show-ref", "--verify", "--quiet", remote_ref }, timeout_ms, function(result)
      if is_timed_out(result) then
        callback(nil, {
          status = "error",
          message = error_message(result, "Failed to resolve target branch"),
          timed_out = true,
        })
        return
      end

      if result.code == 0 then
        callback({ ref = "origin/" .. version, label = version })
        return
      end

      callback({ ref = version, label = version })
    end)
  end

  if is_version_range(version) then
    return run_git(item.path, { "tag", "--list", "--sort=-v:refname" }, timeout_ms, function(result)
      if result.code ~= 0 then
        callback(nil, {
          status = "error",
          message = error_message(result, "Failed to list tags"),
          timed_out = is_timed_out(result),
        })
        return
      end

      local tag = find_matching_tag(split_lines(result.stdout), version)
      if not tag then
        callback(nil, {
          status = "unsupported",
          message = "No tag matches version range",
        })
        return
      end

      callback({ ref = tag, label = tag })
    end)
  end

  callback(nil, {
    status = "unsupported",
    message = "Unsupported version spec",
  })
end

local function save(item, info)
  info = vim.tbl_extend("force", info, {
    path = item.path,
    current_rev = info.current_rev or item.rev,
  })

  if info.status ~= "checking" then
    info.checked_at = now_ms()
  end

  cache[item.name] = info
  running[item.name] = nil
  return info
end

local function set_check_state(item, info, on_change)
  cache[item.name] = vim.tbl_extend("force", {
    path = item.path,
    current_rev = item.rev,
  }, info)

  safe_invoke(on_change, item, cache[item.name])
end

run_git = function(path, args, timeout_ms, callback)
  local command = { "git" }
  vim.list_extend(command, args)
  local settled = false
  local timer = uv.new_timer()

  local function stop_timer()
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
  end

  local function complete(result)
    if settled then
      return
    end

    settled = true
    stop_timer()
    callback(result)
  end

  timer:start(watchdog_timeout_ms(timeout_ms), 0, function()
    vim.schedule(function()
      complete({
        code = 124,
        stdout = "",
        stderr = "",
      })
    end)
  end)

  local ok, err = pcall(vim.system, command, {
    cwd = path,
    text = true,
    timeout = timeout_ms,
    env = env.non_interactive(),
  }, function(result)
    complete(result)
  end)

  if ok then
    return
  end

  complete({
    code = 1,
    stdout = "",
    stderr = tostring(err),
  })
end

local function finish(item, info, on_change, token, batch)
  if token ~= session then
    return
  end

  local saved = save(item, info)
  running_count = math.max(running_count - 1, 0)

  if on_change then
    safe_invoke(on_change, item, saved)
  end

  if batch and batch.session == token then
    summarize(batch.summary, saved)
    batch.pending = math.max(batch.pending - 1, 0)

    if batch.pending == 0 and batch.on_complete then
      local on_complete = batch.on_complete
      local summary = vim.deepcopy(batch.summary)
      batch.on_complete = nil
      last_check_at = now_ms()

      vim.schedule(function()
        safe_invoke(on_complete, summary)
      end)
    end
  end

  if #queue > 0 then
    vim.schedule(function()
      if M._process_queue then
        M._process_queue()
      end
    end)
  end
end

local function check_item(item, opts)
  local max_commits = opts.max_commits or DEFAULT_MAX_COMMITS
  local timeout_ms = opts.timeout_ms or DEFAULT_GIT_TIMEOUT_MS
  local on_change = opts.on_change
  local token = opts._session
  local batch = opts._batch

  local settled = false

  local function complete(info)
    if settled then
      return
    end

    settled = true
    finish(item, info, on_change, token, batch)
  end

  running[item.name] = true
  running_count = running_count + 1
  set_check_state(item, { status = "checking" }, on_change)

  run_git(item.path, { "rev-parse", "HEAD" }, timeout_ms, function(head_result)
    if head_result.code ~= 0 then
      return complete({
        status = "error",
        message = error_message(head_result, "Failed to resolve HEAD"),
        timed_out = is_timed_out(head_result),
      })
    end

    local current_rev = trim(head_result.stdout)

    run_git(
      item.path,
      { "fetch", "--quiet", "--tags", "--force", "--recurse-submodules=yes", "origin" },
      timeout_ms,
      function(fetch_result)
        if fetch_result.code ~= 0 then
          return complete({
            status = "error",
            current_rev = current_rev,
            message = error_message(fetch_result, "Failed to fetch updates"),
            timed_out = is_timed_out(fetch_result),
          })
        end

        resolve_target_ref(item, timeout_ms, function(target, target_error)
          if target_error then
            target_error.current_rev = current_rev
            return complete(target_error)
          end

          run_git(item.path, { "rev-list", "-1", target.ref }, timeout_ms, function(target_result)
            if target_result.code ~= 0 then
              return complete({
                status = "error",
                current_rev = current_rev,
                message = error_message(target_result, "Failed to resolve target revision"),
                timed_out = is_timed_out(target_result),
              })
            end

            local target_rev = trim(target_result.stdout)
            if target_rev == current_rev then
              return complete({
                status = "current",
                current_rev = current_rev,
                target_rev = target_rev,
                pending_count = 0,
                commits = {},
              })
            end

            local revision_range = string.format("HEAD..%s", target.ref)

            run_git(item.path, { "rev-list", "--count", revision_range }, timeout_ms, function(count_result)
              if count_result.code ~= 0 then
                return complete({
                  status = "error",
                  current_rev = current_rev,
                  target_rev = target_rev,
                  message = error_message(count_result, "Failed to count incoming commits"),
                  timed_out = is_timed_out(count_result),
                })
              end

              local pending_count = tonumber(trim(count_result.stdout)) or 0

              run_git(
                item.path,
                { "log", "--oneline", string.format("--max-count=%d", max_commits), revision_range },
                timeout_ms,
                function(log_result)
                  if log_result.code ~= 0 then
                    return complete({
                      status = "error",
                      current_rev = current_rev,
                      target_rev = target_rev,
                      message = error_message(log_result, "Failed to load incoming commits"),
                      timed_out = is_timed_out(log_result),
                    })
                  end

                  local commits = split_lines(log_result.stdout)

                  complete({
                    status = "available",
                    current_rev = current_rev,
                    target_rev = target_rev,
                    pending_count = pending_count,
                    commits = commits,
                    remaining_count = math.max(pending_count - #commits, 0),
                  })
                end
              )
            end)
          end)
        end)
      end
    )
  end)
end

local function is_stale(info, ttl_ms)
  return not info.checked_at or now_ms() - info.checked_at >= ttl_ms
end

local function has_reusable_result(item)
  local info = cache[item.name]
  if not info or info.path ~= item.path then
    return false
  end

  if info.status == "queued" or info.status == "checking" then
    return false
  end

  if info.current_rev and item.rev and info.current_rev ~= item.rev then
    return false
  end

  return true
end

local function can_reuse_recent_batch(items, opts)
  if opts.force then
    return false
  end

  local ttl_ms = opts.ttl_ms or DEFAULT_TTL_MS
  if not last_check_at or now_ms() - last_check_at >= ttl_ms then
    return false
  end

  for _, item in ipairs(items or {}) do
    if item.active and item.path and item.path ~= "" and not has_reusable_result(item) then
      return false
    end
  end

  return true
end

local function should_check(item, opts)
  if not item.active or not item.path or item.path == "" then
    return false
  end

  if running[item.name] then
    return false
  end

  local info = cache[item.name]
  if not info then
    return true
  end

  if opts.force then
    return true
  end

  if info.path ~= item.path then
    return true
  end

  if info.current_rev and item.rev and info.current_rev ~= item.rev then
    return true
  end

  return is_stale(info, opts.ttl_ms or DEFAULT_TTL_MS)
end

function M.decorate(items)
  for _, item in ipairs(items) do
    local info = cache[item.name]

    if
      info
      and info.path == item.path
      and (not info.current_rev or not item.rev or info.current_rev == item.rev or info.status == "checking")
    then
      item.update_info = vim.deepcopy(info)
    else
      item.update_info = nil
    end
  end

  return items
end

function M.check_loaded(items, opts)
  opts = opts or {}
  local batch
  local started = 0

  if can_reuse_recent_batch(items, opts) then
    return 0
  end

  for _, item in ipairs(items or {}) do
    if should_check(item, opts) then
      if not batch then
        batch = {
          pending = 0,
          session = session,
          on_complete = opts.on_complete,
          summary = empty_summary(),
        }
      end

      batch.pending = batch.pending + 1
      batch.summary.total = batch.summary.total + 1
      started = started + 1
      running[item.name] = true
      set_check_state(item, { status = "queued" }, opts.on_change)

      local queued_opts = vim.tbl_extend("force", {}, opts, { _session = session, _batch = batch })
      table.insert(queue, { item = item, opts = queued_opts })
    end
  end

  if batch then
    M._process_queue()
  end

  return started
end

function M._process_queue()
  while running_count < MAX_CONCURRENT_CHECKS and #queue > 0 do
    local next_item = table.remove(queue, 1)
    if next_item and next_item.item and next_item.item.path and next_item.item.path ~= "" then
      check_item(next_item.item, next_item.opts)
    else
      finish(next_item.item, {
        status = "error",
        message = "Missing package path",
      }, next_item.opts.on_change, next_item.opts._session, next_item.opts._batch)
    end
  end
end

function M.reset()
  session = session + 1
  cache = {}
  running = {}
  queue = {}
  running_count = 0
  last_check_at = nil
end

return M
