--- Claude Code provider — a thin specialization of the reverse-MCP base.
---
--- Claude keeps its own TUI and connects back over WebSocket MCP. This module
--- supplies only the Claude-specific bits — the `~/.claude/ide/<port>.lock`
--- discovery file, the auth header, and the discovery env — and reuses the shared
--- Claude-Code-IDE tool set + capabilities (see cc_ide). Protocol per
--- coder/claudecode.nvim PROTOCOL.md.

local cc_ide = require("harnt.providers.cc_ide")
local context = require("harnt.services.context")
local reverse_mcp = require("harnt.providers.reverse_mcp")

local M = {}

M.name = "claude"

--- Command that launches Claude's TUI (spawned in a terminal split by the manager).
M.cmd = { "claude" }

--- Header the Claude CLI sends carrying the lockfile's auth token.
M.AUTH_HEADER = "x-claude-code-ide-authorization"

--- Directory Claude scans for IDE lockfiles (honors $CLAUDE_CONFIG_DIR).
---@return string
local function ide_dir()
  local base = vim.env.CLAUDE_CONFIG_DIR
  if not base or base == "" then
    base = vim.fs.joinpath(assert(vim.uv.os_homedir()), ".claude")
  end
  return vim.fs.joinpath(base, "ide")
end

---@param info harnt.reverse_mcp.Info
---@return string
local function lockfile_path(info)
  return vim.fs.joinpath(ide_dir(), info.port .. ".lock")
end

--- The discovery contract: write/remove `~/.claude/ide/<port>.lock`.
---@type harnt.reverse_mcp.Discovery
M.discovery = {
  write = function(info)
    vim.fn.mkdir(ide_dir(), "p")
    local contents = vim.json.encode({
      pid = info.pid,
      workspaceFolders = context.workspace_roots(),
      ideName = "Neovim",
      transport = "ws",
      authToken = info.auth_token,
    })
    vim.fn.writefile({ contents }, lockfile_path(info))
  end,
  remove = function(info)
    local path = lockfile_path(info)
    if vim.fn.filereadable(path) == 1 then
      vim.fn.delete(path)
    end
  end,
}

-- Shared Claude-Code-IDE surface (tools + capabilities).
M.tools = cc_ide.tools
M.review = cc_ide.review
M.on_selection = cc_ide.on_selection
M.on_mention = cc_ide.on_mention

--- Environment variables so the spawned `claude` CLI discovers this session.
---@param info harnt.reverse_mcp.Info
---@return table<string, string>
function M.env(info)
  return {
    CLAUDE_CODE_SSE_PORT = tostring(info.port),
    ENABLE_IDE_INTEGRATION = "true",
  }
end

--- Whether the `claude` CLI is available.
---@return boolean
function M.detect()
  return vim.fn.executable("claude") == 1
end

--- Start a Claude reverse-MCP session.
---@param ctx? harnt.SessionContext
---@return harnt.reverse_mcp.Session
function M.start(ctx)
  return reverse_mcp.start({
    name = M.name,
    auth_header = M.AUTH_HEADER,
    discovery = M.discovery,
    tools = M.tools,
    server_info = { name = "harnt.nvim", version = "0.1.0" },
  }, ctx)
end

return M
