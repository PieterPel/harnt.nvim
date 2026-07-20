--- Shared "Claude Code IDE" protocol surface.
---
--- The reverse-MCP tool set Claude Code calls into the editor for — openDiff,
--- getDiagnostics, selection, workspace/editors — plus the selection_changed /
--- at_mentioned notifications the editor pushes back. Wired to harnt's services,
--- so the Claude provider is just discovery + env + transport on top. Protocol
--- per coder/claudecode.nvim PROTOCOL.md.
---
--- (Only Claude uses this surface. Codex is a different shape entirely — an
--- app-server proxy — see providers/codex.lua and CODEX.md.) Claude edits are
--- recorded into the change-log via a PostToolUse hook in providers/claude.lua,
--- not here — openDiff is a permission prompt, not an edit feed.

local context = require("harnt.services.context")
local diff = require("harnt.services.diff")
local mcp = require("harnt.transport.mcp")

local M = {}

local EMPTY_SCHEMA = { type = "object", properties = vim.empty_dict() }

--- The editor tools the agent may call, wired to the shared services.
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
        -- Tag with the provider so review feedback routes to Claude's TUI even
        -- when other agents are running (this surface is Claude-only).
        diff.open({ path = target, proposed = proposed, origin = "claude" }, function(result)
          if result.accepted then
            -- Claude expects TWO content items on save: the marker + the final
            -- (possibly user-edited) content. Without the content it can't treat
            -- the edit as resolved and re-prompts in its TUI. (Per claudecode.nvim.)
            local final = table.concat(result.content or proposed, "\n")
            respond(mcp.texts({ "FILE_SAVED", final }))
          else
            respond(mcp.texts({ "DIFF_REJECTED", args.tab_name or target }))
          end
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
      -- The agent dismisses a diff tab after resolving it; our diffs already tear
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

--- `selection_changed` payload (0-indexed LSP positions), from raw context.
---@return table
local function selection_changed_payload()
  local cursor = context.cursor()
  local path = vim.api.nvim_buf_get_name(0)
  local pos = { line = cursor.row - 1, character = cursor.col }
  return {
    text = "",
    filePath = path,
    fileUrl = path ~= "" and ("file://" .. path) or "",
    selection = { start = pos, ["end"] = pos, isEmpty = true },
  }
end

--- `at_mentioned` payload for the current file/selection.
---@return table
local function at_mentioned_payload()
  local range = context.file_range()
  return { filePath = range.path, lineStart = range.line_start, lineEnd = range.line_end }
end

--- PUSH the live selection as the cursor moves (Claude's `selection_changed`
--- notification). The reverse-MCP session always has a `push` channel.
---@param session harnt.reverse_mcp.Session
function M.push_selection(session)
  session:push("selection_changed", selection_changed_payload())
end

--- Send the current file/selection as an @-mention. Claude has a native
--- `at_mentioned` notification, so we deliver it over the protocol, not the TUI.
---@param ctx harnt.MentionContext
function M.on_mention(ctx)
  local session = ctx.session --[[@as harnt.reverse_mcp.Session]]
  session:push("at_mentioned", at_mentioned_payload())
end

--- Deliver diff-review feedback: reject the diff, then type the comments into the
--- agent's TUI as a follow-up prompt. openDiff is accept/reject only and the input
--- is the terminal, so prose-into-the-TUI is the native path.
---@param ctx harnt.ReviewContext
function M.review(ctx)
  ctx.reject()
  if #ctx.comments == 0 then
    return
  end
  local where = ctx.path and vim.fn.fnamemodify(ctx.path, ":~:.") or "the proposed changes"
  local lines = { ("I rejected the changes to %s. Feedback:"):format(where) }
  for _, comment in ipairs(ctx.comments) do
    table.insert(lines, ("- L%d: %s"):format(comment.line, comment.text))
  end
  ctx.send_text(table.concat(lines, "\n"))
end

return M
