local backend = require("vpack.backend.pack")
local env = require("vpack.backend.env")
local updates = require("vpack.backend.updates")

describe("vpack backend", function()
  local original_system
  local original_pack

  before_each(function()
    original_system = vim.system
    original_pack = vim.pack
    updates.reset()
  end)

  after_each(function()
    vim.system = original_system
    vim.pack = original_pack
    updates.reset()
  end)

  it("runs async updates with a timeout", function()
    local captured_timeout
    local captured_env
    local result

    vim.pack = vim.tbl_extend("force", {}, original_pack or {}, {
      update = function() end,
    })

    vim.system = function(_, opts, callback)
      captured_timeout = opts.timeout
      captured_env = opts.env

      vim.schedule(function()
        callback({
          code = 0,
          stdout = "VPACK_RESULT:" .. vim.json.encode({ changed_names = {}, failed_names = {} }) .. "\n",
          stderr = "",
        })
      end)

      return {}
    end

    backend.update_async("lazy.nvim", function(done)
      result = done
    end)

    local completed = vim.wait(100, function()
      return result ~= nil
    end)

    assert.are.equal(true, completed)
    assert.is_true(type(captured_timeout) == "number" and captured_timeout > 0)
    assert.are.equal("0", captured_env.GIT_TERMINAL_PROMPT)
    assert.are.equal("never", captured_env.GCM_INTERACTIVE)
  end)

  it("completes check batches with a summary and git timeouts", function()
    local captured_timeouts = {}
    local captured_env
    local summary

    vim.system = function(command, opts, callback)
      table.insert(captured_timeouts, opts.timeout)
      captured_env = opts.env

      local result

      if command[2] == "rev-parse" and command[3] == "HEAD" then
        result = { code = 0, stdout = "abcdef01\n", stderr = "" }
      elseif command[2] == "fetch" then
        result = { code = 0, stdout = "", stderr = "" }
      elseif command[2] == "rev-parse" and command[3] == "--abbrev-ref" then
        result = { code = 0, stdout = "origin/main\n", stderr = "" }
      elseif command[2] == "rev-list" and command[3] == "-1" and command[4] == "origin/main" then
        result = { code = 0, stdout = "abcdef01\n", stderr = "" }
      else
        error("unexpected git command: " .. table.concat(command, " "))
      end

      vim.schedule(function()
        callback(result)
      end)

      return {}
    end

    updates.check_loaded({
      {
        name = "lazy.nvim",
        active = true,
        path = "/tmp/lazy.nvim",
        rev = "abcdef01",
        spec = {},
        branches = { "main" },
      },
    }, {
      force = true,
      on_complete = function(done)
        summary = done
      end,
    })

    local completed = vim.wait(100, function()
      return summary ~= nil
    end)

    assert.are.equal(true, completed)
    assert.are.equal(1, summary.total)
    assert.are.equal(1, summary.current)
    assert.are.equal(0, summary.available)
    assert.are.equal(0, summary.unsupported)
    assert.are.equal(0, summary.error)
    assert.are.equal(0, summary.timed_out)
    assert.is_true(#captured_timeouts > 0)
    assert.are.equal("0", captured_env.GIT_TERMINAL_PROMPT)
    assert.are.equal("never", captured_env.GCM_INTERACTIVE)

    for _, timeout in ipairs(captured_timeouts) do
      assert.is_true(type(timeout) == "number" and timeout > 0)
    end
  end)

  it("checks branch versions against origin branches instead of upstream", function()
    local summary
    local final_info

    vim.system = function(command, _, callback)
      local result

      if command[2] == "rev-parse" and command[3] == "HEAD" then
        result = { code = 0, stdout = "abcdef01\n", stderr = "" }
      elseif command[2] == "fetch" then
        result = { code = 0, stdout = "", stderr = "" }
      elseif command[2] == "show-ref" and command[5] == "refs/remotes/origin/main" then
        result = { code = 0, stdout = "", stderr = "" }
      elseif command[2] == "rev-list" and command[3] == "-1" and command[4] == "origin/main" then
        result = { code = 0, stdout = "fedcba98\n", stderr = "" }
      elseif command[2] == "rev-list" and command[3] == "--count" then
        result = { code = 0, stdout = "1\n", stderr = "" }
      elseif command[2] == "log" then
        result = { code = 0, stdout = "fedcba9 feat: update\n", stderr = "" }
      else
        error("unexpected git command: " .. table.concat(command, " "))
      end

      vim.schedule(function()
        callback(result)
      end)

      return {}
    end

    updates.check_loaded({
      {
        name = "lazy.nvim",
        active = true,
        path = "/tmp/lazy.nvim",
        rev = "abcdef01",
        spec = { version = "main" },
      },
    }, {
      force = true,
      on_change = function(_, info)
        if info.status ~= "queued" and info.status ~= "checking" then
          final_info = info
        end
      end,
      on_complete = function(done)
        summary = done
      end,
    })

    local completed = vim.wait(100, function()
      return summary ~= nil and final_info ~= nil
    end)

    assert.are.equal(true, completed)
    assert.are.equal("available", final_info.status)
    assert.are.equal("fedcba98", final_info.target_rev)
    assert.are.equal(1, final_info.pending_count)
    assert.are.equal(1, summary.available)
    assert.are.equal(0, summary.unsupported)
  end)

  it("resolves tag versions to commits instead of tag objects", function()
    local summary
    local final_info

    vim.system = function(command, _, callback)
      local result

      if command[2] == "rev-parse" and command[3] == "HEAD" then
        result = { code = 0, stdout = "abcdef01\n", stderr = "" }
      elseif command[2] == "fetch" then
        result = { code = 0, stdout = "", stderr = "" }
      elseif command[2] == "show-ref" and command[5] == "refs/remotes/origin/v1.2.3" then
        result = { code = 1, stdout = "", stderr = "" }
      elseif command[2] == "rev-list" and command[3] == "-1" and command[4] == "v1.2.3" then
        result = { code = 0, stdout = "abcdef01\n", stderr = "" }
      else
        error("unexpected git command: " .. table.concat(command, " "))
      end

      vim.schedule(function()
        callback(result)
      end)

      return {}
    end

    updates.check_loaded({
      {
        name = "tagged.nvim",
        active = true,
        path = "/tmp/tagged.nvim",
        rev = "abcdef01",
        spec = { version = "v1.2.3" },
      },
    }, {
      force = true,
      on_change = function(_, info)
        if info.status ~= "queued" and info.status ~= "checking" then
          final_info = info
        end
      end,
      on_complete = function(done)
        summary = done
      end,
    })

    local completed = vim.wait(100, function()
      return summary ~= nil and final_info ~= nil
    end)

    assert.are.equal(true, completed)
    assert.are.equal("current", final_info.status)
    assert.are.equal("abcdef01", final_info.target_rev)
    assert.are.equal(1, summary.current)
    assert.are.equal(0, summary.available)
  end)

  it("picks the greatest matching semver tag for version ranges", function()
    local summary
    local final_info

    vim.system = function(command, _, callback)
      local result

      if command[2] == "rev-parse" and command[3] == "HEAD" then
        result = { code = 0, stdout = "abcdef01\n", stderr = "" }
      elseif command[2] == "fetch" then
        result = { code = 0, stdout = "", stderr = "" }
      elseif command[2] == "tag" then
        result = { code = 0, stdout = "1.0.0-rc1\n1.0.0\n", stderr = "" }
      elseif command[2] == "rev-list" and command[3] == "-1" and command[4] == "1.0.0" then
        result = { code = 0, stdout = "abcdef01\n", stderr = "" }
      else
        error("unexpected git command: " .. table.concat(command, " "))
      end

      vim.schedule(function()
        callback(result)
      end)

      return {}
    end

    updates.check_loaded({
      {
        name = "versioned.nvim",
        active = true,
        path = "/tmp/versioned.nvim",
        rev = "abcdef01",
        spec = {
          version = {
            has = function(_, parsed)
              return parsed.major == 1
            end,
          },
        },
      },
    }, {
      force = true,
      on_change = function(_, info)
        if info.status ~= "queued" and info.status ~= "checking" then
          final_info = info
        end
      end,
      on_complete = function(done)
        summary = done
      end,
    })

    local completed = vim.wait(100, function()
      return summary ~= nil and final_info ~= nil
    end)

    assert.are.equal(true, completed)
    assert.are.equal("current", final_info.status)
    assert.are.equal("abcdef01", final_info.target_rev)
    assert.are.equal(1, summary.current)
  end)

  it("treats default-branch lookup timeouts as check errors", function()
    local summary
    local final_info

    vim.system = function(command, _, callback)
      local result

      if command[2] == "rev-parse" and command[3] == "HEAD" then
        result = { code = 0, stdout = "abcdef01\n", stderr = "" }
      elseif command[2] == "fetch" then
        result = { code = 0, stdout = "", stderr = "" }
      elseif command[2] == "rev-parse" and command[3] == "--abbrev-ref" then
        result = { code = 124, stdout = "", stderr = "" }
      else
        error("unexpected git command: " .. table.concat(command, " "))
      end

      vim.schedule(function()
        callback(result)
      end)

      return {}
    end

    updates.check_loaded({
      { name = "lazy.nvim", active = true, path = "/tmp/lazy.nvim", rev = "abcdef01", spec = {} },
    }, {
      force = true,
      on_change = function(_, info)
        if info.status ~= "queued" and info.status ~= "checking" then
          final_info = info
        end
      end,
      on_complete = function(done)
        summary = done
      end,
    })

    local completed = vim.wait(100, function()
      return summary ~= nil and final_info ~= nil
    end)

    assert.are.equal(true, completed)
    assert.are.equal("error", final_info.status)
    assert.are.equal(true, final_info.timed_out)
    assert.are.equal(1, summary.error)
    assert.are.equal(1, summary.timed_out)
    assert.are.equal(0, summary.unsupported)
  end)

  it("does not emit completion when no checks start", function()
    local completed = false

    local started = updates.check_loaded({
      { name = "lazy.nvim", active = false, path = "/tmp/lazy.nvim", rev = "abcdef01" },
    }, {
      force = true,
      on_complete = function()
        completed = true
      end,
    })

    vim.wait(50)

    assert.are.equal(0, started)
    assert.are.equal(false, completed)
  end)

  it("fails a check when a git callback never returns", function()
    local summary
    local final_info

    vim.system = function(command, _, callback)
      if command[2] == "rev-parse" and command[3] == "HEAD" then
        vim.schedule(function()
          callback({ code = 0, stdout = "abcdef01\n", stderr = "" })
        end)
      elseif command[2] == "rev-parse" and command[3] == "--abbrev-ref" then
        vim.schedule(function()
          callback({ code = 0, stdout = "origin/main\n", stderr = "" })
        end)
      elseif command[2] == "fetch" then
        -- simulate a missing vim.system callback
      else
        error("unexpected git command: " .. table.concat(command, " "))
      end

      return {}
    end

    updates.check_loaded({
      { name = "lazy.nvim", active = true, path = "/tmp/lazy.nvim", rev = "abcdef01" },
    }, {
      force = true,
      timeout_ms = 10,
      on_change = function(_, info)
        if info.status ~= "queued" and info.status ~= "checking" then
          final_info = info
        end
      end,
      on_complete = function(done)
        summary = done
      end,
    })

    local completed = vim.wait(200, function()
      return summary ~= nil and final_info ~= nil
    end)

    assert.are.equal(true, completed)
    assert.are.equal("error", final_info.status)
    assert.are.equal(true, final_info.timed_out)
    assert.are.equal(1, summary.error)
    assert.are.equal(1, summary.timed_out)
  end)

  it("builds non-interactive env inside a fast callback", function()
    local ok
    local result

    local timer = (vim.uv or vim.loop).new_timer()
    timer:start(0, 0, function()
      ok, result = pcall(env.non_interactive)
      timer:stop()
      timer:close()
    end)

    local completed = vim.wait(100, function()
      return ok ~= nil
    end)

    assert.are.equal(true, completed)
    assert.are.equal(true, ok)
    assert.are.equal("0", result.GIT_TERMINAL_PROMPT)
    assert.are.equal("never", result.GCM_INTERACTIVE)
  end)

  it("marks only running checks as checking and leaves the rest queued", function()
    local items = {}
    for index = 1, 11 do
      items[index] = {
        name = string.format("plugin-%d", index),
        active = true,
        path = string.format("/tmp/plugin-%d", index),
        rev = string.format("%08d", index),
      }
    end

    vim.system = function(_, _, _)
      return {}
    end

    updates.check_loaded(items, { force = true })

    local decorated = updates.decorate(vim.deepcopy(items))

    for index = 1, 10 do
      assert.are.equal("checking", decorated[index].update_info.status)
    end
    assert.are.equal("queued", decorated[11].update_info.status)
  end)

  it("reuses a recent completed batch without rerunning git commands", function()
    local system_calls = 0
    local first_summary

    vim.system = function(command, _, callback)
      system_calls = system_calls + 1

      local result
      if command[2] == "rev-parse" and command[3] == "HEAD" then
        result = { code = 0, stdout = "abcdef01\n", stderr = "" }
      elseif command[2] == "fetch" then
        result = { code = 0, stdout = "", stderr = "" }
      elseif command[2] == "rev-parse" and command[3] == "--abbrev-ref" then
        result = { code = 0, stdout = "origin/main\n", stderr = "" }
      elseif command[2] == "rev-list" and command[3] == "-1" and command[4] == "origin/main" then
        result = { code = 0, stdout = "abcdef01\n", stderr = "" }
      else
        error("unexpected git command: " .. table.concat(command, " "))
      end

      vim.schedule(function()
        callback(result)
      end)

      return {}
    end

    local items = {
      { name = "lazy.nvim", active = true, path = "/tmp/lazy.nvim", rev = "abcdef01", spec = {} },
    }

    updates.check_loaded(items, {
      ttl_ms = 1000,
      on_complete = function(summary)
        first_summary = summary
      end,
    })

    assert.are.equal(
      true,
      vim.wait(100, function()
        return first_summary ~= nil
      end)
    )

    local before = system_calls
    local started = updates.check_loaded(items, { ttl_ms = 1000 })

    assert.are.equal(0, started)
    assert.are.equal(before, system_calls)
  end)

  it("force bypasses recent batch cache", function()
    local system_calls = 0
    local first_summary
    local second_summary

    vim.system = function(command, _, callback)
      system_calls = system_calls + 1

      local result
      if command[2] == "rev-parse" and command[3] == "HEAD" then
        result = { code = 0, stdout = "abcdef01\n", stderr = "" }
      elseif command[2] == "fetch" then
        result = { code = 0, stdout = "", stderr = "" }
      elseif command[2] == "rev-parse" and command[3] == "--abbrev-ref" then
        result = { code = 0, stdout = "origin/main\n", stderr = "" }
      elseif command[2] == "rev-list" and command[3] == "-1" and command[4] == "origin/main" then
        result = { code = 0, stdout = "abcdef01\n", stderr = "" }
      else
        error("unexpected git command: " .. table.concat(command, " "))
      end

      vim.schedule(function()
        callback(result)
      end)

      return {}
    end

    local items = {
      { name = "lazy.nvim", active = true, path = "/tmp/lazy.nvim", rev = "abcdef01", spec = {} },
    }

    updates.check_loaded(items, {
      ttl_ms = 1000,
      on_complete = function(summary)
        first_summary = summary
      end,
    })

    assert.are.equal(
      true,
      vim.wait(100, function()
        return first_summary ~= nil
      end)
    )

    local before = system_calls

    updates.check_loaded(items, {
      force = true,
      ttl_ms = 1000,
      on_complete = function(summary)
        second_summary = summary
      end,
    })

    assert.are.equal(
      true,
      vim.wait(100, function()
        return second_summary ~= nil
      end)
    )
    assert.is_true(system_calls > before)
  end)
end)
