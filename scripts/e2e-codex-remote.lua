---@diagnostic disable
-- Real-CLI end-to-end smoke against the LIVE codex `--remote` path.
--
-- Unlike scripts/e2e-codex.lua (which drives the app-server directly), this stands
-- up the REAL proxy via `codex.start()` — spawning `codex app-server` AND hosting
-- the ws server — then launches the REAL native client `codex --remote ws://…` as
-- a child, exactly as the manager would. It asserts that when the client requests
-- an edit, harnt's tap fires (open_review) and answering `accept` writes the file.
--
-- This closes the gap the demo GIF exposed: the app-server path can tap approvals,
-- but the LIVE `--remote` client only requests approval if its session approval
-- policy is `untrusted`. This test proves the exact client invocation the demo/
-- manager uses actually produces a harnt diff.
--
-- Run from a trusted repo root:  nvim -l scripts/e2e-codex-remote.lua
-- Requires `codex` on PATH + authenticated. Nondeterministic; NOT part of `just ci`.
-- Exits 0 on success, 1 otherwise.

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path = ("%s/lua/?.lua;%s/lua/?/init.lua;%s"):format(root, root, package.path)

local function log(msg)
  io.write("[e2e] " .. msg .. "\n")
  io.flush()
end

local diff = require("harnt.services.diff")
local codex = require("harnt.providers.codex")

-- Seed a fresh trusted project with a real off-by-one bug.
local ws = vim.fn.tempname()
vim.fn.mkdir(ws, "p")
vim.fn.system({ "git", "-C", ws, "init", "-q" })
local target = ws .. "/fizzbuzz.lua"
vim.fn.writefile({
  "local function fizzbuzz(n)",
  "  for i = 1, n - 1 do -- BUG: never prints n",
  "    print(i)",
  "  end",
  "end",
  "fizzbuzz(15)",
}, target)

local tapped, accepted = false, false

-- Intercept the diff service the way the demo does: record the tap, auto-accept.
diff.open_review = function(spec, cb)
  tapped = true
  log(("tapped file change: %s"):format(tostring(spec.path)))
  log(
    "diff body:\n"
      .. (type(spec.diff) == "table" and table.concat(spec.diff, "\n") or tostring(spec.diff))
  )
  cb({ accepted = true })
  accepted = true
  return 1
end

local session = codex.start({ cwd = ws })
log("proxy up at " .. session.info.remote_url)

-- Launch the REAL native client exactly as the demo does.
local PROMPT =
  "Fix the off-by-one bug in fizzbuzz.lua so it prints through n. Make the edit, then stop."
local job = vim.fn.jobstart({
  "codex",
  "--remote",
  session.info.remote_url,
  "-c",
  "approval_policy=untrusted",
  PROMPT,
}, { cwd = ws, pty = true })
assert(job > 0, "failed to spawn codex --remote")
log("spawned codex --remote (job " .. job .. ")")

-- Wait for the tap (bounded).
local deadline = vim.loop.now() + 150000
while not tapped and vim.loop.now() < deadline do
  vim.wait(500)
end

vim.fn.jobstop(job)
session.stop()

log(("tapped=%s accepted=%s"):format(tostring(tapped), tostring(accepted)))
if tapped and accepted then
  log("PASS")
  os.exit(0)
else
  log("FAIL: the live --remote client never produced a harnt diff")
  os.exit(1)
end
