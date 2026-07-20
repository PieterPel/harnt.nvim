---@diagnostic disable: undefined-field, need-check-nil
---@diagnostic disable: param-type-mismatch, missing-fields, return-type-mismatch, missing-return
-- luassert's narrowing is invisible to emmylua; and this spec deliberately feeds
-- invalid/partial provider tables to exercise registry validation.

local registry = require("harnt.providers")

--- A complete valid provider stub. The contract is total, so a registrable
--- provider must define every capability; `pull_selection` satisfies the
--- push-or-pull selection rule.
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
    cmd = {},
    env = function()
      return {}
    end,
    review = function() end,
    health = function() end,
    on_mention = function() end,
    pull_selection = function()
      return nil
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
    local off = stub("off")
    off.detect = function()
      return false
    end
    registry.register(off)
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

  it("rejects a provider missing a required capability method", function()
    -- The contract is total: dropping any capability method is a registration
    -- error, not a silent no-op.
    for _, field in ipairs({ "cmd", "env", "review", "health", "on_mention" }) do
      local p = stub("cap_" .. field)
      p[field] = nil
      -- The registered error message names the missing field, so match on it —
      -- this also proves each field is individually enforced, not just one.
      assert.has_error(
        function()
          registry.register(p)
        end,
        ('register_provider: provider "cap_%s" must define %s (%s)'):format(
          field,
          field,
          field == "cmd" and "table or function" or "function"
        )
      )
    end
  end)

  it("rejects a provider that serves the selection neither by push nor pull", function()
    local p = stub("no_selection")
    p.pull_selection = nil -- stub has no push_selection either
    assert.has_error(function()
      registry.register(p)
    end)
  end)

  it("accepts a provider that serves the selection by push only", function()
    local p = stub("pusher")
    p.pull_selection = nil
    p.push_selection = function() end
    assert.has_no_error(function()
      registry.register(p)
    end)
  end)
end)
