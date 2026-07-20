---@diagnostic disable
-- Init for `just try`: a clean Neovim with ONLY harnt loaded, plus convenience
-- keymaps and an on-launch help popup — so you can kick the tyres without
-- touching your real config. Not used at runtime; purely a manual harness.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":h:h") -- .../scripts/try-init.lua -> repo root

vim.g.mapleader = " "
vim.o.number = true
vim.o.termguicolors = true

vim.opt.runtimepath:prepend(root)
vim.cmd("runtime plugin/harnt.lua")
require("harnt").setup()

local map = vim.keymap.set
map("n", "<leader>ho", "<cmd>Harnt open claude<cr>", { desc = "harnt: open claude" })
map("n", "<leader>ht", "<cmd>Harnt toggle claude<cr>", { desc = "harnt: toggle terminal" })
map("n", "<leader>hs", "<cmd>Harnt send<cr>", { desc = "harnt: send file" })
map("x", "<leader>hs", "<cmd>Harnt send<cr>", { desc = "harnt: send selection" })
map("n", "<leader>hq", "<cmd>Harnt stop<cr>", { desc = "harnt: stop" })
map("n", "<leader>h?", "<cmd>checkhealth harnt<cr>", { desc = "harnt: checkhealth" })

local help = table.concat({
  "  harnt · try mode  (leader = <Space>)",
  "",
  "  <leader>ho   open claude          (or :Harnt open claude)",
  "  <leader>ht   toggle its terminal",
  "  <leader>hs   send file/selection to claude  (visual or normal)",
  "  <leader>a/r  accept / reject a proposed diff",
  "  <leader>hq   stop      <leader>h?  checkhealth",
}, "\n")

vim.schedule(function()
  vim.notify(help, vim.log.levels.INFO, { title = "harnt" })
end)
