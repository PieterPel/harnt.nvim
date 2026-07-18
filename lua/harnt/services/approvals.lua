--- Approvals service.
---
--- Answers server-initiated approval requests (run this command? apply this
--- edit?) with allow/deny × once/always. "Always" decisions are remembered per
--- request key so the user isn't asked again. The prompt UI is injectable: the
--- default uses `vim.ui.select`, tests swap in a deterministic chooser, and a
--- provider frontend can later swap in a `nui` menu — the policy logic is the
--- same either way. Agent-agnostic.

local M = {}

---@alias harnt.approvals.Decision "allow_once"|"allow_always"|"deny_once"|"deny_always"

---@class harnt.approvals.Request
---@field key string identity used to remember "always" decisions (e.g. tool name or command)
---@field prompt string one-line question shown to the user
---@field detail? string optional extra context (the command, the diff summary, …)

--- The four choices, in the order the v1 keymap (1–4) expects them.
---@type { label: string, decision: harnt.approvals.Decision }[]
M.CHOICES = {
  { label = "Allow once", decision = "allow_once" },
  { label = "Allow always", decision = "allow_always" },
  { label = "Deny once", decision = "deny_once" },
  { label = "Deny always", decision = "deny_always" },
}

---@alias harnt.approvals.Chooser fun(req: harnt.approvals.Request, on_choice: fun(decision: harnt.approvals.Decision))

--- key -> remembered allow(true)/deny(false)
---@type table<string, boolean>
local remembered = {}

--- Default chooser: a `vim.ui.select` menu. Cancelling is treated as deny-once.
---@param req harnt.approvals.Request
---@param on_choice fun(decision: harnt.approvals.Decision)
local function default_chooser(req, on_choice)
  vim.ui.select(M.CHOICES, {
    prompt = req.prompt,
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    on_choice(choice and choice.decision or "deny_once")
  end)
end

---@type harnt.approvals.Chooser
local chooser = default_chooser

--- Swap the prompt UI (tests, or a provider's nui menu). Pass nil to restore
--- the default `vim.ui.select` chooser.
---@param fn harnt.approvals.Chooser?
function M.set_chooser(fn)
  chooser = fn or default_chooser
end

--- Forget all remembered "always" decisions.
function M.reset()
  remembered = {}
end

--- Whether a decision means "allowed".
---@param decision harnt.approvals.Decision
---@return boolean
local function is_allow(decision)
  return decision == "allow_once" or decision == "allow_always"
end

--- Request approval. If an "always" decision is remembered for `req.key`, the
--- callback fires immediately without prompting; otherwise the chooser runs and
--- an "always" choice is remembered for next time.
---@param req harnt.approvals.Request
---@param callback fun(allowed: boolean, decision: harnt.approvals.Decision)
function M.request(req, callback)
  local mem = remembered[req.key]
  if mem ~= nil then
    callback(mem, mem and "allow_always" or "deny_always")
    return
  end

  chooser(req, function(decision)
    if decision == "allow_always" then
      remembered[req.key] = true
    elseif decision == "deny_always" then
      remembered[req.key] = false
    end
    callback(is_allow(decision), decision)
  end)
end

return M
