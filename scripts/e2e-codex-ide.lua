---@diagnostic disable
-- Real-CLI end-to-end smoke for Codex's /ide CONTEXT channel (separate from the
-- app-server diff proxy that e2e-codex.lua covers).
--
-- harnt hosts the /ide unix socket via the real `codex.serve_ide_context`; we then
-- launch the actual interactive `codex` TUI over a PTY, type `/ide`, and assert
-- that real codex connected to our socket and issued an `ide-context` request that
-- we answered with the live editor context. This exercises the exact wire
-- (`$TMPDIR/codex-ipc/ipc-{uid}.sock`, u32-LE JSON frames) against the real binary.
--
-- Run from a trusted repo root:  just e2e-codex-ide   (needs `codex` authed).
-- Nondeterministic + real binary, so NOT part of `just ci`.

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path = ("%s/lua/?.lua;%s/lua/?/init.lua;%s"):format(root, root, package.path)

local function log(msg)
  io.write("[e2e] " .. msg .. "\n")
  io.flush()
end

local codex = require("harnt.providers.codex")

if not codex.detect() then
  log("SKIP: codex not on PATH")
  os.exit(1)
end

-- Open a real file so the context we serve is non-empty.
local ws = vim.fn.tempname()
vim.fn.mkdir(ws, "p")
local file = ws .. "/sample.lua"
vim.fn.writefile({ "local x = 1", "local y = 2", "return x + y" }, file)
vim.cmd.edit(file)
vim.api.nvim_win_set_cursor(0, { 2, 0 })

-- Capture each ide-context request the real codex sends us.
local requests = {}
local orig = codex._ide_response
codex._ide_response = function(req)
  requests[#requests + 1] = req
  local frame = orig(req)
  log(("answered ide-context requestId=%s"):format(tostring(req.requestId)))
  return frame
end

local ide = codex.serve_ide_context(function()
  log("hosting /ide socket")
end)

-- Let the async bind settle, then launch the real codex TUI over a PTY.
vim.wait(500)

-- Track TUI state: a first-run directory-trust prompt, the composer being ready,
-- and whether /ide was acknowledged.
local trust_prompt, composer_ready, ide_ack = false, false, false
local job = vim.fn.jobstart({ "codex" }, {
  cwd = ws,
  pty = true,
  width = 120,
  height = 40,
  env = { TERM = "xterm-256color" },
  on_stdout = function(_, data)
    for _, line in ipairs(data or {}) do
      local clean = line:gsub("\27%][%d;]*[^\7\27]*[\7]?", ""):gsub("\27%[[%d;?]*[a-zA-Z]", "")
      clean = clean:gsub("[\r%z]", "")
      if clean:match("%S") then
        log("codex> " .. clean)
      end
      if clean:find("Yes, continue") or clean:find("Trusting the directory") then
        trust_prompt = true
      end
      if
        clean:find("default ·")
        or clean:find("Find and fix a bug")
        or clean:find("Ask Codex")
      then
        composer_ready = true
      end
      if clean:find("IDE context is on") or clean:find("could not be enabled") then
        ide_ack = true
      end
    end
  end,
})
if job <= 0 then
  log("FAIL: could not launch codex")
  os.exit(1)
end

-- Clear the first-run "trust this directory?" prompt (default = Yes, continue).
vim.wait(12000, function()
  return trust_prompt or composer_ready
end, 100)
if trust_prompt and not composer_ready then
  log("accepting directory-trust prompt")
  vim.fn.chansend(job, "\r")
end

-- Now wait for the composer.
vim.wait(15000, function()
  return composer_ready
end, 100)
vim.wait(2000)
log("composer ready=" .. tostring(composer_ready) .. "; sending /ide")

-- Type the command char-by-char, then submit. Retry Enter until codex
-- acknowledges /ide or a context request arrives.
for ch in ("/ide"):gmatch(".") do
  vim.fn.chansend(job, ch)
  vim.wait(80)
end
vim.wait(1000)
for _ = 1, 8 do
  vim.fn.chansend(job, "\r")
  if vim.wait(2500, function()
    return #requests > 0 or ide_ack
  end, 100) then
    break
  end
end

vim.wait(4000, function()
  return #requests > 0
end, 100)

pcall(vim.fn.chansend, job, "\3") -- Ctrl-C to quit the TUI
vim.wait(500)
pcall(vim.fn.jobstop, job)
ide.close()

if #requests > 0 then
  local r = requests[1]
  log(
    ("got %d ide-context request(s); method=%s workspaceRoot=%s"):format(
      #requests,
      tostring(r.method),
      tostring(r.params and r.params.workspaceRoot)
    )
  )
  log("PASS — real codex pulled editor context over harnt's /ide socket")
  os.exit(0)
end
log("FAIL: codex never requested ide-context (did /ide connect?)")
os.exit(1)
