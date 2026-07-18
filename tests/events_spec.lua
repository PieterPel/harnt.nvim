---@diagnostic disable: undefined-field, need-check-nil
-- (luassert extends `assert`; its narrowing is invisible to emmylua)

local events = require("harnt.events")

describe("events.Emitter dispatch", function()
  it("delivers an event to its subscribers with (payload, event)", function()
    local bus = events.new({ autocmd = false })
    local got
    bus:on(events.TYPES.tool_started, function(payload, event)
      got = { payload = payload, event = event }
    end)
    bus:emit(events.TYPES.tool_started, { session = "s1", provider = { native = true } })

    assert.equals("tool.started", got.event)
    assert.equals("s1", got.payload.session)
    assert.same({ native = true }, got.payload.provider)
  end)

  it("does not deliver to subscribers of other events", function()
    local bus = events.new({ autocmd = false })
    local calls = 0
    bus:on(events.TYPES.diff_ready, function()
      calls = calls + 1
    end)
    bus:emit(events.TYPES.tool_completed, {})
    assert.equals(0, calls)
  end)

  it("delivers every event to a '*' wildcard subscriber", function()
    local bus = events.new({ autocmd = false })
    local seen = {}
    bus:on("*", function(_, event)
      table.insert(seen, event)
    end)
    bus:emit(events.TYPES.session_started, {})
    bus:emit(events.TYPES.session_completed, {})
    assert.same({ "session.started", "session.completed" }, seen)
  end)

  it("defaults the payload to an empty table", function()
    local bus = events.new({ autocmd = false })
    local got
    bus:on("*", function(payload)
      got = payload
    end)
    bus:emit(events.TYPES.message_delta)
    assert.same({}, got)
  end)
end)

describe("events.Emitter:on unsubscribe", function()
  it("stops delivering after the returned function is called", function()
    local bus = events.new({ autocmd = false })
    local calls = 0
    local off = bus:on(events.TYPES.tool_started, function()
      calls = calls + 1
    end)
    bus:emit(events.TYPES.tool_started)
    off()
    bus:emit(events.TYPES.tool_started)
    assert.equals(1, calls)
  end)

  it("removes only the unsubscribed handler, not its duplicates-in-spirit", function()
    local bus = events.new({ autocmd = false })
    local a, b = 0, 0
    local off_a = bus:on(events.TYPES.tool_started, function()
      a = a + 1
    end)
    bus:on(events.TYPES.tool_started, function()
      b = b + 1
    end)
    off_a()
    bus:emit(events.TYPES.tool_started)
    assert.equals(0, a)
    assert.equals(1, b)
  end)
end)

describe("events.Emitter autocmd mirror", function()
  it("fires a User HarntEvent autocmd carrying event + payload", function()
    local bus = events.new() -- autocmd on by default
    local received
    local group = vim.api.nvim_create_augroup("harnt_test_events", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = events.PATTERN,
      callback = function(args)
        received = args.data
      end,
    })

    bus:emit(events.TYPES.approval_requested, { session = "s2" })
    vim.api.nvim_del_augroup_by_id(group)

    assert.is_table(received)
    assert.equals("approval.requested", received.event)
    assert.equals("s2", received.payload.session)
  end)

  it("does not fire the autocmd when disabled", function()
    local bus = events.new({ autocmd = false })
    local fired = false
    local group = vim.api.nvim_create_augroup("harnt_test_events2", { clear = true })
    vim.api.nvim_create_autocmd("User", {
      group = group,
      pattern = events.PATTERN,
      callback = function()
        fired = true
      end,
    })

    bus:emit(events.TYPES.session_failed)
    vim.api.nvim_del_augroup_by_id(group)

    assert.is_false(fired)
  end)
end)
