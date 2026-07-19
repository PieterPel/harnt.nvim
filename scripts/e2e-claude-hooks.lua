---@diagnostic disable
-- Real-CLI end-to-end smoke: Claude auto-accept edits reach the change-log.
--
-- `claude.start()` injects a PostToolUse hook (via --settings) and tails its
-- output file. This drives a real `claude -p` edit in bypassPermissions mode
-- (no openDiff, no prompt) and asserts the edit is recorded in the change-log —
-- proving auto-applied edits are captured even when the IDE diff never fires.
--
-- Run from a trusted repo root:  nvim -l scripts/e2e-claude-hooks.lua
--   (or: just e2e-claude-hooks). Requires `claude` on PATH + authenticated.
-- Nondeterministic + real API calls; NOT part of `ci`. Exits 0 on success.

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path = ("%s/lua/?.lua;%s/lua/?/init.lua;%s"):format(root, root, package.path)

local function log(m)
  io.write("[e2e] " .. m .. "\n")
  io.flush()
end

local change_log = require("harnt.services.changes")
local claude = require("harnt.providers.claude")
change_log.clear()

local work = vim.fn.tempname()
vim.fn.mkdir(work, "p")

local session = claude.start({})
local job = vim.fn.jobstart({
  "claude",
  "-p",
  "Create a file hello.txt containing exactly: hi there",
  "--permission-mode",
  "bypassPermissions",
  "--settings",
  session.settings_json,
}, { cwd = work, env = claude.env(session.info) })

vim.wait(90000, function()
  return change_log.count() > 0
end, 200)

local recorded = change_log.count() > 0
if recorded then
  local c = change_log.list()[1]
  log(("recorded [%s] %s %s"):format(c.provider, c.kind, c.path))
end
log("recorded=" .. tostring(recorded))

pcall(vim.fn.jobstop, job)
session:stop()
log(recorded and "PASS" or "FAIL")
os.exit(recorded and 0 or 1)
