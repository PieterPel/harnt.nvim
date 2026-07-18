---@diagnostic disable: undefined-field, need-check-nil, inject-field, return-type-mismatch
-- luassert narrowing is invisible to emmylua; the tests stub vim.notify and use
-- partial provider doubles.

local harnt = require("harnt")
local registry = require("harnt.providers")

local notifications
local orig_notify

before_each(function()
  notifications = {}
  orig_notify = vim.notify
  vim.notify = function(msg, level)
    table.insert(notifications, { msg = msg, level = level })
  end
end)

after_each(function()
  vim.notify = orig_notify
  registry.clear()
end)

describe("harnt.setup", function()
  it("delegates to config and returns the merged options", function()
    local opts = harnt.setup({})
    assert.same({ diff = {}, approvals = {}, keymaps = {} }, opts)
  end)
end)

describe("harnt.register_provider", function()
  it("registers a provider into the registry", function()
    harnt.register_provider({
      name = "p",
      detect = function()
        return true
      end,
      start = function()
        return {}
      end,
    })
    assert.is_true(registry.is_available("p"))
  end)
end)

describe("harnt.dispatch", function()
  it("runs a known subcommand with its args", function()
    local got
    harnt.subcommands.spec_probe = function(args)
      got = args
    end
    harnt.dispatch("spec_probe", { "a", "b" })
    assert.same({ "a", "b" }, got)
    harnt.subcommands.spec_probe = nil
  end)

  it("notifies an error for an unknown subcommand", function()
    harnt.dispatch("bogus")
    assert.equals(1, #notifications)
    assert.equals(vim.log.levels.ERROR, notifications[1].level)
    assert.is_truthy(notifications[1].msg:find("unknown"))
  end)

  it("notifies usage when no subcommand is given", function()
    harnt.dispatch(nil)
    assert.equals(1, #notifications)
    assert.equals(vim.log.levels.INFO, notifications[1].level)
  end)

  it("exposes sorted subcommand names", function()
    local names = harnt.subcommand_names()
    assert.is_true(vim.tbl_contains(names, "health"))
  end)
end)

describe("plugin/harnt.lua", function()
  it("defines the :Harnt user command", function()
    vim.g.loaded_harnt = nil
    dofile("plugin/harnt.lua")
    assert.equals(2, vim.fn.exists(":Harnt"))
  end)
end)

describe("harnt.dispatch diff commands", function()
  it("accept notifies when there is no diff", function()
    harnt.dispatch("accept")
    assert.is_true(#notifications >= 1)
    assert.equals(vim.log.levels.WARN, notifications[#notifications].level)
  end)

  it("reject notifies when there is no diff", function()
    harnt.dispatch("reject")
    assert.equals(vim.log.levels.WARN, notifications[#notifications].level)
  end)
end)
