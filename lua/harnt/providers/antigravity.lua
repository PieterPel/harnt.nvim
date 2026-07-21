--- Antigravity provider — lifecycle-hook gate.
---
--- The terminal `agy` CLI is standalone: it does NOT dial the exa language_server
--- (that server is the desktop IDE's Cascade sidebar; see ANTIGRAVITY.md for the
--- full reverse-engineering record and why the earlier LS/ExtensionServer path was
--- the wrong integration point). What terminal agy *does* expose is a documented
--- lifecycle-hook system (`.agents/hooks.json`, shipped with the CLI at
--- `builtin/skills/agy-customizations/docs/hooks.md`). harnt uses it to reach the
--- project's whole point — interactive diffs and approvals in nvim:
---
---   * `PreToolUse` (blocking) for edit/command tools → we reconstruct the proposed
---     change from the tool args, render it through the shared `diff` service (an
---     edit) or `approvals` service (a command), and answer `{decision}`. This is
---     agy's analogue of Claude's `openDiff` / Codex's `item/fileChange/requestApproval`.
---   * `PreInvocation` → we inject the live editor context (active file, selection,
---     open files) as an `ephemeralMessage`, closing the context gap the same way
---     codex's `/ide` socket does — the pull-based equivalent of Claude's IDE tools.
---
--- The hook command bridges the agy child process to harnt over a per-session unix
--- socket (`reqsock`): the hook pipes its stdin JSON to us via `nc -U`, we decide,
--- and write the JSON decision back. All agy protocol knowledge (hook file shape,
--- tool names, decision strings) lives in THIS file; the services stay agnostic.

local approvals = require("harnt.services.approvals")
local change_log = require("harnt.services.changes")
local context = require("harnt.services.context")
local diff = require("harnt.services.diff")
local events = require("harnt.events")
local reqsock = require("harnt.transport.reqsock")

local M = {}

M.name = "antigravity"

--- Edit tools whose args we turn into a reviewable diff (`kind` decided by whether
--- the target already exists). Command tools go through the approval prompt.
local EDIT_TOOLS = {
  edit_file = true,
  write_file = true,
  write_to_file = true,
  replace_file_content = true,
  multi_replace_file_content = true,
}

--- The `PreToolUse` matcher regex (Go `regexp`, `|` = alternation): the edit
--- tools plus `run_command`. Tool names are the lowercased step type minus the
--- `CORTEX_STEP_TYPE_` prefix (per hooks.md).
local TOOL_MATCHER =
  "edit_file|write_file|write_to_file|replace_file_content|multi_replace_file_content|run_command"

--- Likely arg field names carrying the target path / new content across agy's
--- edit tools. Tried in order; the exact set is confirmed empirically per version
--- (log a real `PreToolUse` payload). Unknown shapes fall back to showing the raw
--- args, so the gate still works even before the mapping is pinned.
local PATH_FIELDS =
  { "path", "file_path", "filePath", "absolute_path", "AbsolutePath", "TargetFile", "target_file" }
local CONTENT_FIELDS = {
  "content",
  "Content",
  "new_content",
  "NewContent",
  "CodeContent",
  "file_content",
  "text",
  "contents",
}
-- `replace_file_content` / `multi_replace_file_content` are search→replace, not
-- full content: an old snippet and its replacement (verified: `TargetContent` /
-- `ReplacementContent`).
local REPLACE_OLD = { "TargetContent", "target_content", "old_string", "search" }
local REPLACE_NEW = { "ReplacementContent", "replacement_content", "new_string", "replace" }

--- First string-valued field of `args` named in `fields`, or nil.
---@param args table
---@param fields string[]
---@return string?
local function pick(args, fields)
  for _, field in ipairs(fields) do
    if type(args[field]) == "string" then
      return args[field]
    end
  end
  return nil
end

--- A normalized proposed change: the change as CONTENT (old + new full text).
--- harnt's diff service renders it — antigravity does no display work.
---@class harnt.antigravity.Edit
---@field path string
---@field kind string "add" | "update"
---@field new string[] full proposed content
---@field old string[] baseline the new content replaces (empty = new file / snippet)

--- Turn an edit tool's args into old/new content for the diff service. Handles
--- the two real agy shapes — full-content (`write_to_file`/`edit_file`) and
--- search→replace (`replace_file_content`, spliced into the on-disk file) — and
--- falls back to showing the raw args for an unrecognized tool.
---@param name string tool name
---@param args table tool args
---@return harnt.antigravity.Edit
function M._normalize_edit(name, args)
  local path = pick(args, PATH_FIELDS)
  local disk = {} ---@type string[]
  local exists = false
  if path and vim.fn.filereadable(path) == 1 then
    exists = true
    disk = vim.fn.readfile(path)
  end

  -- Full-content edit (write_to_file / edit_file).
  local content = pick(args, CONTENT_FIELDS)
  if path and content then
    return {
      path = path,
      kind = exists and "update" or "add",
      new = vim.split(content, "\n", { plain = true }),
      old = disk,
    }
  end

  -- Search→replace edit (replace_file_content): splice the replacement into the
  -- on-disk file. If the target text isn't found verbatim, diff the snippets.
  local old_snip = pick(args, REPLACE_OLD)
  local new_snip = pick(args, REPLACE_NEW)
  if path and old_snip and new_snip then
    local text = table.concat(disk, "\n")
    local s, e = text:find(old_snip, 1, true) -- plain (no pattern magic)
    if s and e then
      local spliced = text:sub(1, s - 1) .. new_snip .. text:sub(e + 1)
      return {
        path = path,
        kind = "update",
        new = vim.split(spliced, "\n", { plain = true }),
        old = disk,
      }
    end
    return {
      path = path,
      kind = "update",
      new = vim.split(new_snip, "\n", { plain = true }),
      old = vim.split(old_snip, "\n", { plain = true }),
    }
  end

  -- Unknown shape: show the raw args as an addition so it's still reviewable.
  return {
    path = path or ("(%s)"):format(name),
    kind = "update",
    new = vim.split(vim.inspect(args), "\n", { plain = true }),
    old = {},
  }
end

--- Build the `PreInvocation` context injection: the live editor state as a single
--- transient `ephemeralMessage`. Empty when there's nothing worth sending.
---@return table[] injectSteps
function M._context_steps()
  local snap = context.snapshot()
  local root = snap.roots[1]
  local function rel(p)
    if root and root ~= "" and p:sub(1, #root) == p and p ~= "" then
      return p:sub(#root + 2)
    end
    return p
  end

  -- agy has no channel we can push into: it *pulls* editor context by firing the
  -- `PreInvocation` hook before each model turn, and we answer with the live
  -- state. The selection is served through `pull_selection` so the pull path has
  -- one source of truth (the contract's declared mechanism for this provider).
  local sel = M.pull_selection()

  local lines = {} ---@type string[]
  if sel and sel.path ~= "" then
    lines[#lines + 1] = ("Editor selection — %s (lines %d–%d):"):format(
      rel(sel.path),
      sel.start.row,
      sel.finish.row
    )
    lines[#lines + 1] = sel.text
  else
    local active = vim.api.nvim_buf_get_name(0)
    if active ~= "" then
      lines[#lines + 1] = "Active file in editor: " .. rel(active)
    end
  end

  local open = {} ---@type string[]
  for _, b in ipairs(snap.buffers) do
    if b.path ~= "" then
      open[#open + 1] = rel(b.path)
    end
  end
  if #open > 0 then
    lines[#lines + 1] = "Open files: " .. table.concat(open, ", ")
  end

  local errors = 0
  for _, d in ipairs(snap.diagnostics) do
    if d.severity == "error" then
      errors = errors + 1
    end
  end
  if errors > 0 then
    lines[#lines + 1] = ("Editor reports %d error diagnostic(s)."):format(errors)
  end

  if #lines == 0 then
    return {}
  end
  return {
    { ephemeralMessage = "Context from the user's Neovim editor:\n" .. table.concat(lines, "\n") },
  }
end

--- Build the deny `reason` for a rejected edit, folding in any inline review
--- comments the user attached to the diff. Plain rejection with no comments still
--- gives agy a clear reason.
---@param comments? { line: integer, text: string }[]
---@return string
function M._deny_reason(comments)
  if not comments or #comments == 0 then
    return "Change rejected in the editor."
  end
  local lines = { "Change rejected in the editor. Feedback:" }
  for _, c in ipairs(comments) do
    lines[#lines + 1] = ("- L%d: %s"):format(c.line, c.text)
  end
  return table.concat(lines, "\n")
end

--- Handle a `PreToolUse` payload: gate an edit through the diff service or a
--- command through the approval service, then answer with the agy decision.
---@param call { name?: string, args?: table }
---@param respond fun(response: table)
function M._handle_tool_use(call, respond)
  local name = call.name or ""
  local args = call.args or {}

  if name == "run_command" then
    local cmdline = args.CommandLine or args.command or args.cmd
    approvals.request({
      key = "antigravity:command",
      prompt = "Antigravity wants to run a command",
      detail = cmdline,
    }, function(allowed)
      if allowed then
        -- Granting the permission ourselves means agy doesn't ALSO prompt — our
        -- approval popup is the one and only gate. `command(<cmdline>)` is agy's
        -- permission grammar (hooks.md PreToolUse example).
        respond({
          decision = "allow",
          permissionOverrides = cmdline and { ("command(%s)"):format(cmdline) } or nil,
        })
      else
        respond({ decision = "deny" })
      end
    end)
    return
  end

  if EDIT_TOOLS[name] then
    local edit = M._normalize_edit(name, args)
    diff.open_review(
      { path = edit.path, new = edit.new, old = edit.old, origin = M.name },
      function(result)
        if result.accepted then
          change_log.record({
            path = edit.path,
            kind = edit.kind,
            diff = table.concat(edit.new, "\n"),
            provider = M.name,
          })
          -- Our accepted diff IS the approval; grant agy's write permission so it
          -- doesn't double-prompt (verified end-to-end — see e2e-agy-hooks).
          respond({
            decision = "allow",
            permissionOverrides = { ("write_file(%s)"):format(edit.path) },
          })
        else
          -- Deny, folding any inline review comments into the `reason` — agy's
          -- native feedback channel (the reason is shown to the model), so a
          -- rejected diff carries the user's notes back and the agent can revise.
          respond({ decision = "deny", reason = M._deny_reason(result.comments) })
        end
      end
    )
    return
  end

  -- A matched-but-unhandled tool: don't block it.
  respond({ decision = "allow" })
end

--- Route one hook request to the right handler by payload shape (agy sends no
--- explicit event discriminator; the fields distinguish the events). `PreToolUse`
--- carries `toolCall`; `PreInvocation` carries `invocationNum`; anything else
--- (e.g. `PostToolUse`) just gets an empty ack.
---@param request table the hook stdin payload
---@param respond fun(response: table)
function M._on_hook(request, respond)
  if type(request.toolCall) == "table" then
    M._handle_tool_use(request.toolCall, respond)
  elseif request.invocationNum ~= nil then
    respond({ injectSteps = M._context_steps() })
  else
    respond(vim.empty_dict())
  end
end

--- Path to the workspace hook config.
---@param cwd string
---@return string
local function hooks_path(cwd)
  return vim.fs.joinpath(cwd, ".agents", "hooks.json")
end

--- The `harnt` named-hook entry bridging agy's lifecycle events to our socket.
--- The command pipes the hook's stdin JSON to us and echoes our JSON reply
--- (`nc -U`). `PreToolUse` blocks on user review, so its timeout is generous;
--- `PreInvocation` is a fast round-trip. Structure per hooks.md: `PreToolUse` is
--- grouped (matcher + hooks), `PreInvocation` is a flat handler list.
---@param sock string
---@return table
local function hook_entry(sock)
  local command = "nc -U " .. vim.fn.shellescape(sock)
  return {
    PreToolUse = {
      {
        matcher = TOOL_MATCHER,
        hooks = { { type = "command", command = command, timeout = 3600 } },
      },
    },
    PreInvocation = {
      { type = "command", command = command, timeout = 30 },
    },
  }
end

--- Install our hook into `.agents/hooks.json`, merging non-destructively under the
--- `harnt` key (agy merges multiple named hooks) and preserving any existing file.
--- Returns a restore function that puts the file back exactly as it was (or removes
--- it if we created it).
---@param cwd string
---@param sock string
---@return fun() restore
local function install_hooks(cwd, sock)
  local path = hooks_path(cwd)
  local existed = vim.fn.filereadable(path) == 1
  local original_lines = existed and vim.fn.readfile(path) or nil

  local config = {}
  if original_lines then
    local ok, parsed = pcall(vim.json.decode, table.concat(original_lines, "\n"))
    if ok and type(parsed) == "table" then
      config = parsed
    end
  end
  config.harnt = hook_entry(sock)

  vim.fn.mkdir(vim.fs.dirname(path), "p")
  vim.fn.writefile({ vim.json.encode(config) }, path)

  return function()
    if existed and original_lines then
      pcall(vim.fn.writefile, original_lines, path)
    else
      pcall(os.remove, path)
    end
  end
end

--- The launch command: the native `agy` TUI. Hooks are discovered from
--- `.agents/hooks.json` in the workspace, so no special env/flags are needed.
M.cmd = { "agy" }

--- No spawn-time env: agy discovers us via the `.agents/hooks.json` bridge, not
--- environment variables.
---@return table<string, string>
function M.env()
  return {}
end

--- PULL: answer the current selection when agy asks. agy has no push channel — it
--- pulls editor context via the `PreInvocation` hook before each turn (see
--- `_context_steps`, which reads through this). This declares that mechanism.
---@return harnt.context.Selection?
function M.pull_selection()
  return context.selection()
end

--- Deliver diff-review feedback. agy's native feedback channel is the hook's deny
--- `reason`: rejecting the diff fires the `open_review` callback, which folds the
--- inline comments into the `reason` agy sees (see `_handle_tool_use`). So the
--- honest review path here is simply to reject — the comments ride agy's own wire,
--- not a typed follow-up.
---@param ctx harnt.ReviewContext
function M.review(ctx)
  ctx.reject()
end

--- @-mention the current file/selection into the native agy TUI. agy has no
--- protocol at-mention, so we type an `@path` reference into the terminal via
--- `send_text`. A visual selection appends its line range as readable context.
---@param ctx harnt.MentionContext
function M.on_mention(ctx)
  local sel = context.selection()
  local path = sel and sel.path or vim.api.nvim_buf_get_name(0)
  if path == "" then
    return
  end
  local ref = "@" .. vim.fn.fnamemodify(path, ":~:.")
  if sel then
    ref = ref .. (" (lines %d–%d)"):format(sel.start.row, sel.finish.row)
  end
  ctx.send_text(ref)
end

--- An Antigravity session.
---@class harnt.antigravity.Session : harnt.Session
---@field info { hook_socket: string, cwd: string }

--- Start an Antigravity session: host the hook decision socket and install the
--- `.agents/hooks.json` bridge. The manager launches `agy` (see `cmd`); its edits
--- and commands then route through our shared diff/approval services, and each
--- model invocation pulls the live editor context.
---@param ctx? harnt.SessionContext
---@return harnt.antigravity.Session
function M.start(ctx)
  ctx = ctx or {}
  local cwd = ctx.cwd or vim.uv.cwd() or "."
  local bus = events.new()

  local sock = vim.fn.tempname() .. ".agy.sock"
  local server, err = reqsock.serve({
    path = sock,
    on_request = function(request, respond)
      M._on_hook(request, respond)
    end,
  })
  assert(server, "antigravity: could not host hook socket: " .. tostring(err))

  local restore = install_hooks(cwd, sock)
  vim.schedule(function()
    bus:emit(events.TYPES.session_started, { provider = M.name })
  end)

  local stopped = false
  ---@type harnt.antigravity.Session
  return {
    info = { hook_socket = sock, cwd = cwd },
    on = function(_self, event, handler)
      return bus:on(event, handler)
    end,
    respond = function() end,
    interrupt = function() end,
    stop = function()
      if stopped then
        return
      end
      stopped = true
      restore()
      server.close()
      bus:emit(events.TYPES.session_completed, { provider = M.name })
    end,
  }
end

--- Whether the `agy` CLI is available.
---@return boolean
function M.detect()
  return vim.fn.executable("agy") == 1
end

--- `:checkhealth harnt` probes for Antigravity.
---@param report harnt.health.Report
function M.health(report)
  if vim.fn.executable("agy") ~= 1 then
    report.error("agy CLI not found on PATH", "Install the Antigravity CLI so `agy` is runnable.")
    return
  end
  report.ok("agy CLI: " .. vim.fn.exepath("agy"))

  if vim.fn.executable("nc") == 1 then
    report.ok("nc found (the hook bridge shells out to `nc -U`)")
  else
    report.error(
      "nc (netcat) not found on PATH",
      "The lifecycle-hook bridge uses `nc -U <socket>`; install netcat."
    )
  end

  local cwd = vim.uv.cwd() or "."
  if vim.uv.fs_access(cwd, "W") then
    report.ok("workspace writable (.agents/hooks.json is merged here): " .. cwd)
  else
    report.warn(
      "workspace not writable: " .. cwd,
      "harnt injects .agents/hooks.json here (restored on stop); check permissions."
    )
  end
end

return M
