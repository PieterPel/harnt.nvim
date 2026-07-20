---@diagnostic disable
-- Real-CLI end-to-end smoke against OpenCode (HTTP-server + SSE-tap path).
--
-- Exercises harnt's ACTUAL transport + provider code against the real `opencode`
-- binary, headlessly:
--   1. spawns the real `opencode serve` (via transport/stdio),
--   2. waits for it to be healthy over harnt's real httpclient (real HTTP),
--   3. subscribes to the real `/event` SSE stream through httpclient.stream and
--      asserts we parse real events (server.connected) via our SSE parser,
--   4. creates a session over a real POST and asserts a 200 + session id.
--
-- What it does NOT do: drive a turn. OpenCode's `serve` admits prompts but does
-- not execute turns without a connected DRIVING client — the native TUI
-- (`opencode attach`) is the driver (see OPENCODE.md, "the load-bearing
-- discovery"). So a live `permission.v2.asked` / `session.diff` only appears with
-- the TUI attached; that hop is best eyeballed via `just try` + `:Harnt open
-- opencode` and is the interactive part of the no-feature-loss check. This smoke proves the wire and
-- our transport against the real server; the router that turns those events into
-- diffs/approvals is unit-tested in tests/providers/opencode_spec.lua.
--
-- Run from a trusted repo root:  nvim -l scripts/e2e-opencode.lua  (or: just e2e-opencode)
-- Requires `opencode` on PATH. Real process + real HTTP; NOT part of `just ci`.
-- Exits 0 on success, 1 otherwise.

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path = ("%s/lua/?.lua;%s/lua/?/init.lua;%s"):format(root, root, package.path)

local function log(msg)
  io.write("[e2e] " .. msg .. "\n")
  io.flush()
end

if vim.fn.executable("opencode") ~= 1 then
  log("SKIP — `opencode` not on PATH")
  os.exit(0)
end

local stdio = require("harnt.transport.stdio")
local httpclient = require("harnt.transport.httpclient")

-- Pick a free loopback port (bind :0, read it back, release).
local probe = assert(vim.uv.new_tcp())
probe:bind("127.0.0.1", 0)
local port = probe:getsockname().port
probe:close()

local ws = vim.fn.tempname()
vim.fn.mkdir(ws, "p")
log("workdir=" .. ws .. " port=" .. port)

local serve = stdio.spawn({
  cmd = { "opencode", "serve", "--hostname", "127.0.0.1", "--port", tostring(port) },
  cwd = ws,
})

-- 1) health
local healthy = false
vim.wait(15000, function()
  if healthy then
    return true
  end
  httpclient.request({ port = port, path = "/api/health" }, function(res)
    if res and res.status == 200 and res.body:find("healthy") then
      healthy = true
    end
  end)
  return false
end, 200)
log("healthy=" .. tostring(healthy))

-- 2) SSE tap — assert we parse a real event through our real transport.
local saw_connected = false
local events_seen = 0
local stream = httpclient.stream({
  port = port,
  path = "/event",
  on_event = function(data)
    events_seen = events_seen + 1
    local ok, e = pcall(vim.json.decode, data)
    if ok and e.type == "server.connected" then
      saw_connected = true
    end
  end,
})
vim.wait(5000, function()
  return saw_connected
end, 100)
log(("sse: events=%d server.connected=%s"):format(events_seen, tostring(saw_connected)))

-- 3) create a session over a real POST.
local session_id
vim.wait(8000, function()
  if session_id then
    return true
  end
  httpclient.request({
    port = port,
    method = "POST",
    path = "/api/session",
    json = vim.empty_dict(),
  }, function(res)
    if res and res.status == 200 then
      local ok, body = pcall(vim.json.decode, res.body)
      if ok and body.data and body.data.id then
        session_id = body.data.id
      end
    end
  end)
  return false
end, 200)
log("session_id=" .. tostring(session_id))

-- 4) context push: POST /tui/append-prompt round-trips through our HTTP client.
local appended
vim.wait(5000, function()
  if appended ~= nil then
    return true
  end
  httpclient.request({
    port = port,
    method = "POST",
    path = "/tui/append-prompt",
    json = { text = "@README.md " },
  }, function(res)
    appended = res and res.status or false
  end)
  return false
end, 200)
log("append-prompt status=" .. tostring(appended))

stream.close()
serve.stop()

if healthy and saw_connected and session_id and appended then
  log("PASS — real opencode serve reached over harnt's HTTP client + SSE tap + tui push")
  log("NOTE: drive a turn with the native TUI (`just try` + `:Harnt open opencode`)")
  log("      permission/diff route through the shared services.")
  os.exit(0)
end
log("FAIL")
os.exit(1)
