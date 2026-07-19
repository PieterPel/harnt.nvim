---@diagnostic disable
-- Real-CLI end-to-end smoke against Codex (app-server proxy path).
--
-- Drives the actual `codex app-server` through harnt's real transport + tap: it
-- spawns the app-server via `transport/stdio`, drives one file-editing turn
-- (initialize → thread/start → turn/start), and feeds every app-server frame
-- through the actual `codex._router`. It asserts the router taps the file-change
-- approval, hands us the diff, and that answering `accept` makes the real codex
-- write the file to disk.
--
-- This exercises the exact code the live proxy uses (stdio transport + router +
-- decision wire) against the real binary. It does NOT drive the interactive
-- `codex --remote` TUI — that hop is generic ws.lua (unit-tested) and is best
-- eyeballed via `just try-codex`.
--
-- Run from a trusted repo root:  nvim -l scripts/e2e-codex.lua   (or: just e2e-codex)
-- Requires `codex` on PATH + authenticated. Nondeterministic (real model), makes
-- real API calls, so it is NOT part of `just ci`. Exits 0 on success, 1 otherwise.

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path = ("%s/lua/?.lua;%s/lua/?/init.lua;%s"):format(root, root, package.path)

local function log(msg)
  io.write("[e2e] " .. msg .. "\n")
  io.flush()
end

local stdio = require("harnt.transport.stdio")
local codex = require("harnt.providers.codex")

local ws = vim.fn.tempname()
vim.fn.mkdir(ws, "p")

local got_diff = false
local decided = false
local appserver

-- The proxy tap, wired to record the diff and auto-accept it.
local router = codex._router({
  send_upstream = function(obj)
    appserver.send(obj)
  end,
  forward_to_tui = function(_raw) end, -- no TUI in this smoke
  open_review = function(changes, resolve)
    got_diff = true
    log(
      ("tapped file change: %s (%s)"):format(
        changes[1] and changes[1].path or "?",
        changes[1] and changes[1].kind or "?"
      )
    )
    log("diff body:\n" .. (changes[1] and changes[1].diff or ""))
    resolve(true) -- accept: real codex should now write the file
    decided = true
  end,
  request_command = function(_params, resolve)
    resolve(false)
  end,
  emit = function(_ev, _p) end,
})

appserver = stdio.spawn({
  cmd = { "codex", "app-server" },
  cwd = ws,
  on_message = function(obj, raw)
    router.feed_upstream(obj, raw)
    -- Drive the turn off the responses we get back.
    if type(obj) == "table" and obj.id and obj.result then
      if obj.result.codexHome ~= nil then -- initialize response
        appserver.send({
          id = 2,
          method = "thread/start",
          params = { cwd = ws, sandbox = "workspace-write", approvalPolicy = "untrusted" },
        })
      elseif obj.result.thread and obj.result.thread.id then -- thread/start response
        appserver.send({
          id = 3,
          method = "turn/start",
          params = {
            threadId = obj.result.thread.id,
            input = {
              {
                type = "text",
                text = "Create a new file hello.txt containing exactly: hi there. Make the edit now.",
              },
            },
          },
        })
      end
    end
  end,
})

appserver.send({
  id = 1,
  method = "initialize",
  params = { clientInfo = { name = "harnt-e2e", version = "0.0.0" } },
})

vim.wait(120000, function()
  return decided
end, 100)

-- Give real codex a moment to apply the accepted patch.
vim.wait(6000, function()
  return vim.fn.filereadable(ws .. "/hello.txt") == 1
end, 100)

local wrote = vim.fn.filereadable(ws .. "/hello.txt") == 1
appserver.stop()

log(
  "tapped_diff="
    .. tostring(got_diff)
    .. " accepted="
    .. tostring(decided)
    .. " file_written="
    .. tostring(wrote)
)
if got_diff and wrote then
  log("PASS")
  os.exit(0)
end
log("FAIL")
os.exit(1)
