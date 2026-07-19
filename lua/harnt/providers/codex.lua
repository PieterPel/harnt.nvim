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
local diff = require("harnt.services.diff")
local events = require("harnt.events")
local stdio = require("harnt.transport.stdio")
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
    open_review = function(changes, resolve)
      local path = (changes[1] and changes[1].path) or "(codex change)"
      bus:emit(events.TYPES.diff_ready, { provider = { changes = changes }, path = path })
      diff.open_review({ path = path, patch = render_patch(changes) }, function(result)
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
      server.close()
      appserver.stop()
      bus:emit(events.TYPES.session_completed, { provider = M.name })
    end,
  }
  return session
end

return M
