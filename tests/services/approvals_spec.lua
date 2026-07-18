---@diagnostic disable: undefined-field, need-check-nil
-- (luassert extends `assert`; its narrowing is invisible to emmylua)

local approvals = require("harnt.services.approvals")

--- A chooser that always answers with `decision` and records how many times it
--- was consulted, so tests can assert "always" decisions skip the prompt.
local function scripted(decision)
  local calls = 0
  local fn = function(_req, on_choice)
    calls = calls + 1
    on_choice(decision)
  end
  return fn, function()
    return calls
  end
end

before_each(function()
  approvals.reset()
  approvals.set_chooser(nil)
end)

describe("approvals.request", function()
  it("allow_once allows without remembering", function()
    local chooser, count = scripted("allow_once")
    approvals.set_chooser(chooser)

    local allowed, decision
    approvals.request({ key = "cmd:ls", prompt = "run ls?" }, function(a, d)
      allowed, decision = a, d
    end)
    assert.is_true(allowed)
    assert.equals("allow_once", decision)

    -- second request must prompt again (nothing remembered)
    approvals.request({ key = "cmd:ls", prompt = "run ls?" }, function() end)
    assert.equals(2, count())
  end)

  it("deny_once denies without remembering", function()
    local chooser, count = scripted("deny_once")
    approvals.set_chooser(chooser)

    local allowed
    approvals.request({ key = "cmd:rm", prompt = "run rm?" }, function(a)
      allowed = a
    end)
    assert.is_false(allowed)

    approvals.request({ key = "cmd:rm", prompt = "run rm?" }, function() end)
    assert.equals(2, count())
  end)

  it("allow_always is remembered and skips the prompt next time", function()
    local chooser, count = scripted("allow_always")
    approvals.set_chooser(chooser)

    local first
    approvals.request({ key = "tool:openDiff", prompt = "?" }, function(a)
      first = a
    end)
    assert.is_true(first)
    assert.equals(1, count())

    local second_allowed, second_decision
    approvals.request({ key = "tool:openDiff", prompt = "?" }, function(a, d)
      second_allowed, second_decision = a, d
    end)
    assert.is_true(second_allowed)
    assert.equals("allow_always", second_decision)
    assert.equals(1, count()) -- chooser NOT consulted again
  end)

  it("deny_always is remembered and denies without prompting", function()
    local chooser, count = scripted("deny_always")
    approvals.set_chooser(chooser)

    approvals.request({ key = "tool:shell", prompt = "?" }, function() end)
    local allowed = true
    approvals.request({ key = "tool:shell", prompt = "?" }, function(a)
      allowed = a
    end)
    assert.is_false(allowed)
    assert.equals(1, count())
  end)

  it("remembers decisions per key independently", function()
    approvals.set_chooser(function(req, on_choice)
      on_choice(req.key == "a" and "allow_always" or "deny_always")
    end)
    approvals.request({ key = "a", prompt = "?" }, function() end)
    approvals.request({ key = "b", prompt = "?" }, function() end)

    local a_allowed, b_allowed
    approvals.request({ key = "a", prompt = "?" }, function(x)
      a_allowed = x
    end)
    approvals.request({ key = "b", prompt = "?" }, function(x)
      b_allowed = x
    end)
    assert.is_true(a_allowed)
    assert.is_false(b_allowed)
  end)

  it("reset() forgets remembered decisions", function()
    local chooser, count = scripted("allow_always")
    approvals.set_chooser(chooser)
    approvals.request({ key = "k", prompt = "?" }, function() end)
    approvals.reset()
    approvals.request({ key = "k", prompt = "?" }, function() end)
    assert.equals(2, count()) -- prompted again after reset
  end)
end)
