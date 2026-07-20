---@diagnostic disable
-- Real-CLI e2e SPIKE for the Antigravity (`agy`) @-mention path
-- (`:Harnt send` → on_mention).
--
-- Same open question as the Codex spike: `on_mention` for agy types an `@path`
-- reference into the native `agy` TUI via `send_text`. agy has no protocol
-- at-mention, so typing is the only lever — but `@` in the agy composer typically
-- opens an interactive file picker, so `chansend("@path")` may be hijacked. And a
-- mention should populate the composer WITHOUT submitting. This spike drives the
-- real interactive TUI (the exact way the manager runs it), exercises the REAL
-- `agy.on_mention`, and REPORTS what actually lands in the composer.
--
-- Run from a trusted repo root:  just e2e-agy-mention   (needs `agy` authed).
-- Nondeterministic + real binary, so NOT part of `just ci`.

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path = ("%s/lua/?.lua;%s/lua/?/init.lua;%s"):format(root, root, package.path)

local function log(msg)
  io.write("[e2e] " .. msg .. "\n")
  io.flush()
end

local agy = require("harnt.providers.antigravity")
local context = require("harnt.services.context")

if not agy.detect() then
  log("SKIP: agy not on PATH")
  os.exit(1)
end

-- A real file + a visual selection over lines 1–2, so on_mention has a range.
local ws = vim.fn.tempname()
vim.fn.mkdir(ws, "p")
vim.fn.system({ "git", "-C", ws, "init", "-q" })
local file = ws .. "/widget_config.lua"
vim.fn.writefile({ "local sentinel = 42", "local other = 7", "return sentinel + other" }, file)
vim.cmd.edit(file)
vim.cmd("normal! ggVj\27") -- visual-select lines 1-2, then Esc to set the '< '> marks
local sel = context.selection()
log(
  ("selection: %s"):format(sel and ("lines %d-%d"):format(sel.start.row, sel.finish.row) or "nil")
)

local function clean(line)
  return (
    line:gsub("\27%][%d;]*[^\7\27]*[\7]?", ""):gsub("\27%[[%d;?]*[a-zA-Z]", ""):gsub("[\r%z]", "")
  )
end

local transcript = {}
local job = vim.fn.jobstart({ "agy", "--new-project" }, {
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
        log("agy> " .. c)
      end
    end
  end,
})
if job <= 0 then
  log("FAIL: could not launch agy")
  os.exit(1)
end

-- Give agy time to boot; accept a first-run trust/continue prompt (default Enter),
-- then let the composer settle. agy's composer markers are less predictable than
-- codex's, so we time-box rather than string-match the ready state.
vim.wait(9000)
vim.fn.chansend(job, "\r")
vim.wait(4000)

local before = #transcript

-- Exercise the REAL provider path (agy.on_mention → send_text), delivered
-- char-by-char into the PTY, no submit.
local mention_text
agy.on_mention({
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
vim.wait(3000)

local after = {}
for i = before + 1, #transcript do
  after[#after + 1] = transcript[i]
end
local joined = table.concat(after, "\n")

local rel = vim.fn.fnamemodify(file, ":t") -- "widget_config.lua"
local path_visible = joined:find(rel, 1, true) ~= nil
local picker_open = joined:lower():find("search")
  or joined:find("↑↓")
  or joined:find("to select")

pcall(vim.fn.chansend, job, "\3")
vim.wait(500)
pcall(vim.fn.jobstop, job)

log("")
log("=== FINDINGS (agy @-mention) ===")
log("mention string:     " .. tostring(mention_text))
log("path visible after: " .. tostring(path_visible))
log("picker UI detected: " .. tostring(picker_open ~= nil and picker_open ~= false))
log("(inspect the agy> lines above for the composer's actual state)")

if path_visible or picker_open then
  log("PASS — the mention reached the agy composer (see mechanism notes above)")
  os.exit(0)
end
log("FAIL — mention text did not land in the composer; `@`-typing may be hijacked")
os.exit(1)
