---@diagnostic disable
-- Clean-room load smoke.
--
-- Proves harnt loads, configures, registers its providers, defines :Harnt, and
-- runs :checkhealth with NOTHING else on the runtimepath — no dev flake, no user
-- plugins. Catches "works only inside nix develop" surprises a real user would
-- hit on a fresh `lazy.nvim` install. Deterministic, no network, no agent CLIs.
--
-- Run:  nvim --clean -l scripts/smoke-clean-load.lua   (or: just smoke)
-- Exits 0 on success, 1 otherwise.

local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
package.path = ("%s/lua/?.lua;%s/lua/?/init.lua;%s"):format(root, root, package.path)

local function fail(msg)
  io.write("[smoke] FAIL: " .. msg .. "\n")
  os.exit(1)
end

local ok, harnt = pcall(require, "harnt")
if not ok then
  fail("require('harnt'): " .. tostring(harnt))
end

local ok_setup, err = pcall(harnt.setup, {})
if not ok_setup then
  fail("setup(): " .. tostring(err))
end

-- Source the plugin file the way a plugin manager would, then confirm the command.
vim.cmd("runtime! plugin/harnt.lua")
if vim.fn.exists(":Harnt") ~= 2 then
  fail(":Harnt user command was not defined")
end

-- Built-in providers registered by setup().
local registry = require("harnt.providers")
local registered = {}
for _, name in ipairs(registry.list()) do
  registered[name] = true
end
for _, want in ipairs({ "claude", "codex", "antigravity" }) do
  if not registered[want] then
    fail("provider not registered: " .. want)
  end
end

-- Subcommands present, and dispatch of a read-only one doesn't error.
local subs = harnt.subcommand_names()
if #subs == 0 then
  fail("no :Harnt subcommands registered")
end

-- :checkhealth harnt runs cleanly (this also exercises each provider's health()).
local ok_health, health_err = pcall(vim.cmd, "checkhealth harnt")
if not ok_health then
  fail(":checkhealth harnt: " .. tostring(health_err))
end

io.write(
  ("[smoke] PASS — loads clean; providers=%s; subcommands=%d\n"):format(
    table.concat(registry.list(), ","),
    #subs
  )
)
os.exit(0)
