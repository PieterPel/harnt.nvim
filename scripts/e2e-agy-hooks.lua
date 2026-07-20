---@diagnostic disable
-- Real-CLI end-to-end smoke against Antigravity (`agy`) via the lifecycle-hook gate.
--
-- Drives the REAL *interactive* `agy` TUI over a PTY — the exact way harnt runs it
-- (the manager spawns `agy` in a Neovim terminal split). harnt's provider hosts
-- the hook decision socket and installs `.agents/hooks.json`; we exercise the REAL
-- provider path (`_on_hook` → `_handle_tool_use` → the `diff` review) and only
-- inject the review VERDICT (accept / reject) via a wrapped `diff.open_review`.
--
-- Two phases isolate our gate as the sole decider:
--   * REJECT the diff  → agy must NOT write the file.
--   * ACCEPT the diff  → provider replies allow + `permissionOverrides`, so agy's
--                        own permission is satisfied by our accept and it writes.
-- Together they prove agy obeys harnt's verdict both ways, in the interactive mode
-- harnt actually uses. We also harvest the real `toolCall.args` and confirm they
-- map through the normalizer.
--
-- Run from a trusted repo root:  just e2e-agy-hooks   (needs `agy` authed + `nc`).
-- Nondeterministic (real model) + real API calls, so NOT part of `just ci`.

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path = ("%s/lua/?.lua;%s/lua/?/init.lua;%s"):format(root, root, package.path)

local function log(msg)
  io.write("[e2e] " .. msg .. "\n")
  io.flush()
end

local agy = require("harnt.providers.antigravity")
local diff = require("harnt.services.diff")
local approvals = require("harnt.services.approvals")

if not agy.detect() then
  log("SKIP: agy not on PATH")
  os.exit(1)
end

-- Auto-resolve any diff review / command approval with the phase's verdict, so the
-- REAL provider handler runs unattended. No UI is opened (no-op presenter).
---@param accept boolean
local function auto_resolve(accept)
  diff.set_review_presenter(function()
    return { teardown = function() end }
  end)
  local orig_open_review = diff.open_review
  diff.open_review = function(spec, cb)
    local id = orig_open_review(spec, cb)
    vim.schedule(function()
      if accept then
        diff.accept(id)
      else
        diff.reject(id)
      end
    end)
    return id
  end
  approvals.set_chooser(function(_req, on_choice)
    on_choice(accept and "allow_once" or "deny_once")
  end)
  return function()
    diff.open_review = orig_open_review
    diff.set_review_presenter(nil)
    approvals.set_chooser(nil)
  end
end

-- Run one interactive `agy` turn; resolve the diff per `accept`. Returns whether
-- an edit hook fired, whether PreInvocation fired, whether the file landed, and
-- the captured edit args (via a thin capture wrapper over the real `_on_hook`).
---@param accept boolean
---@return { saw_tool: boolean, saw_preinvocation: boolean, wrote: boolean, args: table? }
local function run_agy(accept)
  local phase = accept and "accept" or "reject"
  local ws = vim.fn.tempname()
  vim.fn.mkdir(ws, "p")
  vim.fn.system({ "git", "-C", ws, "init", "-q" })
  local target = ws .. "/hello.txt"

  local restore = auto_resolve(accept)
  local captured = {}
  local real_on_hook = agy._on_hook
  agy._on_hook = function(req, respond)
    captured[#captured + 1] = req
    if req.toolCall then
      log(("  [%s] PreToolUse: %s"):format(phase, req.toolCall.name))
    end
    real_on_hook(req, respond)
  end

  local session = agy.start({ cwd = ws })
  log(("[%s] session up; hooks at %s/.agents/hooks.json"):format(phase, ws))

  local job = vim.fn.jobstart(
    { "agy", "--new-project", "-i", "Create a file named hello.txt containing exactly: hi there" },
    {
      cwd = ws,
      pty = true,
      width = 120,
      height = 40,
      env = { TERM = "xterm-256color" },
    }
  )
  if job <= 0 then
    log("FAIL: could not launch agy")
    os.exit(1)
  end

  -- Accept the first-run directory-trust prompt (agy shows it, then runs the
  -- initial `-i` prompt).
  vim.wait(9000)
  vim.fn.chansend(job, "\r")

  -- Accept phase: succeed as soon as the file appears. Reject phase: give agy
  -- ample time to attempt (and be blocked) before confirming the file is absent.
  if accept then
    vim.wait(90000, function()
      return vim.fn.filereadable(target) == 1
    end, 300)
  else
    vim.wait(60000, function()
      return #captured >= 3 -- a couple of hook round-trips = it tried and we blocked
    end, 300)
    vim.wait(4000)
  end

  agy._on_hook = real_on_hook
  restore()
  pcall(vim.fn.chansend, job, "\3")
  vim.wait(400)
  pcall(vim.fn.jobstop, job)
  session:stop()

  local saw_tool, saw_preinvocation, edit_args = false, false, nil
  for _, req in ipairs(captured) do
    if req.toolCall then
      saw_tool = true
      if req.toolCall.name ~= "run_command" then
        edit_args = req.toolCall.args
      end
    elseif req.invocationNum ~= nil then
      saw_preinvocation = true
    end
  end
  return {
    saw_tool = saw_tool,
    saw_preinvocation = saw_preinvocation,
    wrote = vim.fn.filereadable(target) == 1,
    args = edit_args,
  }
end

log("=== phase 1: REJECT the diff (expect no file) ===")
local rej = run_agy(false)
log("=== phase 2: ACCEPT the diff (expect the file written) ===")
local acc = run_agy(true)

-- Captured args must map onto our normalizer (not the raw-args fallback).
local normalized_ok = false
local edit_args = acc.args or rej.args
if edit_args then
  local edit = agy._normalize_edit("write_to_file", edit_args)
  normalized_ok = edit.path ~= "" and edit.path == (edit_args.TargetFile or edit_args.path)
  log(
    ("normalizer → path=%s kind=%s recovered=%s"):format(
      edit.path,
      edit.kind,
      tostring(normalized_ok)
    )
  )
end

log("")
log(
  ("reject: saw_tool=%s preinvocation=%s wrote=%s"):format(
    tostring(rej.saw_tool),
    tostring(rej.saw_preinvocation),
    tostring(rej.wrote)
  )
)
log(
  ("accept: saw_tool=%s preinvocation=%s wrote=%s"):format(
    tostring(acc.saw_tool),
    tostring(acc.saw_preinvocation),
    tostring(acc.wrote)
  )
)

if
  rej.saw_tool
  and not rej.wrote
  and acc.saw_tool
  and acc.wrote
  and acc.saw_preinvocation
  and normalized_ok
then
  log("PASS — interactive agy obeys harnt BOTH ways (reject blocks, accept writes)")
  os.exit(0)
end
log("FAIL")
os.exit(1)
