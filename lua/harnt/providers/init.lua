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

--- A live agent session. `push` (an unsolicited notification channel) is *not*
--- here: whether a session can push is a transport property, so it lives on the
--- subtypes that have one (`harnt.reverse_mcp.Session`). Push-mode providers are
--- the only ones that touch it, and they know their own richer session type.
---@class harnt.Session
---@field on fun(self: harnt.Session, event: string, handler: harnt.events.Handler): fun() subscribe; returns unsubscribe
---@field respond fun(self: harnt.Session, id: harnt.jsonrpc.Id, result: any) answer a server-initiated request (e.g. an approval)
---@field interrupt fun(self: harnt.Session) interrupt the current turn
---@field stop fun(self: harnt.Session) end the session

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

--- Handed to a provider's `on_mention` handler: the primitives for delivering an
--- @-mention of the current file/selection in whatever way is native to the agent
--- — a protocol notification (via `session`) or typed prose (via `send_text`).
---@class harnt.MentionContext
---@field session harnt.Session the live session, for protocol-native delivery
---@field send_text fun(text: string) deliver free text to the agent (Shape A: type into its TUI)

--- A registered agent.
---
--- The contract is total on purpose: there are no silently-skippable capability
--- methods (`review`/`health`/`on_mention`), because an absent method used to mean
--- "this agent quietly can't do X and nobody noticed". Every provider implements
--- every capability, and `register()` refuses one that doesn't. The single
--- either/or is the editor **selection**: an agent obtains it either by *push*
--- (`push_selection`, sent on cursor move) or by *pull* (`pull_selection`,
--- answered on demand). Exactly one mechanism is required; declaring neither is a
--- registration error, so "does this agent see my selection?" can never silently
--- be "no".
---@class harnt.Provider
---@field name string unique registry key
---@field detect fun(): boolean CLI present + authenticated
---@field start fun(ctx: harnt.SessionContext): harnt.Session
---@field cmd string[]|fun(session: harnt.Session): string[] command to spawn the agent's own TUI (empty = no external process, e.g. the Fake provider); a function when it needs session info (e.g. a proxy port)
---@field env fun(info: harnt.reverse_mcp.Info): table<string, string> env for the spawned TUI (reverse-MCP discovery vars; `{}` when none)
---@field review fun(ctx: harnt.ReviewContext) deliver diff-review feedback the agent's native way
---@field health fun(report: harnt.health.Report) provider-specific `:checkhealth harnt` probes
---@field on_mention fun(ctx: harnt.MentionContext) @-mention the current file/selection to the agent
---@field push_selection? fun(session: harnt.Session) PUSH: send a live selection update as the cursor moves. Provide this OR `pull_selection`.
---@field pull_selection? fun(): harnt.context.Selection? PULL: answer the current selection when the agent asks for it. Provide this OR `push_selection`.

---@type table<string, harnt.Provider>
local registry = {}

--- Validate a provider table, raising a clear error on any missing/wrong field.
--- The contract is total: every capability method is required, so a provider that
--- silently can't do something can't be registered. The one either/or is the
--- editor selection — a provider must serve it by push OR pull (see the class doc).
---@param provider any
local function validate(provider)
  assert(type(provider) == "table", "register_provider: provider must be a table")
  assert(
    type(provider.name) == "string" and provider.name ~= "",
    "register_provider: provider.name must be a non-empty string"
  )

  local name = provider.name
  --- Assert `provider[field]` is one of `kinds` (e.g. {"function"} or {"table", "function"}).
  ---@param field string
  ---@param kinds string[]
  local function require_field(field, kinds)
    assert(
      vim.tbl_contains(kinds, type(provider[field])),
      ("register_provider: provider %q must define %s (%s)"):format(
        name,
        field,
        table.concat(kinds, " or ")
      )
    )
  end

  require_field("detect", { "function" })
  require_field("start", { "function" })
  require_field("cmd", { "table", "function" })
  require_field("env", { "function" })
  require_field("review", { "function" })
  require_field("health", { "function" })
  require_field("on_mention", { "function" })

  -- Selection is push-or-pull: exactly one mechanism must be present, so an agent
  -- can never silently fail to see the editor selection. Codex/Antigravity pull;
  -- Claude pushes. A new provider is forced to answer "push or pull?".
  assert(
    type(provider.push_selection) == "function" or type(provider.pull_selection) == "function",
    (
      "register_provider: provider %q must serve the editor selection — define push_selection "
      .. "(push on cursor move) or pull_selection (answer on demand)"
    ):format(name)
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
