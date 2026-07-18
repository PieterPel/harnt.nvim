--- Canonical event bus.
---
--- Providers emit a small, normalized set of UI-critical events (PLAN §1.5); the
--- core dispatches them to in-process subscribers AND mirrors every one onto a
--- `User HarntEvent` autocmd, so other plugins/users can hook without a Lua
--- dependency on us.
---
--- We normalize ONLY the common surface. Provider-native detail is never
--- flattened away: it rides along under `payload.provider`, and provider-
--- specific events can be emitted with their own namespaced type. Feature loss
--- is a bug, not a tradeoff.

local M = {}

--- autocmd pattern every emitted event is mirrored onto.
M.PATTERN = "HarntEvent"

--- Canonical event types. Providers should emit these for the shared UI surface;
--- anything richer travels under `payload.provider` or a namespaced type.
M.TYPES = {
  session_started = "session.started",
  session_completed = "session.completed",
  session_failed = "session.failed",
  message_delta = "message.delta",
  message_completed = "message.completed",
  tool_started = "tool.started",
  tool_completed = "tool.completed",
  approval_requested = "approval.requested",
  approval_resolved = "approval.resolved",
  diff_ready = "diff.ready",
  diff_closed = "diff.closed",
}

--- Base shape of an emitted payload. Concrete events add their own fields, and
--- always keep the untouched native payload under `provider`.
---@class harnt.events.Payload
---@field session? string session id this event belongs to
---@field provider? any verbatim provider-native payload (never flattened)

---@alias harnt.events.Handler fun(payload: harnt.events.Payload, event: string)

---@class harnt.events.Emitter
---@field private _handlers table<string, harnt.events.Handler[]>
---@field private _autocmd boolean
local Emitter = {}
Emitter.__index = Emitter
M.Emitter = Emitter

--- Create an emitter. Pass `autocmd = false` to suppress the `User HarntEvent`
--- mirror (e.g. for isolated unit tests).
---@param opts? { autocmd?: boolean }
---@return harnt.events.Emitter
function M.new(opts)
  opts = opts or {}
  return setmetatable({
    _handlers = {},
    _autocmd = opts.autocmd ~= false,
  }, Emitter)
end

--- Subscribe to a canonical event type, or `"*"` for every event.
---@param event string canonical type or "*"
---@param handler harnt.events.Handler
---@return fun() unsubscribe removes this handler
function Emitter:on(event, handler)
  local list = self._handlers[event]
  if not list then
    list = {}
    self._handlers[event] = list
  end
  table.insert(list, handler)
  return function()
    for i = #list, 1, -1 do
      if list[i] == handler then
        table.remove(list, i)
      end
    end
  end
end

--- Emit an event: fire specific handlers, then wildcard handlers, then mirror it
--- onto the `User HarntEvent` autocmd (unless disabled).
---@param event string
---@param payload? harnt.events.Payload
function Emitter:emit(event, payload)
  payload = payload or {}
  for _, handler in ipairs(self._handlers[event] or {}) do
    handler(payload, event)
  end
  for _, handler in ipairs(self._handlers["*"] or {}) do
    handler(payload, event)
  end
  if self._autocmd then
    vim.api.nvim_exec_autocmds("User", {
      pattern = M.PATTERN,
      data = { event = event, payload = payload },
    })
  end
end

return M
