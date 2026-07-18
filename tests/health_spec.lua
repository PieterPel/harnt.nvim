---@diagnostic disable: undefined-field, need-check-nil, inject-field, return-type-mismatch
-- luassert narrowing is invisible to emmylua; the tests stub vim.health.* and
-- use partial provider doubles.

local health = require("harnt.health")
local registry = require("harnt.providers")

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

  it("reports available vs unavailable providers", function()
    registry.register({
      name = "up",
      detect = function()
        return true
      end,
      start = function()
        return {}
      end,
    })
    registry.register({
      name = "down",
      detect = function()
        return false
      end,
      start = function()
        return {}
      end,
    })
    health.check()

    local ok_joined = table.concat(calls.ok, "\n")
    local warn_joined = table.concat(calls.warn, "\n")
    assert.is_truthy(ok_joined:find("up: available"))
    assert.is_truthy(warn_joined:find("down"))
  end)
end)
