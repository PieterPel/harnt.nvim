--- Fake provider.
---
--- An in-process provider that implements the Provider/Session contract without
--- any real CLI, so editor services, the event bus, and (later) frontends can be
--- exercised end-to-end in headless CI. It streams whatever canned events a test
--- drives into it, and records the responses it's given to server-initiated
--- requests. This is the deterministic seam docs/TOOLS.md/PLAN call for.

local events = require("harnt.events")
local context = require("harnt.services.context")

local M = {}

M.name = "fake"

--- No external process: the fake runs in-process, so the manager spawns no TUI.
--- An empty `cmd` is how a provider says "nothing to launch".
M.cmd = {}

--- No spawn env (nothing is spawned).
---@return table<string, string>
function M.env()
  return {}
end

--- Always available.
---@return boolean
function M.detect()
  return true
end

--- `:checkhealth harnt` probe: the fake is always present (it's in-process).
---@param report harnt.health.Report
function M.health(report)
  report.ok("fake: in-process test provider (always available)")
end

--- Review feedback: there's no real agent to deliver to, so just resolve the diff
--- as rejected. Tests assert on the reject; the comments have nowhere native to go.
---@param ctx harnt.ReviewContext
function M.review(ctx)
  ctx.reject()
end

--- @-mention: no real agent/TUI to deliver into, so this is a no-op. Kept explicit
--- (not absent) so the contract stays total and a reader sees the deliberate choice.
---@param _ctx harnt.MentionContext
function M.on_mention(_ctx) end

--- PULL: serve the current editor selection on demand — lets tests exercise the
--- pull mechanism without a real CLI.
---@return harnt.context.Selection?
function M.pull_selection()
  return context.selection()
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
