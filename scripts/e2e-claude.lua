---@diagnostic disable
-- Real-CLI end-to-end smoke against Claude Code.
--
-- Drives the actual `claude` binary through harnt's reverse-MCP server: connect,
-- MCP handshake, prompt an edit, let Claude propose it via openDiff, auto-accept,
-- and verify FILE_SAVED + the file changing on disk.
--
-- Run from the repo root (which must be trusted by your `claude`):
--     nvim -l scripts/e2e-claude.lua        (or: just e2e-claude)
--
-- Requires `claude` on PATH and authenticated. It is nondeterministic (real
-- model + API) and makes real API calls, so it is NOT part of `just ci`.
-- Exits 0 on success, 1 otherwise.

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path = ("%s/lua/?.lua;%s/lua/?/init.lua;%s"):format(root, root, package.path)

local function log(msg)
  io.write("[e2e] " .. msg .. "\n")
  io.flush()
end

-- Log every MCP method the real Claude CLI sends.
local mcp = require("harnt.transport.mcp")
local real_server = mcp.server
local saw_open_diff = false
mcp.server = function(opts)
  local server = real_server(opts)
  local real_feed = server.feed
  server.feed = function(self, payload)
    local ok, msg = pcall(vim.json.decode, payload)
    if ok and type(msg) == "table" and msg.method then
      local name = msg.method == "tools/call" and msg.params and msg.params.name
      log("MCP <- " .. msg.method .. (name and (" " .. name) or ""))
      if name == "openDiff" then
        saw_open_diff = true
      end
    end
    return real_feed(self, payload)
  end
  return server
end

require("harnt").setup()
local claude = require("harnt.providers.claude")
local diff = require("harnt.services.diff")

local file = root .. "/e2e_scratch.txt"
vim.fn.writefile({ "line one", "line two" }, file)

local session = claude.start({})
local connected = false
session:on("session.started", function()
  connected = true
  log("claude connected")
end)

local accepted = false
local timer = assert(vim.uv.new_timer())
timer:start(
  400,
  400,
  vim.schedule_wrap(function()
    if not accepted and diff.open_count() > 0 then
      local id = diff.current()
      if id then
        log("auto-accepting diff " .. id)
        accepted = true
        diff.accept(id)
      end
    end
  end)
)

local job = vim.fn.jobstart(
  { "claude" },
  { term = true, env = claude.env(session.info), cwd = root }
)

vim.wait(15000, function()
  return connected
end, 100)
vim.wait(5000, function()
  return false
end, 100)

-- Type the prompt, then send Enter separately (Ink treats text+CR as a paste).
vim.fn.chansend(job, "Edit e2e_scratch.txt and add a third line that says: hello from harnt")
vim.wait(1500, function()
  return false
end, 100)
vim.fn.chansend(job, "\r")
vim.wait(1500, function()
  return false
end, 100)
vim.fn.chansend(job, "\r")
log("prompt sent")

vim.wait(90000, function()
  return accepted
end, 200)
vim.wait(2500, function()
  return false
end, 100)

local content = vim.fn.readfile(file)
local applied = vim.tbl_contains(content, "hello from harnt")
log(
  "saw_openDiff="
    .. tostring(saw_open_diff)
    .. " accepted="
    .. tostring(accepted)
    .. " applied="
    .. tostring(applied)
)
log("file: [" .. table.concat(content, " | ") .. "]")

pcall(vim.fn.jobstop, job)
timer:stop()
timer:close()
session:stop()
vim.fn.delete(file)

local passed = saw_open_diff and accepted and applied
log(passed and "PASS" or "FAIL")
vim.cmd(passed and "qall!" or "cquit! 1")
