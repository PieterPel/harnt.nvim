---@diagnostic disable
-- Real-CLI e2e SPIKE for the Codex @-mention path (`:Harnt send` → on_mention).
--
-- This is the verification we owed: `on_mention` for Codex types an `@path`
-- reference into the native `codex --remote` TUI via `send_text`. Codex has no
-- protocol at-mention (unlike Claude's `at_mentioned`), so typing is the only
-- lever — but `@` in the codex composer usually opens an INTERACTIVE file picker,
-- so a naive `chansend("@path")` may be hijacked rather than landing as a clean
-- mention. And a mention should populate the composer as context WITHOUT
-- submitting (submitting fires a bare "@path" message), whereas manager.send_text
-- auto-submits. This spike drives the real TUI, exercises the REAL
-- `codex.on_mention`, and REPORTS what actually happens to the composer so we can
-- decide the right delivery shape. It is deliberately observational.
--
-- Run from a trusted repo root:  just e2e-codex-mention   (needs `codex` authed).
-- Nondeterministic + real binary, so NOT part of `just ci`.

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path = ("%s/lua/?.lua;%s/lua/?/init.lua;%s"):format(root, root, package.path)

local function log(msg)
  io.write("[e2e] " .. msg .. "\n")
  io.flush()
end

local codex = require("harnt.providers.codex")
local context = require("harnt.services.context")

if not codex.detect() then
  log("SKIP: codex not on PATH")
  os.exit(1)
end

-- A real file with a distinctive path, and a visual selection over lines 1–2 so
-- on_mention has a range to encode.
local ws = vim.fn.tempname()
vim.fn.mkdir(ws, "p")
local file = ws .. "/widget_config.lua"
vim.fn.writefile({ "local sentinel = 42", "local other = 7", "return sentinel + other" }, file)
vim.cmd.edit(file)
vim.cmd("normal! ggVj\27") -- visual-select lines 1-2, then Esc to set the '< '> marks
local sel = context.selection()
log(
  ("selection: %s"):format(sel and ("lines %d-%d"):format(sel.start.row, sel.finish.row) or "nil")
)

-- Strip terminal escapes so the log is readable and matchable.
local function clean(line)
  return (
    line:gsub("\27%][%d;]*[^\7\27]*[\7]?", ""):gsub("\27%[[%d;?]*[a-zA-Z]", ""):gsub("[\r%z]", "")
  )
end

local composer_ready, trust_prompt = false, false
local transcript = {}
local job = vim.fn.jobstart({ "codex" }, {
  cwd = ws,
  pty = true,
  width = 120,
  height = 40,
  env = { TERM = "xterm-256color" },
  on_stdout = function(_, data)
    for _, line in ipairs(data or {}) do
      local c = clean(line)
      if c:match("%S") then
        transcript[#transcript + 1] = c
        log("codex> " .. c)
      end
      if c:find("Yes, continue") or c:find("Trusting the directory") then
        trust_prompt = true
      end
      if c:find("default ·") or c:find("Find and fix a bug") or c:find("Ask Codex") then
        composer_ready = true
      end
    end
  end,
})
if job <= 0 then
  log("FAIL: could not launch codex")
  os.exit(1)
end

-- Clear the first-run directory-trust prompt (default = Yes, continue).
vim.wait(12000, function()
  return trust_prompt or composer_ready
end, 100)
if trust_prompt and not composer_ready then
  log("accepting directory-trust prompt")
  vim.fn.chansend(job, "\r")
end
vim.wait(15000, function()
  return composer_ready
end, 100)
vim.wait(1500)
log("composer ready=" .. tostring(composer_ready))

-- Snapshot how much transcript we've seen, so we can inspect ONLY what the
-- mention produces.
local before = #transcript

-- Exercise the REAL provider path. on_mention builds the "@path (lines a-b)"
-- string and hands it to send_text; we deliver it char-by-char into the PTY
-- (mirroring how a real terminal receives typing) and DO NOT submit — a mention
-- should populate the composer, not fire a message.
local mention_text
codex.on_mention({
  session = { info = {} },
  send_text = function(text)
    mention_text = text
    log("on_mention → send_text: [" .. text .. "]")
    for ch in text:gmatch(".") do
      vim.fn.chansend(job, ch)
      vim.wait(60)
    end
  end,
})
vim.wait(3000) -- let the composer / any picker react

local after = {}
for i = before + 1, #transcript do
  after[#after + 1] = transcript[i]
end
local joined = table.concat(after, "\n")

-- Heuristics: did the path land in the composer, and did `@` open a file picker?
local rel = vim.fn.fnamemodify(file, ":t") -- "widget_config.lua"
local path_visible = joined:find(rel, 1, true) ~= nil
local picker_open = joined:lower():find("search")
  or joined:find("↑↓")
  or joined:find("to select")

pcall(vim.fn.chansend, job, "\3")
vim.wait(500)
pcall(vim.fn.jobstop, job)

log("")
log("=== FINDINGS (Codex @-mention) ===")
log("mention string:     " .. tostring(mention_text))
log("path visible after: " .. tostring(path_visible))
log("picker UI detected: " .. tostring(picker_open ~= nil and picker_open ~= false))
log("(inspect the codex> lines above for the composer's actual state)")

-- A clean landing means the composer shows the file (either echoed inline or
-- surfaced by the picker). Neither = the `@`-into-TUI mechanism does not work as
-- assumed and on_mention for codex needs a different shape.
if path_visible or picker_open then
  log("PASS — the mention reached the codex composer (see mechanism notes above)")
  os.exit(0)
end
log("FAIL — mention text did not land in the composer; `@`-typing may be hijacked")
os.exit(1)
