--- Provider registry + the Provider/Session contract.
---
--- Modeled on nvim-dap adapters / conform.nvim formatters: an agent is a table
--- anyone can register, no core PR required (PLAN §1.4). The contract is
--- deliberately small — a provider knows how to `detect` itself and `start` a
--- session; a session exposes canonical events, answers server-initiated
--- requests, and can be interrupted/stopped.

local M = {}

--- Context handed to a provider when a session starts. Grows over time (context
--- service handle, chosen cwd, …); kept open-ended on purpose.
---@class harnt.SessionContext
---@field cwd? string working directory for the agent

--- A live agent session.
---@class harnt.Session
---@field on fun(self: harnt.Session, event: string, handler: harnt.events.Handler): fun() subscribe; returns unsubscribe
---@field respond fun(self: harnt.Session, id: harnt.jsonrpc.Id, result: any) answer a server-initiated request (e.g. an approval)
---@field interrupt fun(self: harnt.Session) interrupt the current turn
---@field stop fun(self: harnt.Session) end the session

--- A registered agent.
---@class harnt.Provider
---@field name string unique registry key
---@field detect fun(): boolean CLI present + authenticated
---@field start fun(ctx: harnt.SessionContext): harnt.Session

---@type table<string, harnt.Provider>
local registry = {}

--- Validate a provider table, raising a clear error on any missing/wrong field.
---@param provider any
local function validate(provider)
  assert(type(provider) == "table", "register_provider: provider must be a table")
  assert(
    type(provider.name) == "string" and provider.name ~= "",
    "register_provider: provider.name must be a non-empty string"
  )
  assert(
    type(provider.detect) == "function",
    ("register_provider: provider %q must define detect()"):format(provider.name)
  )
  assert(
    type(provider.start) == "function",
    ("register_provider: provider %q must define start()"):format(provider.name)
  )
end

--- Register (or replace) a provider.
---@param provider harnt.Provider
function M.register(provider)
  validate(provider)
  registry[provider.name] = provider
end

--- Look up a provider by name.
---@param name string
---@return harnt.Provider?
function M.get(name)
  return registry[name]
end

--- Registered provider names, sorted.
---@return string[]
function M.list()
  local names = vim.tbl_keys(registry)
  table.sort(names)
  return names
end

--- Whether a provider is registered and reports itself available.
---@param name string
---@return boolean
function M.is_available(name)
  local provider = registry[name]
  return provider ~= nil and provider.detect()
end

--- Remove all registrations (for tests).
function M.clear()
  registry = {}
end

return M
