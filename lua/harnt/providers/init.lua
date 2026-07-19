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
---@field push? fun(self: harnt.Session, method: string, params: any) push an unsolicited notification to the agent (context updates); optional

--- Handed to a provider's review handler: the rejected diff's comments plus
--- primitives to deliver the feedback in whatever way is native to the agent.
--- The generic layer supplies the primitives; the provider composes them (type
--- prose into a TUI, send a structured protocol message, whatever fits).
---@class harnt.ReviewContext
---@field comments { line: integer, text: string }[]
---@field path string?
---@field reject fun() reject the diff (resolve it as rejected)
---@field send_text fun(text: string) deliver free text to the agent (Shape A: type into its TUI)
---@field session harnt.Session the live session, for protocol-native delivery

--- A registered agent.
---@class harnt.Provider
---@field name string unique registry key
---@field detect fun(): boolean CLI present + authenticated
---@field start fun(ctx: harnt.SessionContext): harnt.Session
---@field cmd? string[]|fun(session: harnt.Session): string[] command to spawn the agent's own TUI; a function when it needs session info (e.g. a proxy port)
---@field env? fun(info: harnt.reverse_mcp.Info): table<string, string> env for the spawned TUI (reverse-MCP discovery vars)
---@field review? fun(ctx: harnt.ReviewContext) deliver diff-review feedback the agent's native way
---@field on_selection? fun(session: harnt.Session) push a live selection update as the cursor moves
---@field on_mention? fun(session: harnt.Session) @-mention the current file/selection to the agent

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
