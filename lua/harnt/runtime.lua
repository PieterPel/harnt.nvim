--- Runtime glue: connect a Session to the editor services.
---
--- A provider adapter emits canonical events; this wires the two server-initiated
--- flows that need an answer back to the agent — a proposed diff and an approval
--- request — to the diff/approvals services, and routes each resolution back via
--- `session:respond(id, …)`. Display-only events (message/tool deltas) are left
--- for the frontend to consume off the event bus directly.
---
--- Services are injected (defaulting to the real ones) so this glue is testable
--- with doubles, independently of how diffs/approvals are actually presented.

local events = require("harnt.events")

local M = {}

--- Payload for a `diff.ready` event.
---@class harnt.events.DiffReady : harnt.events.Payload
---@field id? harnt.jsonrpc.Id request id to answer, when server-initiated
---@field path string
---@field proposed string[]
---@field original? string[]

--- Payload for an `approval.requested` event.
---@class harnt.events.ApprovalRequested : harnt.events.Payload
---@field id? harnt.jsonrpc.Id request id to answer
---@field key string
---@field prompt string
---@field detail? string

--- Just the slice of the diff service the runtime needs (for injection).
---@class harnt.runtime.DiffService
---@field open fun(spec: harnt.diff.Spec, callback: fun(result: harnt.diff.Result)): integer

--- Just the slice of the approvals service the runtime needs (for injection).
---@class harnt.runtime.ApprovalsService
---@field request fun(req: harnt.approvals.Request, callback: fun(allowed: boolean, decision: harnt.approvals.Decision))

---@class harnt.runtime.Deps
---@field diff? harnt.runtime.DiffService
---@field approvals? harnt.runtime.ApprovalsService

--- Attach `session` to the editor services. Returns a detach function that
--- removes every subscription.
---@param session harnt.Session
---@param deps? harnt.runtime.Deps
---@return fun() detach
function M.attach(session, deps)
  deps = deps or {}
  ---@type harnt.runtime.DiffService
  local diff = deps.diff or require("harnt.services.diff")
  ---@type harnt.runtime.ApprovalsService
  local approvals = deps.approvals or require("harnt.services.approvals")

  local unsubscribes = {}

  table.insert(
    unsubscribes,
    session:on(events.TYPES.diff_ready, function(payload)
      ---@cast payload harnt.events.DiffReady
      diff.open(
        { path = payload.path, proposed = payload.proposed, original = payload.original },
        function(result)
          if payload.id ~= nil then
            session:respond(payload.id, result)
          end
        end
      )
    end)
  )

  table.insert(
    unsubscribes,
    session:on(events.TYPES.approval_requested, function(payload)
      ---@cast payload harnt.events.ApprovalRequested
      approvals.request(
        { key = payload.key, prompt = payload.prompt, detail = payload.detail },
        function(allowed, decision)
          if payload.id ~= nil then
            session:respond(payload.id, { allowed = allowed, decision = decision })
          end
        end
      )
    end)
  )

  return function()
    for _, off in ipairs(unsubscribes) do
      off()
    end
  end
end

return M
