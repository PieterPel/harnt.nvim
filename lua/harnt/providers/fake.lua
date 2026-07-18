--- Fake provider.
---
--- An in-process provider that implements the Provider/Session contract without
--- any real CLI, so editor services, the event bus, and (later) frontends can be
--- exercised end-to-end in headless CI. It streams whatever canned events a test
--- drives into it, and records the responses it's given to server-initiated
--- requests. This is the deterministic seam TOOLS.md/PLAN call for.

local events = require("harnt.events")

local M = {}

M.name = "fake"

--- Always available.
---@return boolean
function M.detect()
  return true
end

--- A scripted step the fake can replay: an event type + payload.
---@class harnt.fake.Step
---@field event string
---@field payload? harnt.events.Payload

---@class harnt.fake.Session : harnt.Session
---@field private _bus harnt.events.Emitter
---@field private _responses table<harnt.jsonrpc.Id, any>
---@field stopped boolean
---@field interrupted boolean
local Session = {}
Session.__index = Session

--- Start a fake session.
---@param _ctx harnt.SessionContext
---@return harnt.fake.Session
function M.start(_ctx)
  return setmetatable({
    _bus = events.new(),
    _responses = {},
    stopped = false,
    interrupted = false,
  }, Session)
end

--- Subscribe to canonical events. Returns an unsubscribe function.
---@param event string
---@param handler harnt.events.Handler
---@return fun()
function Session:on(event, handler)
  return self._bus:on(event, handler)
end

--- Record a response to a server-initiated request (e.g. an approval decision).
---@param id harnt.jsonrpc.Id
---@param result any
function Session:respond(id, result)
  self._responses[id] = result
end

--- The response recorded for `id`, if any (fake-only accessor for tests).
---@param id harnt.jsonrpc.Id
---@return any
function Session:response_for(id)
  return self._responses[id]
end

--- Interrupt the current turn.
function Session:interrupt()
  self.interrupted = true
end

--- Stop the session, emitting session.completed.
function Session:stop()
  if self.stopped then
    return
  end
  self.stopped = true
  self._bus:emit(events.TYPES.session_completed, {})
end

--- Drive one canned event into the session (fake-only).
---@param event string
---@param payload? harnt.events.Payload
function Session:emit(event, payload)
  self._bus:emit(event, payload)
end

--- Replay a scripted sequence of events in order (fake-only).
---@param steps harnt.fake.Step[]
function Session:play(steps)
  for _, step in ipairs(steps) do
    self._bus:emit(step.event, step.payload)
  end
end

return M
