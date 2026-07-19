--- Codex provider — reverse-MCP over WebSocket via `codex /ide`.
---
--- Codex's `/ide` mirrors the Claude Code IDE protocol (per ishiooon/codex.nvim),
--- so it reuses the shared cc_ide tool set + capabilities. It differs from Claude
--- only in the discovery env (CODEX_CODE_SSE_PORT) and that it discovers the
--- server from that env var alone — no lockfile.
---
--- NOTE: Codex's `/ide` wire is under-documented; the exact env var names, any
--- auth handshake, and the tool surface should be verified against the real
--- `codex` CLI (as Claude was) before relying on it.

local cc_ide = require("harnt.providers.cc_ide")
local reverse_mcp = require("harnt.providers.reverse_mcp")

local M = {}

M.name = "codex"

--- Command that launches Codex's TUI (spawned in a terminal split by the manager).
M.cmd = { "codex" }

--- Codex discovers the server from CODEX_CODE_SSE_PORT alone (env-only); there is
--- no lockfile to place, so discovery is a no-op.
---@type harnt.reverse_mcp.Discovery
M.discovery = {
  write = function() end,
  remove = function() end,
}

-- Shared Claude-Code-IDE surface (tools + capabilities).
M.tools = cc_ide.tools
M.review = cc_ide.review
M.on_selection = cc_ide.on_selection
M.on_mention = cc_ide.on_mention

--- Environment variables so the spawned `codex` CLI discovers this session.
---@param info harnt.reverse_mcp.Info
---@return table<string, string>
function M.env(info)
  return {
    CODEX_CODE_SSE_PORT = tostring(info.port),
    ENABLE_IDE_INTEGRATION = "true",
  }
end

--- Whether the `codex` CLI is available.
---@return boolean
function M.detect()
  return vim.fn.executable("codex") == 1
end

--- Start a Codex reverse-MCP session.
---@param ctx? harnt.SessionContext
---@return harnt.reverse_mcp.Session
function M.start(ctx)
  return reverse_mcp.start({
    name = M.name,
    discovery = M.discovery,
    tools = M.tools,
    server_info = { name = "harnt.nvim", version = "0.1.0" },
  }, ctx)
end

return M
