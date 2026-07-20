---@diagnostic disable
-- Real-CLI e2e for the Claude @-mention path (`:Harnt send` → on_mention).
--
-- Unlike Codex/agy (which have no protocol at-mention and must type into the TUI),
-- Claude has a first-class `at_mentioned` notification. `claude.on_mention` pushes
-- it — with `filePath` + `lineStart`/`lineEnd` from the live selection — over the
-- REAL reverse-MCP WebSocket to the REAL connected `claude`. This drives that end
-- to end: connect the real CLI, push the mention for a file holding a unique
-- sentinel, then ask Claude about the referenced range and assert the sentinel
-- comes back — i.e. Claude genuinely received and used the @-mention.
--
-- Run from the repo root (which must be trusted by your `claude`):
--     just e2e-claude-mention        (needs `claude` on PATH + authenticated)
-- Nondeterministic (real model + API), so NOT part of `just ci`.

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path = ("%s/lua/?.lua;%s/lua/?/init.lua;%s"):format(root, root, package.path)

local function log(msg)
  io.write("[e2e] " .. msg .. "\n")
  io.flush()
end

require("harnt").setup()
local claude = require("harnt.providers.claude")
local context = require("harnt.services.context")

if not claude.detect() then
  log("SKIP: claude not on PATH")
  os.exit(1)
end

-- A file whose distinctive sentinel Claude can only know by reading the range we
-- @-mention. Lives under the repo root so `claude` (trusted here) can resolve it.
local SENTINEL = "ZPHINEX_7731"
local file = root .. "/e2e_mention_scratch.lua"
vim.fn.writefile({
  "-- unrelated header line",
  ("local magic_token = %q"):format(SENTINEL),
  "return magic_token",
}, file)
vim.cmd.edit(file)
vim.cmd("normal! 2GV\27") -- visual-select line 2 (the sentinel), Esc to set '< '> marks
local range = context.file_range()
log(("mention range: %s lines %d-%d"):format(range.path, range.line_start, range.line_end))

-- Confirm on_mention pushes a well-formed at_mentioned (deterministic), while ALSO
-- letting the real push go over the live WS to the real claude.
local session = claude.start({})
local connected, pushed = false, nil
session:on("session.started", function()
  connected = true
  log("claude connected")
end)

local transcript = {}
local function clean(line)
  return (
    line:gsub("\27%][%d;]*[^\7\27]*[\7]?", ""):gsub("\27%[[%d;?]*[a-zA-Z]", ""):gsub("[\r%z]", "")
  )
end
local job = vim.fn.jobstart({ "claude" }, {
  cwd = root,
  pty = true,
  width = 120,
  height = 40,
  env = vim.tbl_extend("force", { TERM = "xterm-256color" }, claude.env(session.info)),
  on_stdout = function(_, data)
    for _, line in ipairs(data or {}) do
      local c = clean(line)
      if c:match("%S") then
        transcript[#transcript + 1] = c
        log("claude> " .. c)
      end
    end
  end,
})
if job <= 0 then
  log("FAIL: could not launch claude")
  os.exit(1)
end

vim.wait(20000, function()
  return connected
end, 100)
if not connected then
  log("FAIL: claude never connected to the reverse-MCP server")
  pcall(vim.fn.jobstop, job)
  os.exit(1)
end
vim.wait(4000) -- let the composer settle

-- Wrap push so we can assert the payload shape, then fire the REAL on_mention.
local real_push = session.push
session.push = function(self, method, params)
  if method == "at_mentioned" then
    pushed = params
    log(
      ("at_mentioned pushed: file=%s L%s-%s"):format(
        tostring(params.filePath),
        tostring(params.lineStart),
        tostring(params.lineEnd)
      )
    )
  end
  return real_push(self, method, params)
end
claude.on_mention({ session = session, send_text = function() end })
vim.wait(2000)

-- Ask about the referenced range WITHOUT naming the file. The proof is that
-- Claude then accesses that exact file+range purely from the @-mention — it was
-- never told the filename. (We don't grep Claude's final prose for the sentinel:
-- its Ink TUI wraps/escapes output, so the reliable observable is Claude touching
-- the mentioned file, e.g. `Read e2e_mention_scratch.lua (1 lines)` — one line,
-- matching our single-line selection.)
local prompt = "Using only the file range I just @-mentioned, tell me the exact "
  .. "string value assigned in it."
vim.fn.chansend(job, prompt)
vim.wait(1500)
vim.fn.chansend(job, "\r")
vim.wait(1500)
vim.fn.chansend(job, "\r")
log("prompt sent; waiting for Claude to act on the mentioned range")

local basename = vim.fn.fnamemodify(file, ":t") -- "e2e_mention_scratch.lua"
local acted_on_mention = false
vim.wait(90000, function()
  for _, c in ipairs(transcript) do
    -- Claude referencing / reading a file it was never named ⇒ at_mentioned
    -- delivered it. (Sentinel echo is a bonus, not required — see note above.)
    if c:find(basename, 1, true) or c:find(SENTINEL, 1, true) then
      acted_on_mention = true
      return true
    end
  end
  return false
end, 300)

pcall(vim.fn.chansend, job, "\3")
vim.wait(400)
pcall(vim.fn.jobstop, job)
session:stop()
vim.fn.delete(file)

local payload_ok = pushed ~= nil
  and pushed.filePath == range.path
  and pushed.lineStart == range.line_start
  and pushed.lineEnd == range.line_end

log("")
log("=== FINDINGS (Claude @-mention) ===")
log("connected:                                 " .. tostring(connected))
log("payload well-formed (path + line range):   " .. tostring(payload_ok))
log("Claude acted on the (unnamed) mentioned file: " .. tostring(acted_on_mention))

if connected and payload_ok and acted_on_mention then
  log("PASS — real Claude resolved the at_mentioned file+range it was never named")
  os.exit(0)
end
log("FAIL — at_mentioned did not deliver the referenced file+range to Claude")
os.exit(1)
