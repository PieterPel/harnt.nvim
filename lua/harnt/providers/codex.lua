--- Codex provider — app-server proxy (full-fidelity reverse channel).
---
--- Codex's terminal `/ide` socket is context-only (no diffs), so we take the
--- channel that DOES carry diffs + answerable approvals: `codex app-server`.
--- harnt spawns the app-server and speaks its JSON protocol over **stdio** as its
--- sole client, while the user's *native* `codex --remote ws://…` TUI connects to
--- a WebSocket server we host and renders the chat itself. harnt sits in the
--- middle as a transparent proxy and *taps* the stream: file changes and approval
--- requests are peeled off and routed through our own `diff`/`approvals` services;
--- everything else is relayed untouched.
---
--- This is the codex-shaped equivalent of Claude's `openDiff` callback — obtained
--- by proxying app-server rather than receiving a direct call. We never render the
--- chat (the native TUI does), so it stays on-thesis with no feature loss. See
--- CODEX.md for the full reverse-engineering record and the exact wire.
---
--- All app-server protocol knowledge (method names, decision enums, payload
--- shapes) lives in THIS file; the generic layers stay agent-agnostic.

local approvals = require("harnt.services.approvals")
local change_log = require("harnt.services.changes")
local context = require("harnt.services.context")
local diff = require("harnt.services.diff")
local events = require("harnt.events")
local stdio = require("harnt.transport.stdio")
local unixsock = require("harnt.transport.unixsock")
local ws = require("harnt.transport.ws")

local M = {}

M.name = "codex"

--- app-server request methods we intercept. v1 and v2 protocol names both handled
--- (we negotiate v2 by default; v1 is the legacy inline-diff variant).
local METHOD = {
  file_approval_v2 = "item/fileChange/requestApproval",
  file_approval_v1 = "applyPatchApproval",
  cmd_approval_v2 = "item/commandExecution/requestApproval",
  cmd_approval_v1 = "execCommandApproval",
}

--- Decision strings per protocol version (verified from `generate-json-schema`).
local DECISION = {
  v2 = { allow = "accept", deny = "decline" },
  v1 = { allow = "approved", deny = "denied" },
}

--- A single normalized file change.
---@class harnt.codex.Change
---@field path string
---@field kind string "add" | "update" | "delete"
---@field diff string full content (add) or a unified diff (update)

--- Normalize the two approval payload shapes into a flat change list.
--- v1 (`applyPatchApproval`) carries `fileChanges` inline as a path→change map;
--- v2 references an `itemId` whose diff arrived earlier on a `fileChange` item.
---@param params table the approval request params
---@param item_changes any[]? the correlated fileChange item's `changes` (v2)
---@return harnt.codex.Change[]
local function normalize_changes(params, item_changes)
  local out = {}
  if type(params.fileChanges) == "table" then -- v1: inline map
    for path, ch in pairs(params.fileChanges) do
      out[#out + 1] =
        { path = path, kind = ch.type or "update", diff = ch.unified_diff or ch.content or "" }
    end
    return out
  end
  for _, ch in ipairs(item_changes or {}) do -- v2: from the fileChange item
    out[#out + 1] = {
      path = ch.path,
      kind = (type(ch.kind) == "table" and ch.kind.type) or "update",
      diff = ch.diff or "",
    }
  end
  return out
end

--- Render a change list as one reviewable patch buffer (one approval can touch
--- several files; one verdict covers them all, matching codex's semantics).
---@param changes harnt.codex.Change[]
---@return string[]
local function render_patch(changes)
  local lines = {}
  for _, c in ipairs(changes) do
    lines[#lines + 1] = ("# %s  %s"):format((c.kind or "update"):upper(), c.path)
    for _, l in ipairs(vim.split(c.diff or "", "\n", { plain = true })) do
      lines[#lines + 1] = l
    end
    lines[#lines + 1] = ""
  end
  return lines
end

--- Wiring the router needs — all pure functions, injected so the tap logic is
--- unit-testable without spawning codex or opening windows.
---@class harnt.codex.RouterIO
---@field send_upstream fun(obj: any) send a JSON object to app-server
---@field forward_to_tui fun(raw: string) relay a raw frame to the native TUI
---@field open_review fun(changes: harnt.codex.Change[], resolve: fun(accepted: boolean)) show a diff, resolve on verdict
---@field request_command fun(params: table, resolve: fun(allowed: boolean)) prompt a command approval
---@field record_change fun(change: harnt.codex.Change) log a completed change for on-demand review
---@field emit fun(event: string, payload: table)

--- The proxy tap: decide, per upstream (app-server → client) message, whether to
--- intercept it (file/command approval → our services) or relay it to the TUI.
--- Notifications carrying `fileChange` items are captured for v2 diff correlation
--- and still relayed. We do NOT touch the TUI's own requests — codex runs under
--- its own approval policy, and we surface a diff/approval only when it asks.
--- Pure; the only state is the itemId→changes cache.
---@param io harnt.codex.RouterIO
---@return { feed_upstream: fun(obj: any, raw: string) }
function M._router(io)
  ---@type table<string, any[]>
  local changes_by_item = {}

  --- Answer an approval request once the user decides.
  ---@param id harnt.jsonrpc.Id
  ---@param v2 boolean
  ---@param allowed boolean
  local function answer(id, v2, allowed)
    local d = v2 and DECISION.v2 or DECISION.v1
    io.send_upstream({ id = id, result = { decision = allowed and d.allow or d.deny } })
    io.emit(events.TYPES.approval_resolved, { provider = { id = id }, allowed = allowed })
  end

  local function feed_upstream(obj, raw)
    if type(obj) ~= "table" then
      io.forward_to_tui(raw)
      return
    end
    local method, id = obj.method, obj.id

    -- Notification (method, no id): capture fileChange items, always relay.
    if method and id == nil then
      local item = obj.params and obj.params.item
      if type(item) == "table" and item.type == "fileChange" and item.changes then
        changes_by_item[item.id] = item.changes
        -- On completion, log the change for on-demand review — this happens for
        -- EVERY edit (approved or auto-applied), so you can always see what the
        -- agent did without us gating its flow.
        if method == "item/completed" then
          for _, c in ipairs(normalize_changes({}, item.changes)) do
            io.record_change(c)
          end
        end
      end
      io.forward_to_tui(raw)
      return
    end

    -- Server-initiated request (method + id): intercept approvals, relay the rest.
    if method and id ~= nil then
      if method == METHOD.file_approval_v2 or method == METHOD.file_approval_v1 then
        local v2 = method == METHOD.file_approval_v2
        local params = obj.params or {}
        local changes = normalize_changes(params, changes_by_item[params.itemId])
        io.emit(events.TYPES.approval_requested, { provider = obj, kind = "file" })
        io.open_review(changes, function(accepted)
          answer(id, v2, accepted)
        end)
        return -- intercepted: the TUI never sees the prompt
      elseif method == METHOD.cmd_approval_v2 or method == METHOD.cmd_approval_v1 then
        local v2 = method == METHOD.cmd_approval_v2
        io.emit(events.TYPES.approval_requested, { provider = obj, kind = "command" })
        io.request_command(obj.params or {}, function(allowed)
          answer(id, v2, allowed)
        end)
        return
      end
      io.forward_to_tui(raw) -- other server requests: TUI handles + responds
      return
    end

    -- A response to a request, or anything else: relay untouched.
    io.forward_to_tui(raw)
  end

  return { feed_upstream = feed_upstream }
end

-- === /ide context socket ========================================================
-- A SECOND, independent codex reverse channel, orthogonal to the app-server proxy
-- above. codex's TUI (including `codex --remote`) pulls editor context — active
-- file, selection, open tabs — over a unix socket at
-- `$TMPDIR/codex-ipc/ipc-{uid}.sock`, length-prefixed JSON. harnt HOSTS that
-- socket and answers each `ide-context` request with the live editor state from
-- our shared `context` service. It carries no diffs/approvals (those are the
-- app-server's job); this is pure context push, the codex analogue of Claude's
-- `getCurrentSelection`/`getOpenEditors`. Wire verified against codex-0.144.x
-- (`tui/src/ide_context/ipc.rs`): editor = server, codex = client; codex sends
-- `{type:"request", requestId, method:"ide-context", params:{workspaceRoot}}` and
-- reads `result.ideContext`. See CODEX.md.

--- 4-byte little-endian length encoding.
---@param n integer
---@return string
local function le32(n)
  return string.char(
    n % 256,
    math.floor(n / 0x100) % 256,
    math.floor(n / 0x10000) % 256,
    math.floor(n / 0x1000000) % 256
  )
end

--- A pure frame reader for the `/ide` wire: 4-byte LE length prefix + JSON body.
--- Feed arbitrary byte chunks; get back decoded request objects. Partial trailing
--- bytes are retained until the frame completes.
---@return { feed: fun(chunk: string): table[] }
function M._ide_frame_reader()
  local buf = ""
  return {
    feed = function(chunk)
      buf = buf .. chunk
      local out = {} ---@type table[]
      while #buf >= 4 do
        local a, b, c, d = buf:byte(1, 4)
        local len = math.floor(a + b * 0x100 + c * 0x10000 + d * 0x1000000)
        if #buf < 4 + len then
          break
        end
        local payload = buf:sub(5, 4 + len)
        buf = buf:sub(5 + len)
        local ok, obj = pcall(vim.json.decode, payload)
        if ok and type(obj) == "table" then
          out[#out + 1] = obj
        end
      end
      return out
    end,
  }
end

--- Encode one `/ide` frame (LE length prefix + JSON).
---@param obj table
---@return string
local function ide_frame(obj)
  local body = vim.json.encode(obj)
  return le32(#body) .. body
end

--- A file descriptor as the `/ide` schema shapes it: display label, workspace-
--- relative `path`, absolute `fsPath`.
---@param path string absolute file path
---@param root? string workspace root to relativize against
---@return { label: string, path: string, fsPath: string }
local function descriptor(path, root)
  local rel = path
  if root and root ~= "" and path:sub(1, #root) == root then
    rel = path:sub(#root + 2) -- strip "root/"
  end
  return { label = vim.fn.fnamemodify(path, ":t"), path = rel, fsPath = path }
end

--- Build the `ideContext` payload from the live editor state: the active file
--- with its selection, plus the open editors. 0-indexed LSP positions.
---@return table
function M._ide_context()
  local root = context.workspace_roots()[1]
  local sel = context.selection()
  local active_path = sel and sel.path or vim.api.nvim_buf_get_name(0)

  ---@type table
  local active_file = vim.empty_dict()
  if active_path ~= "" then
    local d = descriptor(active_path, root)
    local selection, content
    if sel then
      selection = {
        start = { line = sel.start.row - 1, character = sel.start.col },
        ["end"] = { line = sel.finish.row - 1, character = sel.finish.col },
      }
      content = sel.text
    else
      local cur = context.cursor()
      local pos = { line = cur.row - 1, character = cur.col }
      selection = { start = pos, ["end"] = pos }
      content = ""
    end
    active_file = {
      label = d.label,
      path = d.path,
      fsPath = d.fsPath,
      selection = selection,
      activeSelectionContent = content,
      selections = { selection },
    }
  end

  local open_tabs = {}
  for _, b in ipairs(context.buffers()) do
    if b.path ~= "" then
      open_tabs[#open_tabs + 1] = descriptor(b.path, root)
    end
  end

  return { activeFile = active_file, openTabs = open_tabs }
end

--- Build the response frame answering an `ide-context` request.
---@param req table the decoded request object
---@return string
function M._ide_response(req)
  return ide_frame({
    type = "response",
    requestId = req.requestId,
    resultType = "success",
    method = "ide-context",
    handledByClientId = "harnt",
    result = { ideContext = M._ide_context() },
  })
end

--- The `/ide` context socket path for the current user.
---@return string dir, string sock
local function ide_socket_path()
  local tmp = vim.env.TMPDIR or vim.uv.os_tmpdir() or "/tmp"
  tmp = (tmp:gsub("/+$", ""))
  local dir = tmp .. "/codex-ipc"
  local uid = vim.uv.getuid and vim.uv.getuid() or 0
  return dir, ("%s/ipc-%d.sock"):format(dir, uid)
end

--- Host the `/ide` context socket. Best-effort: if the rendezvous path is already
--- owned by a live editor (e.g. a running IDE), we leave it alone and skip context
--- rather than clobber it. Returns a server handle (with `close`) or nil.
---@param on_ready? fun(server: harnt.unixsock.Server)
---@return { close: fun() }
function M.serve_ide_context(on_ready)
  local dir, sock = ide_socket_path()
  -- codex refuses a socket dir that isn't owner-only; ensure it's 0700 whether we
  -- create it or it already exists from a prior run.
  vim.fn.mkdir(dir, "p")
  pcall(vim.uv.fs_chmod, dir, 448) -- 0o700, owner-only

  local server ---@type harnt.unixsock.Server?
  local wanted = true

  unixsock.free_stale(sock, function(free)
    if not free or not wanted then
      if not free then
        vim.schedule(function()
          vim.notify(
            "harnt: codex /ide socket is owned by another editor; skipping context push",
            vim.log.levels.WARN
          )
        end)
      end
      return
    end
    local s, err = unixsock.server({
      path = sock,
      on_connection = function(conn)
        local reader = M._ide_frame_reader()
        conn.read_start(function(chunk)
          for _, req in ipairs(reader.feed(chunk)) do
            if req.type == "request" and req.method == "ide-context" then
              conn.write(M._ide_response(req))
            end
          end
        end)
      end,
    })
    if not s then
      vim.schedule(function()
        vim.notify("harnt: codex /ide socket unavailable: " .. tostring(err), vim.log.levels.WARN)
      end)
      return
    end
    server = s
    if on_ready then
      on_ready(s)
    end
  end)

  return {
    close = function()
      wanted = false
      if server then
        server.close()
      end
    end,
  }
end

--- Deliver diff-review feedback: decline the patch, then type the comments into
--- the native codex TUI as a follow-up message. codex's decline decision carries
--- no free-text, so prose-into-the-TUI is the native feedback path (the same
--- shape as Claude's openDiff review). `reject` resolves the app-server approval
--- as declined; `send_text` types into the `codex --remote` terminal.
---@param ctx harnt.ReviewContext
function M.review(ctx)
  ctx.reject()
  if #ctx.comments == 0 then
    return
  end
  local where = ctx.path and vim.fn.fnamemodify(ctx.path, ":~:.") or "the proposed changes"
  local lines = { ("I rejected the changes to %s. Feedback:"):format(where) }
  for _, comment in ipairs(ctx.comments) do
    lines[#lines + 1] = ("- L%d: %s"):format(comment.line, comment.text)
  end
  ctx.send_text(table.concat(lines, "\n"))
end

--- Whether the `codex` CLI is available.
---@return boolean
function M.detect()
  return vim.fn.executable("codex") == 1
end

--- The native-TUI launch command (dynamic: needs the proxy's ws port). The
--- manager spawns this in a terminal split; it connects back to our proxy.
---@param session harnt.codex.Session
---@return string[]
function M.cmd(session)
  return { "codex", "--remote", session.info.remote_url }
end

--- A Codex session. `info.remote_url` is the ws endpoint the native TUI dials.
---@class harnt.codex.Session : harnt.Session
---@field info { remote_url: string, port: integer }

--- Start a Codex session: spawn `codex app-server` (stdio), host a ws server for
--- the native `--remote` TUI, and proxy + tap the stream.
---@param ctx? harnt.SessionContext
---@return harnt.codex.Session
function M.start(ctx)
  ctx = ctx or {}
  local bus = events.new()

  ---@type harnt.ws.Connection?
  local tui -- the single native-TUI connection

  ---@type harnt.stdio.Handle
  local appserver

  local router = M._router({
    send_upstream = function(obj)
      appserver.send(obj)
    end,
    forward_to_tui = function(raw)
      if tui then
        tui:send(raw)
      end
    end,
    open_review = function(file_changes, resolve)
      local path = (file_changes[1] and file_changes[1].path) or "(codex change)"
      bus:emit(events.TYPES.diff_ready, { provider = { changes = file_changes }, path = path })
      diff.open_review({ path = path, patch = render_patch(file_changes) }, function(result)
        resolve(result.accepted)
      end)
    end,
    request_command = function(params, resolve)
      approvals.request({
        key = "codex:command",
        prompt = "Codex wants to run a command",
        detail = params.command or params.reason,
      }, function(allowed)
        resolve(allowed)
      end)
    end,
    record_change = function(change)
      change_log.record({
        path = change.path,
        kind = change.kind,
        diff = change.diff,
        provider = M.name,
      })
    end,
    emit = function(event, payload)
      bus:emit(event, payload)
    end,
  })

  -- Upstream: app-server → us (already on the main loop, safe to touch nvim).
  appserver = stdio.spawn({
    cmd = { "codex", "app-server" },
    cwd = ctx.cwd,
    on_message = function(obj, raw)
      router.feed_upstream(obj, raw)
    end,
    on_exit = function()
      bus:emit(events.TYPES.session_completed, { provider = M.name })
    end,
  })

  -- Downstream: the native TUI → us → app-server. Raw relay (fast-path callback).
  local server, err = ws.server({
    on_open = function(client)
      tui = client
      vim.schedule(function()
        bus:emit(events.TYPES.session_started, { provider = M.name })
      end)
    end,
    on_message = function(_client, payload)
      appserver.write(payload .. "\n")
    end,
    on_close = function(client)
      if tui == client then
        tui = nil
      end
    end,
  })
  assert(server, "codex: could not start proxy ws server: " .. tostring(err))

  -- Second reverse channel: host the /ide context socket so the native TUI can
  -- pull the live editor selection / open files. Independent of the proxy above.
  local ide = M.serve_ide_context()

  local stopped = false

  ---@type harnt.codex.Session
  local session = {
    info = { remote_url = ("ws://127.0.0.1:%d"):format(server.port), port = server.port },
    on = function(_self, event, handler)
      return bus:on(event, handler)
    end,
    respond = function(_self, id, result)
      appserver.send({ id = id, result = result })
    end,
    -- The native TUI drives turns and owns interrupt; nothing to do here in v1.
    interrupt = function() end,
    stop = function()
      if stopped then
        return
      end
      stopped = true
      ide.close()
      server.close()
      appserver.stop()
      bus:emit(events.TYPES.session_completed, { provider = M.name })
    end,
  }
  return session
end

return M
