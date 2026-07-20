---@diagnostic disable: undefined-field, need-check-nil, inject-field, return-type-mismatch
-- luassert narrowing is invisible to emmylua; the tests stub vim.health.* and
-- use partial provider doubles.

local health = require("harnt.health")
local registry = require("harnt.providers")
local provider = require("tests.support.provider")

---@type table<string, string[]>
local calls
local orig = {}
local KEYS = { "start", "ok", "warn", "error", "info" }

before_each(function()
  calls = { start = {}, ok = {}, warn = {}, error = {}, info = {} }
  for _, k in ipairs(KEYS) do
    orig[k] = vim.health[k]
    vim.health[k] = function(msg)
      table.insert(calls[k], msg)
    end
  end
  registry.clear()
end)

after_each(function()
  for _, k in ipairs(KEYS) do
    vim.health[k] = orig[k]
  end
  registry.clear()
end)

describe("health.check", function()
  it("starts a harnt section and reports the Neovim version ok", function()
    health.check()
    assert.equals("harnt", calls.start[1])
    assert.is_true(#calls.ok >= 1)
    assert.equals(0, #calls.error)
  end)

  it("reports when no providers are registered", function()
    health.check()
    assert.is_true(#calls.info >= 1)
  end)

  it("delegates to each registered provider's health probe", function()
    -- `health` is a required capability, so check() calls it for every provider
    -- (no generic available/unavailable fallback). Each provider owns its report.
    registry.register(provider("up", {
      health = function(report)
        report.ok("up: all good")
      end,
    }))
    registry.register(provider("down", {
      health = function(report)
        report.warn("down: not authenticated")
      end,
    }))
    health.check()

    assert.is_truthy(table.concat(calls.ok, "\n"):find("up: all good"))
    assert.is_truthy(table.concat(calls.warn, "\n"):find("down: not authenticated"))
  end)
end)
