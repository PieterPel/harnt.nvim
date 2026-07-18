---@diagnostic disable: undefined-field, need-check-nil
---@diagnostic disable: param-type-mismatch, missing-fields, return-type-mismatch, missing-return
-- luassert's narrowing is invisible to emmylua; and this spec deliberately feeds
-- invalid/partial provider tables to exercise registry validation.

local registry = require("harnt.providers")

--- A minimal valid provider stub.
---@param name string
local function stub(name)
  return {
    name = name,
    detect = function()
      return true
    end,
    start = function()
      return {}
    end,
  }
end

before_each(function()
  registry.clear()
end)

describe("providers registry", function()
  it("registers and retrieves a provider", function()
    local p = stub("alpha")
    registry.register(p)
    assert.equals(p, registry.get("alpha"))
  end)

  it("returns nil for an unknown provider", function()
    assert.is_nil(registry.get("nope"))
  end)

  it("lists registered names sorted", function()
    registry.register(stub("zeta"))
    registry.register(stub("alpha"))
    registry.register(stub("mu"))
    assert.same({ "alpha", "mu", "zeta" }, registry.list())
  end)

  it("replaces a provider registered under the same name", function()
    registry.register(stub("dup"))
    local second = stub("dup")
    registry.register(second)
    assert.equals(second, registry.get("dup"))
    assert.equals(1, #registry.list())
  end)

  it("is_available reflects detect()", function()
    registry.register({
      name = "off",
      detect = function()
        return false
      end,
      start = function()
        return {}
      end,
    })
    assert.is_false(registry.is_available("off"))
    registry.register(stub("on"))
    assert.is_true(registry.is_available("on"))
    assert.is_false(registry.is_available("missing"))
  end)

  it("rejects invalid provider tables with a clear error", function()
    assert.has_error(function()
      registry.register(nil)
    end)
    assert.has_error(function()
      registry.register({})
    end)
    assert.has_error(function()
      registry.register({ name = "x" }) -- missing detect/start
    end)
    assert.has_error(function()
      registry.register({ name = "x", detect = function() end }) -- missing start
    end)
  end)
end)
