--- OpenCode provider — HTTP-server-hosted-by-the-agent reverse channel.
---
--- OpenCode inverts the direction of the other providers. Where Claude has the
--- editor host a WebSocket the CLI dials *in* to, and Codex has us proxy an
--- app-server, OpenCode's own TUI is a *client of an HTTP server*: `opencode
--- serve` stands up a local HTTP + Server-Sent-Events API, and the TUI (`opencode
--- attach <url>`) is just one client of it. So harnt joins as a *second client* of
--- the same server:
---
---   opencode serve  (HTTP + SSE, the transport)
---     ├── opencode attach <url>   ← the native TUI = the chat, untouched
---     └── harnt (SSE client)      ← taps /event, answers permissions over HTTP
---
--- harnt spawns `opencode serve`, launches the native TUI attached to it, and
--- subscribes to `GET /event`. It gives every editor-side capability the other
--- providers have:
---   * **approvals** — `permission.v2.asked` → our approvals surface, answered
---     over `POST …/permission/{id}/reply`. An *edit*/*write*/*patch* permission
---     is shown as an interactive **diff review** (accept / reject / comment),
---     built by correlating the permission's `source.callID` with the tool call's
---     input; a command permission uses the four-way approval popup.
---   * **change-log** — `session.diff` file changes recorded for `:Harnt changes`.
---   * **editor context** — `on_mention` pushes the current file/selection to the
---     agent as a native `@path#Lstart-end` mention via `POST /tui/append-prompt`
---     (the same channel OpenCode's own editor integration uses).
--- The TUI renders the chat; we never draw it. On-thesis: `opencode serve` is used
--- purely as the wire (the same role WebSocket plays for Claude and app-server for
--- Codex), NOT as a headless chat surface we render — that would be the §7
--- non-goal. OpenCode does ship such a surface (`opencode acp`); we deliberately
--- do not use it.
---
--- All OpenCode protocol knowledge (event type names, permission decision enum,
--- tool-input shapes, endpoint paths) lives in THIS file; the generic layers stay
--- agent-agnostic. See OPENCODE.md for the reverse-engineering record + the wire.

local approvals = require("harnt.services.approvals")
local change_log = require("harnt.services.changes")
local diff = require("harnt.services.diff")
local events = require("harnt.events")
local httpclient = require("harnt.transport.httpclient")
local stdio = require("harnt.transport.stdio")

local M = {}

M.name = "opencode"

--- SSE event `type`s we act on. Everything else on the stream is ignored (it's
--- the TUI's concern — reasoning deltas, text streaming, etc. never touch us).
local EVENT = {
  connected = "server.connected",
  permission_asked = "permission.v2.asked",
  permission_replied = "permission.v2.replied",
  session_diff = "session.diff",
  file_edited = "file.edited",
  tool_called = "session.next.tool.called",
  tool_success = "session.next.tool.success",
  tool_failed = "session.next.tool.failed",
  session_error = "session.error",
  session_idle = "session.idle",
}

--- Map our approval decision → OpenCode's `PermissionV2Reply` enum. OpenCode
--- distinguishes only allow-once / allow-always / reject, so both "deny" variants
--- collapse to `reject` (deny-always is remembered on OUR side by the approvals
--- service keyed on the action).
---@param decision harnt.approvals.Decision
---@return "once"|"always"|"reject"
local function reply_for(decision)
  if decision == "allow_once" then
    return "once"
  elseif decision == "allow_always" then
    return "always"
  end
  return "reject"
end

--- One normalized file change from a `session.diff` event's `SnapshotFileDiff`.
---@class harnt.opencode.Change
---@field path string
---@field kind string "added" | "deleted" | "modified"
---@field diff string unified patch (may be empty for binary/large files)

--- Normalize a `session.diff` payload's `diff` array into our change shape.
---@param file_diffs any[]?
---@return harnt.opencode.Change[]
local function normalize_diff(file_diffs)
  local out = {}
  for _, fd in ipairs(file_diffs or {}) do
    out[#out + 1] = {
      path = fd.file or "(unknown)",
      kind = fd.status or "modified",
      diff = fd.patch or "",
    }
  end
  return out
end

--- A one-line description of what a permission is asking to do, from its `action`
--- and `resources` (e.g. `edit  src/app.ts` or `bash  rm -rf build`).
---@param perm table PermissionV2Request (`{action, resources, ...}`)
---@return string
local function permission_detail(perm)
  local resources = perm.resources or {}
  local head = resources[1]
  if head then
    return ("%s  %s"):format(perm.action or "?", head)
  end
  return perm.action or "permission request"
end

--- OpenCode's file-mutating tools, whose permission we surface as an interactive
--- diff review (rather than a plain yes/no). Names + input shapes are OpenCode's
--- public tool contracts (`edit`/`write`/`apply_patch`); we degrade gracefully if
--- an input field is absent, falling back to the four-way approval popup.
local EDIT_TOOLS = { edit = true, write = true, apply_patch = true, patch = true }

--- Render a mutating tool call's input as a reviewable patch buffer, so an edit
--- permission shows *what will change* before it's applied (the file on disk is
--- still the old version at permission time — the new content lives in the tool
--- input). Returns nil when the input can't be rendered (→ plain approval).
---@param tool string
---@param input table?
---@return { path: string, lines: string[] }?
local function render_edit(tool, input)
  input = input or {}
  local path = input.filePath or input.path or input.file
  local function split(s)
    return vim.split(s or "", "\n", { plain = true })
  end
  if tool == "apply_patch" or tool == "patch" then
    local patch = input.patch or input.diff or input.input
    if type(patch) == "string" and patch ~= "" then
      return { path = path or "(patch)", lines = split(patch) }
    end
  elseif tool == "write" then
    if path and type(input.content) == "string" then
      local out = { ("# WRITE  %s"):format(path) }
      for _, l in ipairs(split(input.content)) do
        out[#out + 1] = "+" .. l
      end
      return { path = path, lines = out }
    end
  elseif tool == "edit" then
    if path and (input.oldString or input.newString) then
      local out = { ("# EDIT  %s"):format(path) }
      for _, l in ipairs(split(input.oldString)) do
        out[#out + 1] = "-" .. l
      end
      for _, l in ipairs(split(input.newString)) do
        out[#out + 1] = "+" .. l
      end
      return { path = path, lines = out }
    end
  end
  return nil
end

--- Turn diff-review comments into the free-text `message` an OpenCode permission
--- reject can carry (its reply supports a message — a lossless rejection).
---@param path string?
---@param comments { line: integer, text: string }[]
---@return string?
local function reject_message(path, comments)
  if #comments == 0 then
    return nil
  end
  local where = path and vim.fn.fnamemodify(path, ":~:.") or "the proposed change"
  local lines = { ("Rejected the changes to %s. Feedback:"):format(where) }
  for _, c in ipairs(comments) do
    lines[#lines + 1] = ("- L%d: %s"):format(c.line, c.text)
  end
  return table.concat(lines, "\n")
end

--- Build a native OpenCode `@mention` for the current file/selection, workspace-
--- relative. A visual selection becomes `@path#Lstart-end`; otherwise `@path`.
--- OpenCode resolves these into file context exactly as its own editor
--- integration does. Returns nil when there's no real file to mention.
---@return string?
local function current_mention()
  local context = require("harnt.services.context")
  local root = context.workspace_roots()[1]
  local sel = context.selection()
  local path = (sel and sel.path) or vim.api.nvim_buf_get_name(0)
  if path == nil or path == "" then
    return nil
  end
  local rel = path
  if root and root ~= "" and path:sub(1, #root) == root then
    rel = path:sub(#root + 2)
  end
  if sel and sel.start and sel.finish and sel.start.row ~= sel.finish.row then
    return ("@%s#L%d-%d"):format(rel, sel.start.row, sel.finish.row)
  elseif sel and sel.start then
    return ("@%s#L%d"):format(rel, sel.start.row)
  end
  return "@" .. rel
end

--- Wiring the router needs — pure callbacks, injected so the tap logic is
--- unit-testable without spawning opencode, opening windows, or making HTTP calls.
---@class harnt.opencode.RouterIO
---@field ask_permission fun(perm: table, done: fun(decision: harnt.approvals.Decision)) four-way approval popup (non-edit permissions)
---@field open_edit_review fun(rendered: { path: string, lines: string[] }, done: fun(accepted: boolean, message: string?)) interactive diff review for an edit permission
---@field reply_permission fun(session_id: string, request_id: string, reply: "once"|"always"|"reject", message: string?) answer over HTTP
---@field record_change fun(change: harnt.opencode.Change) log a completed change for on-demand review
---@field note_permission fun(perm: table?) remember/forget the latest open permission
---@field emit fun(event: string, payload: table)

--- The SSE tap: decide, per decoded `/event` message, what to do. State is the
--- caller's injected IO plus two caches: per-file patches (to dedupe the
--- cumulative `session.diff` snapshots) and per-callID tool inputs (so an edit
--- permission can be shown as the actual diff, correlated via `source.callID`).
--- Unknown event types are ignored — the TUI already has them off its own client
--- connection, and we only care about the editor-shaped surface.
---@param io harnt.opencode.RouterIO
---@return { feed: fun(event: any) }
function M._router(io)
  --- path → last patch we recorded, so a re-emitted cumulative snapshot doesn't
  --- log the same change twice.
  ---@type table<string, string>
  local seen_patch = {}
  --- callID → { tool, input } from `tool.called`, so a permission that references
  --- a call can render that call's proposed change.
  ---@type table<string, { tool: string, input: table? }>
  local tool_calls = {}

  local function feed(event)
    if type(event) ~= "table" or type(event.type) ~= "string" then
      return
    end
    local props = event.properties or {}
    local t = event.type

    if t == EVENT.permission_asked then
      io.note_permission(props)
      io.emit(events.TYPES.approval_requested, { provider = event, kind = props.action })

      -- One closure answers the permission, however it was surfaced.
      local function reply(decision_reply, message)
        io.reply_permission(props.sessionID, props.id, decision_reply, message)
        io.emit(events.TYPES.approval_resolved, {
          provider = event,
          allowed = decision_reply == "once" or decision_reply == "always",
        })
        io.note_permission(nil)
      end

      -- If the permission is for a file-mutating tool we can render, show the
      -- actual change as an interactive diff (accept → once, reject → reject +
      -- any comments as feedback). Otherwise fall back to the approval popup.
      local call = props.source and props.source.callID and tool_calls[props.source.callID]
      local rendered = call and EDIT_TOOLS[call.tool] and render_edit(call.tool, call.input)
      if rendered then
        io.open_edit_review(rendered, function(accepted, message)
          reply(accepted and "once" or "reject", message)
        end)
      else
        io.ask_permission(props, function(decision)
          reply(reply_for(decision), nil)
        end)
      end
    elseif t == EVENT.permission_replied then
      -- Resolved (possibly answered in the native TUI); stop treating it as open.
      io.note_permission(nil)
    elseif t == EVENT.session_diff then
      -- `session.diff` is a *cumulative* snapshot of every file touched this
      -- session, re-sent as it grows. Record only files whose patch changed since
      -- last time, so `:Harnt changes` shows one entry per real edit, not a flood.
      -- We don't pop a review window: OpenCode applies its own edits (gated by the
      -- permission above when configured to ask), so this is a look-back log, the
      -- same role Codex's `record_change` plays for auto-applied edits.
      local fresh = {}
      for _, c in ipairs(normalize_diff(props.diff)) do
        if c.diff ~= "" and seen_patch[c.path] ~= c.diff then
          seen_patch[c.path] = c.diff
          io.record_change(c)
          fresh[#fresh + 1] = c
        end
      end
      if #fresh > 0 then
        io.emit(events.TYPES.diff_ready, { provider = event, path = fresh[1].path })
      end
    elseif t == EVENT.tool_called then
      -- Cache the call's input so a following permission (which references it by
      -- `source.callID`) can render the proposed change as a diff.
      if props.callID then
        tool_calls[props.callID] = { tool = props.tool, input = props.input }
      end
      io.emit(events.TYPES.tool_started, { provider = event, tool = props.tool })
    elseif t == EVENT.tool_success or t == EVENT.tool_failed then
      io.emit(events.TYPES.tool_completed, {
        provider = event,
        tool = props.tool,
        ok = t == EVENT.tool_success,
      })
    elseif t == EVENT.session_error then
      io.emit(events.TYPES.session_failed, { provider = event })
    end
  end

  return { feed = feed }
end

--- Ask the OS for a free loopback port (bind :0, read it back, release). We need
--- the port up front — before `opencode serve` starts — so the native TUI's
--- attach URL and our SSE client agree on it. The tiny bind/close race is
--- acceptable on loopback; a collision surfaces as a failed health poll.
---@return integer
local function free_port()
  local tcp = assert(vim.uv.new_tcp())
  tcp:bind("127.0.0.1", 0)
  local name = tcp:getsockname()
  tcp:close()
  return name and name.port or 0
end

--- Block (pumping the loop) until `GET /api/health` on `port` answers 200, or
--- `timeout_ms` elapses. Session launch is user-initiated, so a brief wait here is
--- acceptable and lets us guarantee the server is up before attaching the TUI.
---@param port integer
---@param timeout_ms integer
---@return boolean healthy
local function wait_healthy(port, timeout_ms)
  local healthy = false
  local inflight = false
  local ok = vim.wait(timeout_ms, function()
    if healthy then
      return true
    end
    if not inflight then
      inflight = true
      httpclient.request({ port = port, path = "/api/health" }, function(res)
        inflight = false
        if res and res.status == 200 then
          healthy = true
        end
      end)
    end
    return false
  end, 50)
  return ok and healthy
end

--- Whether the `opencode` CLI is available.
---@return boolean
function M.detect()
  return vim.fn.executable("opencode") == 1
end

--- `:checkhealth harnt` probes for OpenCode.
---@param report harnt.health.Report
function M.health(report)
  if vim.fn.executable("opencode") ~= 1 then
    report.error(
      "opencode CLI not found on PATH",
      "Install OpenCode (https://opencode.ai) so `opencode` is runnable."
    )
    return
  end
  report.ok("opencode CLI: " .. vim.fn.exepath("opencode"))
  report.info(
    "harnt spawns `opencode serve` (HTTP+SSE transport); the native TUI is `opencode attach`."
  )
  report.info(
    "Edit permissions show as diffs; commands as approvals; `:Harnt send` @-mentions the buffer."
  )
end

--- The native-TUI launch command (dynamic: needs the served server's URL). The
--- manager spawns this in a terminal split; it attaches to our `opencode serve`.
---@param session harnt.opencode.Session
---@return string[]
function M.cmd(session)
  return { "opencode", "attach", session.info.server_url }
end

--- No spawn-time env: the native TUI discovers the server via its `attach`
--- argument (see `cmd`), not environment variables.
---@return table<string, string>
function M.env()
  return {}
end

--- Deliver diff-review feedback. Like Antigravity, OpenCode's native feedback
--- channel is the permission reply's `message`: rejecting the diff fires the
--- `open_edit_review` callback, which declines the gated edit and carries the
--- inline comments as the reply message (see `M.start`). So review just rejects —
--- the comments ride OpenCode's own wire.
---@param ctx harnt.ReviewContext
function M.review(ctx)
  ctx.reject()
end

--- Push the current file/selection to the agent as a native `@mention`
--- (`:Harnt send`). OpenCode resolves `@path` / `@path#Lstart-end` into file
--- context; we append it to the TUI's prompt input via `/tui/append-prompt` — the
--- same channel OpenCode's own editor integration uses — leaving it for the user
--- to send, rather than auto-submitting.
---@param ctx harnt.MentionContext
function M.on_mention(ctx)
  local mention = current_mention()
  if mention then
    local session = ctx.session --[[@as harnt.opencode.Session]]
    session.append_prompt(mention .. " ")
  end
end

--- An OpenCode session. `info.server_url` is what the native TUI attaches to.
---@class harnt.opencode.Session : harnt.Session
---@field info { server_url: string, port: integer }
---@field append_prompt fun(text: string) append text to the attached TUI's prompt input
---@field pending_permission fun(): table? the latest un-replied permission, if any

--- Start an OpenCode session: spawn `opencode serve`, wait for it to be healthy,
--- then subscribe to its `/event` SSE stream and tap it. The manager launches the
--- native `opencode attach` TUI (via `M.cmd`) against `info.server_url`.
---@param ctx? harnt.SessionContext
---@return harnt.opencode.Session
function M.start(ctx)
  ctx = ctx or {}
  local bus = events.new()
  local port = free_port()
  local server_url = ("http://127.0.0.1:%d"):format(port)

  --- The latest permission we've seen asked but not yet replied — lets `review`
  --- reject the gated change with free-text feedback.
  ---@type table?
  local pending_permission = nil

  local function reply_permission(session_id, request_id, reply, message)
    if not session_id or not request_id then
      return
    end
    httpclient.request({
      port = port,
      method = "POST",
      path = ("/api/session/%s/permission/%s/reply"):format(session_id, request_id),
      json = message and { reply = reply, message = message } or { reply = reply },
    }, function()
      -- A 404 here just means it was already resolved (e.g. answered in the TUI);
      -- nothing to do — the reply is idempotent from our side.
    end)
  end

  local router = M._router({
    ask_permission = function(perm, done)
      approvals.request({
        key = "opencode:" .. (perm.action or "permission"),
        prompt = ("OpenCode: %s"):format(perm.action or "permission request"),
        detail = permission_detail(perm),
      }, function(_allowed, decision)
        done(decision)
      end)
    end,
    open_edit_review = function(rendered, done)
      -- Show the proposed change as an interactive review diff. Accept → allow the
      -- edit once; reject → decline, carrying any inline comments as free-text
      -- feedback on the reply (OpenCode's reject supports a message — lossless).
      diff.open_review(
        { path = rendered.path, patch = rendered.lines, origin = M.name },
        function(result)
          done(result.accepted, reject_message(rendered.path, result.comments))
        end
      )
    end,
    reply_permission = reply_permission,
    record_change = function(change)
      change_log.record({
        path = change.path,
        kind = change.kind,
        diff = change.diff,
        provider = M.name,
      })
    end,
    note_permission = function(perm)
      pending_permission = perm
    end,
    emit = function(event, payload)
      bus:emit(event, payload)
    end,
  })

  -- The transport: opencode's own HTTP server. `--print-logs` sends its structured
  -- logs to stderr; we don't parse them (we pre-picked the port), but capturing
  -- keeps them out of the terminal split and available for debugging.
  local serve = stdio.spawn({
    cmd = { "opencode", "serve", "--hostname", "127.0.0.1", "--port", tostring(port) },
    cwd = ctx.cwd,
    on_exit = function()
      bus:emit(events.TYPES.session_completed, { provider = M.name })
    end,
  })

  ---@type { close: fun() }?
  local stream
  local stopped = false

  -- Wait for the server, then tap /event. If it never comes up, fail loudly.
  if wait_healthy(port, 8000) then
    bus:emit(events.TYPES.session_started, { provider = M.name })
    stream = httpclient.stream({
      port = port,
      path = "/event",
      on_event = function(data)
        local ok, event = pcall(vim.json.decode, data)
        if ok then
          router.feed(event)
        end
      end,
    })
  else
    vim.schedule(function()
      vim.notify("harnt: `opencode serve` did not become healthy", vim.log.levels.ERROR)
    end)
    bus:emit(events.TYPES.session_failed, { provider = M.name })
  end

  --- Append text to the attached TUI's prompt input (context @-mentions).
  local function append_prompt(text)
    httpclient.request({
      port = port,
      method = "POST",
      path = "/tui/append-prompt",
      json = { text = text },
    }, function() end)
  end

  ---@type harnt.opencode.Session
  local session = {
    info = { server_url = server_url, port = port },
    append_prompt = append_prompt,
    pending_permission = function()
      return pending_permission
    end,
    on = function(_self, event, handler)
      return bus:on(event, handler)
    end,
    respond = function(_self, _id, _result)
      -- Approvals answer over HTTP inside the router; nothing routes through here.
    end,
    -- The native TUI drives turns and owns interrupt; nothing to do here in v1.
    interrupt = function() end,
    stop = function()
      if stopped then
        return
      end
      stopped = true
      if stream then
        stream.close()
      end
      serve.stop()
      bus:emit(events.TYPES.session_completed, { provider = M.name })
    end,
  }
  return session
end

return M
