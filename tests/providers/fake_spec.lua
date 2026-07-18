---@diagnostic disable: undefined-field, need-check-nil
-- (luassert extends `assert`; its narrowing is invisible to emmylua)

local registry = require("harnt.providers")
local fake = require("harnt.providers.fake")
local events = require("harnt.events")

describe("fake provider", function()
  it("is always available", function()
    assert.is_true(fake.detect())
  end)

  it("streams a scripted sequence of events to subscribers", function()
    local session = fake.start({})
    local seen = {}
    session:on("*", function(payload, event)
      table.insert(seen, { event = event, tool = payload.tool })
    end)

    session:play({
      { event = events.TYPES.tool_started, payload = { session = "s", tool = "openDiff" } },
      { event = events.TYPES.tool_completed, payload = { session = "s", tool = "openDiff" } },
    })

    assert.equals(2, #seen)
    assert.equals("tool.started", seen[1].event)
    assert.equals("openDiff", seen[1].tool)
    assert.equals("tool.completed", seen[2].event)
  end)

  it("delivers a single driven event", function()
    local session = fake.start({})
    local got
    session:on(events.TYPES.message_completed, function(payload)
      got = payload
    end)
    session:emit(events.TYPES.message_completed, { text = "done" })
    assert.equals("done", got.text)
  end)

  it("records responses to server-initiated requests", function()
    local session = fake.start({})
    session:respond(7, "allow_once")
    assert.equals("allow_once", session:response_for(7))
    assert.is_nil(session:response_for(99))
  end)

  it("tracks interrupt and stops idempotently, emitting session.completed", function()
    local session = fake.start({})
    local completed = 0
    session:on(events.TYPES.session_completed, function()
      completed = completed + 1
    end)

    session:interrupt()
    assert.is_true(session.interrupted)

    session:stop()
    assert.is_true(session.stopped)
    assert.equals(1, completed)

    session:stop() -- idempotent
    assert.equals(1, completed)
  end)

  it("runs end-to-end through the registry", function()
    registry.clear()
    registry.register(fake)
    assert.is_true(registry.is_available("fake"))

    local provider = registry.get("fake")
    assert(provider)
    local session = provider.start({})

    local got
    session:on(events.TYPES.diff_ready, function(payload)
      got = payload
    end)
    session:emit(events.TYPES.diff_ready, { session = "s", path = "/tmp/a.lua" })
    assert.equals("/tmp/a.lua", got.path)

    registry.clear()
  end)
end)
