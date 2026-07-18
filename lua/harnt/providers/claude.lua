--- Claude Code provider — a thin specialization of the reverse-MCP base.
---
--- Claude keeps its own TUI (run in a terminal split) and connects back into the
--- editor over WebSocket MCP. This module supplies the three Claude-specific
--- bits: the `~/.claude/ide/<port>.lock` discovery file, the auth header, and the
--- editor tool set Claude calls (openDiff, getDiagnostics, …), each wired to our
--- shared services. Protocol per coder/claudecode.nvim PROTOCOL.md.

local context = require("harnt.services.context")
local diff = require("harnt.services.diff")
local mcp = require("harnt.transport.mcp")
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

local EMPTY_SCHEMA = { type = "object", properties = vim.empty_dict() }

--- The editor tools Claude may call, wired to the shared services.
---@param _ctx harnt.SessionContext
---@return harnt.mcp.Tool[]
function M.tools(_ctx)
  return {
    {
      name = "openDiff",
      description = "Open a native diff for proposed changes; blocks until the user accepts or rejects.",
      inputSchema = {
        type = "object",
        properties = {
          old_file_path = { type = "string" },
          new_file_path = { type = "string" },
          new_file_contents = { type = "string" },
          tab_name = { type = "string" },
        },
        required = { "old_file_path", "new_file_path", "new_file_contents" },
      },
      handler = function(args, respond)
        local target = args.new_file_path or args.old_file_path
        local proposed = vim.split(args.new_file_contents or "", "\n")
        diff.open({ path = target, proposed = proposed }, function(result)
          respond(mcp.content(result.accepted and "FILE_SAVED" or "DIFF_REJECTED"))
        end)
      end,
    },
    {
      name = "openFile",
      description = "Open a file in the editor.",
      inputSchema = {
        type = "object",
        properties = {
          filePath = { type = "string" },
          preview = { type = "boolean" },
          makeFrontmost = { type = "boolean" },
        },
        required = { "filePath" },
      },
      handler = function(args, respond)
        vim.cmd.edit(vim.fn.fnameescape(args.filePath))
        respond(mcp.content("Opened file: " .. tostring(args.filePath)))
      end,
    },
    {
      name = "getCurrentSelection",
      description = "Get the current text selection.",
      inputSchema = EMPTY_SCHEMA,
      handler = function(_args, respond)
        local sel = context.selection()
        if not sel then
          respond(mcp.content(vim.json.encode({ success = false, text = "" })))
          return
        end
        respond(mcp.content(vim.json.encode({
          success = true,
          text = sel.text,
          filePath = sel.path,
          selection = {
            start = { line = sel.start.row - 1, character = sel.start.col },
            ["end"] = { line = sel.finish.row - 1, character = sel.finish.col },
          },
        })))
      end,
    },
    {
      name = "getDiagnostics",
      description = "Get language diagnostics from open buffers.",
      inputSchema = { type = "object", properties = { uri = { type = "string" } } },
      handler = function(args, respond)
        local bufnr
        if args.uri and args.uri ~= "" then
          bufnr = vim.uri_to_bufnr(args.uri)
        end
        local out = {}
        for _, d in ipairs(context.diagnostics(bufnr)) do
          out[#out + 1] = {
            uri = d.path ~= "" and vim.uri_from_fname(d.path) or nil,
            message = d.message,
            severity = d.severity,
            source = d.source,
            range = {
              start = { line = d.row - 1, character = d.col },
              ["end"] = { line = d.row - 1, character = d.col },
            },
          }
        end
        respond(mcp.content(vim.json.encode(out)))
      end,
    },
    {
      name = "getWorkspaceFolders",
      description = "Get the workspace folders.",
      inputSchema = EMPTY_SCHEMA,
      handler = function(_args, respond)
        respond(mcp.content(vim.json.encode({ workspaceFolders = context.workspace_roots() })))
      end,
    },
    {
      name = "getOpenEditors",
      description = "Get the list of open editors.",
      inputSchema = EMPTY_SCHEMA,
      handler = function(_args, respond)
        local editors = {}
        for _, buffer in ipairs(context.buffers()) do
          editors[#editors + 1] = { filePath = buffer.path, active = buffer.active }
        end
        respond(mcp.content(vim.json.encode({ openEditors = editors })))
      end,
    },
    {
      name = "closeAllDiffTabs",
      description = "Close all open diff tabs.",
      inputSchema = EMPTY_SCHEMA,
      handler = function(_args, respond)
        respond(mcp.content(("CLOSED_%d_DIFF_TABS"):format(diff.reject_all())))
      end,
    },
    {
      -- Claude dismisses a diff tab after resolving it; our diffs already tear
      -- down on accept/reject, so this closes any that linger and acks.
      name = "close_tab",
      description = "Close a tab by name.",
      inputSchema = {
        type = "object",
        properties = { tab_name = { type = "string" } },
        required = { "tab_name" },
      },
      handler = function(_args, respond)
        diff.reject_all()
        respond(mcp.content("TAB_CLOSED"))
      end,
    },
  }
end

--- Environment variables to inject when spawning the `claude` CLI so it discovers
--- and connects to this session.
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
