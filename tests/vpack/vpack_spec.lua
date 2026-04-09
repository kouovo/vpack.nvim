local vpack = require("vpack")
local actions = require("vpack.ui.actions")
local backend = require("vpack.backend.pack")
local updates = require("vpack.backend.updates")
local state = require("vpack.state")

local original_backend = {}
local original_updates = {}
local original_notify = vim.notify

describe("vpack", function()
  before_each(function()
    vpack.close()
    vpack.setup({
      log = {
        path = vim.fn.tempname(),
      },
    })

    original_backend.list = backend.list
    original_backend.update = backend.update
    original_backend.update_async = backend.update_async
    original_backend.update_all = backend.update_all
    original_backend.update_all_async = backend.update_all_async
    original_backend.delete = backend.delete
    original_backend.clean = backend.clean

    original_updates.decorate = updates.decorate
    original_updates.check_loaded = updates.check_loaded

    backend.list = function()
      return {}
    end

    backend.update_async = nil
    backend.update_all_async = nil

    updates.decorate = function(items)
      return items
    end

    updates.check_loaded = function() end
  end)

  after_each(function()
    vpack.close()
    vim.notify = original_notify

    backend.list = original_backend.list
    backend.update = original_backend.update
    backend.update_async = original_backend.update_async
    backend.update_all = original_backend.update_all
    backend.update_all_async = original_backend.update_all_async
    backend.delete = original_backend.delete
    backend.clean = original_backend.clean

    updates.decorate = original_updates.decorate
    updates.check_loaded = original_updates.check_loaded
  end)

  it("merges user window config", function()
    vpack.setup({
      window = {
        border = "single",
      },
    })

    assert.are.equal("single", vpack.config.window.border)
  end)

  it("auto-refreshes the open window after PackChanged", function()
    local calls = 0

    backend.list = function()
      calls = calls + 1

      if calls == 1 then
        return {
          { name = "lazy.nvim", short_name = "lazy.nvim", active = true, rev = "abcdef01", spec = {} },
        }
      end

      return {
        { name = "lazy.nvim", short_name = "lazy.nvim", active = true, rev = "99999999", spec = {} },
      }
    end

    vpack.open()
    vpack.on_pack_changed()
    vim.wait(50, function()
      return state.get().items[1] and state.get().items[1].rev == "99999999"
    end)

    assert.are.equal("99999999", state.get().items[1].rev)
  end)

  it("notifies after updating the selected package", function()
    local updated
    local notice

    backend.list = function()
      return {
        { name = "lazy.nvim", short_name = "lazy.nvim", active = true, rev = "abcdef01", spec = {} },
        { name = "plenary.nvim", short_name = "plenary.nvim", active = false, rev = "12345678", spec = {} },
      }
    end

    backend.update = function(name)
      updated = name
    end

    vim.notify = function(message)
      notice = message
    end

    local view = vpack.open()
    vim.api.nvim_win_set_cursor(view.win, { 7, 0 })

    actions.update_current()

    assert.are.equal("plenary.nvim", updated)
    assert.are.equal("Updating plenary.nvim", notice)
  end)

  it("updates only available packages", function()
    local updated_names

    backend.list = function()
      return {
        { name = "lazy.nvim", short_name = "lazy.nvim", active = true, rev = "abcdef01", spec = {} },
        { name = "mini.nvim", short_name = "mini.nvim", active = true, rev = "12345678", spec = {} },
      }
    end

    updates.decorate = function(items)
      items[1].update_info =
        { status = "available", current_rev = "abcdef01", target_rev = "fedcba98", pending_count = 1 }
      items[2].update_info =
        { status = "current", current_rev = "12345678", target_rev = "12345678", pending_count = 0 }
      return items
    end

    backend.update_all = function(names)
      updated_names = names
    end

    vpack.open()
    actions.update_all()

    assert.are.same({ "lazy.nvim" }, updated_names)
  end)

  it("asks to check first when no update results exist", function()
    local notice

    backend.list = function()
      return {
        { name = "lazy.nvim", short_name = "lazy.nvim", active = true, rev = "abcdef01", spec = {} },
      }
    end

    backend.update_all = function()
      error("update_all should not run without check results")
    end

    vim.notify = function(message)
      notice = message
    end

    vpack.open()
    actions.update_all()

    assert.are.equal("No checked updates available, press c first", notice)
  end)

  it("deletes the selected package", function()
    local deleted

    backend.list = function()
      return {
        { name = "lazy.nvim", short_name = "lazy.nvim", active = true, rev = "abcdef01", spec = {} },
        { name = "plenary.nvim", short_name = "plenary.nvim", active = false, rev = "12345678", spec = {} },
      }
    end

    backend.delete = function(name)
      deleted = name
    end

    local view = vpack.open()
    vim.api.nvim_win_set_cursor(view.win, { 7, 0 })

    actions.delete_current()

    assert.are.equal("plenary.nvim", deleted)
  end)

  it("does not try to delete an active package", function()
    local notice

    backend.list = function()
      return {
        { name = "alpha-nvim", short_name = "alpha-nvim", active = true, rev = "abcdef01", spec = {} },
      }
    end

    backend.delete = function()
      error("delete should not be called for active packages")
    end

    vim.notify = function(message)
      notice = message
    end

    vpack.open()
    actions.delete_current()

    assert.are.equal("Cannot delete active package alpha-nvim", notice)
  end)

  it("cleans all non-active packages", function()
    local cleaned
    local notice

    backend.list = function()
      return {
        { name = "lazy.nvim", short_name = "lazy.nvim", active = true, rev = "abcdef01", spec = {} },
        { name = "plenary.nvim", short_name = "plenary.nvim", active = false, rev = "12345678", spec = {} },
        { name = "mini.nvim", short_name = "mini.nvim", active = false, rev = "fedcba98", spec = {} },
      }
    end

    backend.clean = function(names)
      cleaned = names
    end

    vim.notify = function(message)
      notice = message
    end

    vpack.open()
    actions.clean()

    assert.are.same({ "plenary.nvim", "mini.nvim" }, cleaned)
    assert.are.equal("Cleaned 2 packages", notice)
  end)

  it("renders an updates available section and shows commit previews in details", function()
    backend.list = function()
      return {
        {
          name = "lazy.nvim",
          short_name = "lazy.nvim",
          active = true,
          rev = "abcdef01",
          path = "/tmp/lazy.nvim",
          spec = {},
        },
        {
          name = "mini.nvim",
          short_name = "mini.nvim",
          active = true,
          rev = "12345678",
          path = "/tmp/mini.nvim",
          spec = {},
        },
        {
          name = "plenary.nvim",
          short_name = "plenary.nvim",
          active = false,
          rev = "87654321",
          path = "/tmp/plenary.nvim",
          spec = {},
        },
      }
    end

    updates.decorate = function(items)
      items[1].update_info = {
        status = "available",
        current_rev = "abcdef01",
        target_rev = "fedcba98",
        pending_count = 6,
        commits = {
          "fedcba9 feat: first incoming change",
          "edcba98 fix: second incoming change",
          "dcba987 docs: third incoming change",
          "cba9876 refactor: fourth incoming change",
          "ba98765 test: fifth incoming change",
        },
      }

      return items
    end

    local view = vpack.open()
    local lines = vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
    local content = table.concat(lines, "\n")

    assert.matches("Updates available %(1%)", content)
    assert.matches("Loaded %(1%)", content)
    assert.matches("Unloaded %(1%)", content)

    vim.api.nvim_win_set_cursor(view.win, { 5, 0 })
    actions.toggle_details()

    lines = vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
    content = table.concat(lines, "\n")

    assert.matches("target%s+fedcba9", content)
    assert.matches("ahead%s+6 commits", content)
    assert.matches("feat: first incoming change", content)
    assert.matches("test: fifth incoming change", content)
    assert.matches("%.%.%. and 1 more", content)
  end)

  it("checks updates for loaded packages without blocking the initial render", function()
    local checked_names
    local cache = {}

    backend.list = function()
      return {
        {
          name = "lazy.nvim",
          short_name = "lazy.nvim",
          active = true,
          rev = "abcdef01",
          path = "/tmp/lazy.nvim",
          spec = {},
        },
        {
          name = "mini.nvim",
          short_name = "mini.nvim",
          active = true,
          rev = "12345678",
          path = "/tmp/mini.nvim",
          spec = {},
        },
        {
          name = "plenary.nvim",
          short_name = "plenary.nvim",
          active = false,
          rev = "87654321",
          path = "/tmp/plenary.nvim",
          spec = {},
        },
      }
    end

    updates.decorate = function(items)
      for _, item in ipairs(items) do
        item.update_info = cache[item.name]
      end

      return items
    end

    updates.check_loaded = function(items, opts)
      checked_names = vim
        .iter(items)
        :map(function(item)
          return item.name
        end)
        :totable()

      cache["lazy.nvim"] = {
        status = "available",
        current_rev = "abcdef01",
        target_rev = "fedcba98",
        pending_count = 2,
        commits = {
          "fedcba9 feat: first incoming change",
          "edcba98 fix: second incoming change",
        },
      }

      opts.on_change()
    end

    local view = vpack.open()
    local lines = vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
    local initial = table.concat(lines, "\n")

    assert.matches("Loaded %(2%)", initial)
    assert.is_nil(initial:match("Updates available %(1%)"))

    local updated = vim.wait(100, function()
      local content = table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")
      return content:match("Updates available %(1%)") ~= nil
    end)

    assert.are.equal(true, updated)
    assert.are.same({ "lazy.nvim", "mini.nvim" }, checked_names)
  end)

  it("keeps the current selection when the updates section appears asynchronously", function()
    local updated
    local cache = {}

    backend.list = function()
      return {
        {
          name = "lazy.nvim",
          short_name = "lazy.nvim",
          active = true,
          rev = "abcdef01",
          path = "/tmp/lazy.nvim",
          spec = {},
        },
        {
          name = "mini.nvim",
          short_name = "mini.nvim",
          active = true,
          rev = "12345678",
          path = "/tmp/mini.nvim",
          spec = {},
        },
      }
    end

    backend.update = function(name)
      updated = name
    end

    updates.decorate = function(items)
      for _, item in ipairs(items) do
        item.update_info = cache[item.name]
      end

      return items
    end

    updates.check_loaded = function(_, opts)
      vim.schedule(function()
        cache["lazy.nvim"] = {
          status = "available",
          current_rev = "abcdef01",
          target_rev = "fedcba98",
          pending_count = 1,
          commits = {
            "fedcba9 feat: first incoming change",
          },
        }

        opts.on_change()
      end)
    end

    local view = vpack.open()
    vim.api.nvim_win_set_cursor(view.win, { 6, 0 })

    local refreshed = vim.wait(100, function()
      local content = table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")
      return content:match("Updates available %(1%)") ~= nil
    end)

    assert.are.equal(true, refreshed)

    actions.update_current()

    assert.are.equal("mini.nvim", updated)
  end)

  it("shows updating then updated during async package update", function()
    local done

    backend.list = function()
      return {
        {
          name = "lazy.nvim",
          short_name = "lazy.nvim",
          active = true,
          rev = "abcdef01",
          path = "/tmp/lazy.nvim",
          spec = {},
        },
      }
    end

    backend.update_async = function(name, callback)
      assert.are.equal("lazy.nvim", name)

      vim.schedule(function()
        callback({ ok = true, names = { name } })
        done = true
      end)
    end

    local view = vpack.open()
    actions.update_current()

    local content = table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")
    assert.matches("lazy%.nvim.-%[updating .-%]", content)

    local updated = vim.wait(100, function()
      local lines = vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
      return table.concat(lines, "\n"):match("lazy%.nvim.-%[updated%]") ~= nil and done
    end)

    assert.are.equal(true, updated)
  end)

  it("shows updating then updated during async update all", function()
    local done

    backend.list = function()
      return {
        {
          name = "lazy.nvim",
          short_name = "lazy.nvim",
          active = true,
          rev = "abcdef01",
          path = "/tmp/lazy.nvim",
          spec = {},
        },
        {
          name = "mini.nvim",
          short_name = "mini.nvim",
          active = true,
          rev = "12345678",
          path = "/tmp/mini.nvim",
          spec = {},
        },
        {
          name = "plenary.nvim",
          short_name = "plenary.nvim",
          active = true,
          rev = "87654321",
          path = "/tmp/plenary.nvim",
          spec = {},
        },
      }
    end

    updates.decorate = function(items)
      for _, item in ipairs(items) do
        item.update_info = {
          status = "available",
          current_rev = item.rev,
          target_rev = "ffffffff",
          pending_count = 1,
        }
      end

      return items
    end

    backend.update_all_async = function(callback, names)
      assert.are.same({ "lazy.nvim", "mini.nvim", "plenary.nvim" }, names)

      vim.schedule(function()
        callback({ ok = true, names = { "lazy.nvim", "mini.nvim", "plenary.nvim" } })
        done = true
      end)
    end

    local view = vpack.open()
    actions.update_all()

    local content = table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")
    assert.matches("lazy%.nvim.-%[updating .-%]", content)
    assert.matches("mini%.nvim.-%[updating .-%]", content)
    assert.matches("plenary%.nvim.-%[updating .-%]", content)

    local updated = vim.wait(100, function()
      local lines = vim.api.nvim_buf_get_lines(view.buf, 0, -1, false)
      local current = table.concat(lines, "\n")
      return current:match("lazy%.nvim.-%[updated%]") ~= nil
        and current:match("mini%.nvim.-%[updated%]") ~= nil
        and current:match("plenary%.nvim.-%[updated%]") ~= nil
        and done
    end)

    assert.are.equal(true, updated)
  end)

  it("does not start the same async update twice", function()
    local calls = 0

    backend.list = function()
      return {
        {
          name = "lazy.nvim",
          short_name = "lazy.nvim",
          active = true,
          rev = "abcdef01",
          path = "/tmp/lazy.nvim",
          spec = {},
        },
      }
    end

    backend.update_async = function(_, _)
      calls = calls + 1
    end

    vpack.open()
    actions.update_current()
    actions.update_current()

    assert.are.equal(1, calls)
  end)

  it("ignores async update completion after closing the window", function()
    local callback

    backend.list = function()
      return {
        {
          name = "lazy.nvim",
          short_name = "lazy.nvim",
          active = true,
          rev = "abcdef01",
          path = "/tmp/lazy.nvim",
          spec = {},
        },
      }
    end

    backend.update_async = function(_, on_done)
      callback = on_done
    end

    local view = vpack.open()
    actions.update_current()

    local content = table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")
    assert.matches("lazy%.nvim.-%[updating .-%]", content)

    vpack.close()
    callback({ ok = true, names = { "lazy.nvim" } })
    vim.wait(50)

    view = vpack.open()
    content = table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")

    assert.is_nil(content:match("lazy%.nvim.-%[updated%]"))
  end)

  it("shows the check-updates key and forces a recheck", function()
    local checked_names
    local forced
    local cache = {}

    backend.list = function()
      return {
        {
          name = "lazy.nvim",
          short_name = "lazy.nvim",
          active = true,
          rev = "abcdef01",
          path = "/tmp/lazy.nvim",
          spec = {},
        },
        {
          name = "plenary.nvim",
          short_name = "plenary.nvim",
          active = false,
          rev = "12345678",
          path = "/tmp/plenary.nvim",
          spec = {},
        },
      }
    end

    updates.decorate = function(items)
      for _, item in ipairs(items) do
        item.update_info = cache[item.name]
      end

      return items
    end

    updates.check_loaded = function(items, opts)
      checked_names = vim
        .iter(items)
        :map(function(item)
          return item.name
        end)
        :totable()
      forced = opts.force
      cache["lazy.nvim"] = { status = "checking", current_rev = "abcdef01" }
      opts.on_change()
    end

    local view = vpack.open()
    local content = table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")
    assert.matches("%[c%] check", content)

    actions.check_updates()
    vim.wait(50)

    content = table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")
    assert.are.same({ "lazy.nvim" }, checked_names)
    assert.are.equal(true, forced)
    assert.matches("lazy%.nvim.-%[checking", content)
  end)

  it("does not force a recheck during refresh", function()
    local forces = {}

    backend.list = function()
      return {
        {
          name = "lazy.nvim",
          short_name = "lazy.nvim",
          active = true,
          rev = "abcdef01",
          path = "/tmp/lazy.nvim",
          spec = {},
        },
      }
    end

    updates.check_loaded = function(_, opts)
      table.insert(forces, opts.force == true)
      return 0
    end

    vpack.open()
    vpack.refresh()

    assert.are.same({ false, false }, forces)
  end)

  it("notifies when a manual check completes", function()
    local cache = {}
    local notices = {}
    local calls = 0

    backend.list = function()
      return {
        {
          name = "lazy.nvim",
          short_name = "lazy.nvim",
          active = true,
          rev = "abcdef01",
          path = "/tmp/lazy.nvim",
          spec = {},
        },
        {
          name = "mini.nvim",
          short_name = "mini.nvim",
          active = true,
          rev = "12345678",
          path = "/tmp/mini.nvim",
          spec = {},
        },
      }
    end

    updates.decorate = function(items)
      for _, item in ipairs(items) do
        item.update_info = cache[item.name]
      end

      return items
    end

    updates.check_loaded = function(items, opts)
      calls = calls + 1
      if calls == 1 then
        return
      end

      cache["lazy.nvim"] = {
        status = "available",
        current_rev = "abcdef01",
        target_rev = "fedcba98",
        pending_count = 1,
        commits = { "fedcba9 feat: first incoming change" },
      }
      cache["mini.nvim"] = {
        status = "current",
        current_rev = "12345678",
        target_rev = "12345678",
        pending_count = 0,
        commits = {},
      }

      vim.schedule(function()
        opts.on_change(items[1], cache["lazy.nvim"])
        opts.on_change(items[2], cache["mini.nvim"])
        opts.on_complete({
          total = 2,
          available = 1,
          current = 1,
          unsupported = 0,
          error = 0,
          timed_out = 0,
        })
      end)
    end

    vim.notify = function(message)
      table.insert(notices, message)
    end

    vpack.open()
    actions.check_updates()

    local completed = vim.wait(100, function()
      return notices[#notices] == "Check complete: 1 update available, 1 up-to-date"
    end)

    assert.are.equal(true, completed)
  end)

  it("shows terminal check states in the list", function()
    backend.list = function()
      return {
        {
          name = "lazy.nvim",
          short_name = "lazy.nvim",
          active = true,
          rev = "abcdef01",
          path = "/tmp/lazy.nvim",
          spec = {},
        },
        {
          name = "mini.nvim",
          short_name = "mini.nvim",
          active = true,
          rev = "12345678",
          path = "/tmp/mini.nvim",
          spec = {},
        },
        {
          name = "plenary.nvim",
          short_name = "plenary.nvim",
          active = true,
          rev = "87654321",
          path = "/tmp/plenary.nvim",
          spec = {},
        },
        {
          name = "queued.nvim",
          short_name = "queued.nvim",
          active = true,
          rev = "a1b2c3d4",
          path = "/tmp/queued.nvim",
          spec = {},
        },
      }
    end

    updates.decorate = function(items)
      items[1].update_info = {
        status = "current",
        current_rev = "abcdef01",
        target_rev = "abcdef01",
        pending_count = 0,
        commits = {},
      }
      items[2].update_info = {
        status = "unsupported",
        current_rev = "12345678",
        message = "No upstream tracking branch",
      }
      items[3].update_info = {
        status = "error",
        current_rev = "87654321",
        message = "Failed to fetch updates",
      }

      items[4].update_info = {
        status = "queued",
        current_rev = "a1b2c3d4",
      }

      return items
    end

    local view = vpack.open()
    local content = table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")

    assert.matches("lazy%.nvim.-%[up%-to%-date%]", content)
    assert.matches("mini%.nvim.-%[no upstream%]", content)
    assert.matches("plenary%.nvim.-%[check failed%]", content)
    assert.matches("queued%.nvim.-%[queued%]", content)
  end)

  it("shows no changes when an async package update makes no changes", function()
    backend.list = function()
      return {
        {
          name = "lazy.nvim",
          short_name = "lazy.nvim",
          active = true,
          rev = "abcdef01",
          path = "/tmp/lazy.nvim",
          spec = {},
        },
      }
    end

    backend.update_async = function(name, callback)
      vim.schedule(function()
        callback({ ok = true, names = { name }, changed_names = {} })
      end)
    end

    local view = vpack.open()
    actions.update_current()

    local done = vim.wait(100, function()
      local content = table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")
      return content:match("lazy%.nvim.-%[no changes%]") ~= nil
    end)

    assert.are.equal(true, done)
  end)

  it("auto-clears finished update states after a short delay", function()
    backend.list = function()
      return {
        {
          name = "lazy.nvim",
          short_name = "lazy.nvim",
          active = true,
          rev = "abcdef01",
          path = "/tmp/lazy.nvim",
          spec = {},
        },
      }
    end

    backend.update_async = function(name, callback)
      vim.schedule(function()
        callback({ ok = true, names = { name } })
      end)
    end

    local view = vpack.open()
    actions.update_current()

    local showed = vim.wait(100, function()
      local content = table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")
      return content:match("lazy%.nvim.-%[updated%]") ~= nil
    end)
    assert.are.equal(true, showed)

    local cleared = vim.wait(1500, function()
      local content = table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")
      return content:match("lazy%.nvim.-%[updated%]") == nil
    end)

    assert.are.equal(true, cleared)
  end)

  it("debounces repeated async update-check refreshes", function()
    local original_render = vpack.render
    local render_calls = 0

    backend.list = function()
      return {
        {
          name = "lazy.nvim",
          short_name = "lazy.nvim",
          active = true,
          rev = "abcdef01",
          path = "/tmp/lazy.nvim",
          spec = {},
        },
      }
    end

    vpack.render = function(...)
      render_calls = render_calls + 1
      return original_render(...)
    end

    updates.check_loaded = function(_, opts)
      vim.schedule(opts.on_change)
      vim.schedule(opts.on_change)
      vim.schedule(opts.on_change)
    end

    vpack.open()
    local settled = vim.wait(100, function()
      return render_calls >= 2
    end)

    vpack.render = original_render

    assert.are.equal(true, settled)
    assert.are.equal(2, render_calls)
  end)

  it("keeps the cursor position while the updating spinner is active", function()
    backend.list = function()
      return {
        {
          name = "lazy.nvim",
          short_name = "lazy.nvim",
          active = true,
          rev = "abcdef01",
          path = "/tmp/lazy.nvim",
          spec = {},
        },
        {
          name = "mini.nvim",
          short_name = "mini.nvim",
          active = true,
          rev = "12345678",
          path = "/tmp/mini.nvim",
          spec = {},
        },
      }
    end

    backend.update_async = function(_, _)
      -- keep pending so spinner continues
    end

    local view = vpack.open()
    actions.update_current()
    vim.api.nvim_win_set_cursor(view.win, { 6, 0 })

    vim.wait(150)

    assert.are.same({ 6, 0 }, vim.api.nvim_win_get_cursor(view.win))
  end)

  it("distinguishes updated, failed, and unchanged packages for update all", function()
    backend.list = function()
      return {
        {
          name = "lazy.nvim",
          short_name = "lazy.nvim",
          active = true,
          rev = "abcdef01",
          path = "/tmp/lazy.nvim",
          spec = {},
        },
        {
          name = "mini.nvim",
          short_name = "mini.nvim",
          active = true,
          rev = "12345678",
          path = "/tmp/mini.nvim",
          spec = {},
        },
        {
          name = "plenary.nvim",
          short_name = "plenary.nvim",
          active = true,
          rev = "87654321",
          path = "/tmp/plenary.nvim",
          spec = {},
        },
      }
    end

    updates.decorate = function(items)
      for _, item in ipairs(items) do
        item.update_info = {
          status = "available",
          current_rev = item.rev,
          target_rev = "ffffffff",
          pending_count = 1,
        }
      end

      return items
    end

    backend.update_all_async = function(callback, names)
      assert.are.same({ "lazy.nvim", "mini.nvim", "plenary.nvim" }, names)

      vim.schedule(function()
        callback({
          ok = true,
          names = { "lazy.nvim", "mini.nvim", "plenary.nvim" },
          changed_names = { "lazy.nvim" },
          failed_names = { ["mini.nvim"] = "network error" },
        })
      end)
    end

    local view = vpack.open()
    actions.update_all()

    local done = vim.wait(100, function()
      local content = table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")
      return content:match("lazy%.nvim.-%[updated%]") ~= nil
        and content:match("mini%.nvim.-%[update failed%]") ~= nil
        and content:match("plenary%.nvim.-%[no changes%]") ~= nil
    end)

    assert.are.equal(true, done)
  end)
end)
