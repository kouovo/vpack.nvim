local vpack = require("vpack")
local actions = require("vpack.ui.actions")
local backend = require("vpack.backend.pack")
local state = require("vpack.state")

local original_backend = {}
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
    original_backend.update_all = backend.update_all
    original_backend.delete = backend.delete
    original_backend.clean = backend.clean

    backend.list = function()
      return {}
    end
  end)

  after_each(function()
    vpack.close()
    vim.notify = original_notify

    backend.list = original_backend.list
    backend.update = original_backend.update
    backend.update_all = original_backend.update_all
    backend.delete = original_backend.delete
    backend.clean = original_backend.clean
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
    vim.api.nvim_win_set_cursor(view.win, { 9, 0 })

    actions.update_current()

    assert.are.equal("plenary.nvim", updated)
    assert.are.equal("Updating plenary.nvim", notice)
  end)

  it("updates all packages", function()
    local called = false

    backend.update_all = function()
      called = true
    end

    vpack.open()
    actions.update_all()

    assert.are.equal(true, called)
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
    vim.api.nvim_win_set_cursor(view.win, { 9, 0 })

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

end)
