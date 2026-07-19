--- Claude Code provider — a thin specialization of the reverse-MCP base.
---
--- Claude keeps its own TUI and connects back over WebSocket MCP. This module
--- supplies the Claude-specific bits — the `~/.claude/ide/<port>.lock` discovery
--- file, the auth header, the discovery env — and reuses the shared
--- Claude-Code-IDE tool set + capabilities (see cc_ide). Protocol per
--- coder/claudecode.nvim PROTOCOL.md.
---
--- It also records every Claude edit into the change-log via a **PostToolUse
--- hook** (injected with `--settings` at launch): the hook appends its JSON
--- payload to a per-session file we tail. Unlike `openDiff` (which only fires
--- when a permission prompt is shown), the hook fires for *every* Edit/Write —
--- including auto-accept / bypass mode — so auto-applied edits still show in
--- `:Harnt changes`. Hook config + payload per the official docs
--- (code.claude.com/docs/en/hooks), verified against the real CLI.

local cc_ide = require("harnt.providers.cc_ide")
local change_log = require("harnt.services.changes")
local context = require("harnt.services.context")
local filetail = require("harnt.transport.filetail")
local reverse_mcp = require("harnt.providers.reverse_mcp")

local M = {}

M.name = "claude"

--- Header the Claude CLI sends carrying the lockfile's auth token.
M.AUTH_HEADER = "x-claude-code-ide-authorization"

--- Edit tools whose PostToolUse payloads we record.
local HOOK_TOOLS = { Edit = true, Write = true, MultiEdit = true }

--- Render a hook payload's change as diff text: the `structuredPatch` hunks when
--- present (Edit/MultiEdit), else the written content (Write / new file).
---@param payload table PostToolUse payload
---@return string
local function render_hook_diff(payload)
  local response = payload.tool_response or {}
  local patch = response.structuredPatch
  if type(patch) == "table" and #patch > 0 then
    local lines = {}
    for _, hunk in ipairs(patch) do
      lines[#lines + 1] = ("@@ -%d,%d +%d,%d @@"):format(
        hunk.oldStart or 0,
        hunk.oldLines or 0,
        hunk.newStart or 0,
        hunk.newLines or 0
      )
      for _, line in ipairs(hunk.lines or {}) do
        lines[#lines + 1] = line
      end
    end
    return table.concat(lines, "\n")
  end
  return response.content or (payload.tool_input and payload.tool_input.content) or ""
end

--- Record a PostToolUse edit payload into the shared change-log.
---@param payload table
function M.record_hook_change(payload)
  local input = payload.tool_input or {}
  local response = payload.tool_response or {}
  local path = input.file_path or response.filePath
  if not path then
    return
  end
  change_log.record({
    path = path,
    kind = (response.type == "create") and "add" or "update",
    diff = render_hook_diff(payload),
    provider = M.name,
  })
end

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

--- A Claude session: the reverse-MCP session plus the injected `--settings` JSON.
---@class harnt.claude.Session : harnt.reverse_mcp.Session
---@field settings_json string additional settings (our PostToolUse hook) passed at launch

--- The launch command: the native TUI with our edit-recording hook injected via
--- `--settings` (dynamic — the hook file path is per-session).
---@param session harnt.claude.Session
---@return string[]
function M.cmd(session)
  return { "claude", "--settings", session.settings_json }
end

--- Whether the `claude` CLI is available.
---@return boolean
function M.detect()
  return vim.fn.executable("claude") == 1
end

--- Start a Claude reverse-MCP session, wiring the PostToolUse edit-recording hook.
---@param ctx? harnt.SessionContext
---@return harnt.claude.Session
function M.start(ctx)
  local base = reverse_mcp.start({
    name = M.name,
    auth_header = M.AUTH_HEADER,
    discovery = M.discovery,
    tools = M.tools,
    server_info = { name = "harnt.nvim", version = "0.1.0" },
  }, ctx)

  -- A per-session file the hook appends its JSON payloads to; we tail it and
  -- record each Edit/Write into the change-log.
  local hook_file = vim.fn.tempname()
  vim.fn.writefile({}, hook_file)
  local tail = filetail.tail(hook_file, function(line)
    local ok, payload = pcall(vim.json.decode, line)
    if ok and type(payload) == "table" and HOOK_TOOLS[payload.tool_name] then
      M.record_hook_change(payload)
    end
  end)
  -- Compact single-line payload + newline delimiter (verified: Claude sends
  -- compact JSON). shellescape the path; Claude runs the command via the shell.
  local hook_cmd = ("{ cat; printf '\\n'; } >> %s"):format(vim.fn.shellescape(hook_file))

  ---@cast base harnt.claude.Session
  base.settings_json = vim.json.encode({
    hooks = {
      PostToolUse = {
        { matcher = "Edit|Write|MultiEdit", hooks = { { type = "command", command = hook_cmd } } },
      },
    },
  })

  local base_stop = base.stop
  base.stop = function(self)
    tail.stop()
    pcall(os.remove, hook_file)
    base_stop(self)
  end
  return base
end

return M
