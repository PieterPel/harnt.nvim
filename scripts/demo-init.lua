---@diagnostic disable
-- Init for `just demo`: a clean Neovim with ONLY harnt loaded, dropped into a
-- fresh temp project seeded with a small buggy file — a tidy stage for recording
-- the README demo (Claude/Codex proposes a fix → you accept the diff in nvim →
-- switch agents, same keys). Not used at runtime.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":h:h")

vim.g.mapleader = " "
vim.o.number = true
vim.o.termguicolors = true
vim.o.swapfile = false

vim.opt.runtimepath:prepend(root)
vim.cmd("runtime plugin/harnt.lua")
require("harnt").setup()

-- Seed a clean demo project so the recording isn't cluttered by a real repo.
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
vim.fn.system({ "git", "-C", dir, "init", "-q" })
local sample = dir .. "/fizzbuzz.lua"
vim.fn.writefile({
  "-- Prints 1..n with Fizz/Buzz. There's an off-by-one bug — ask the agent.",
  "local function fizzbuzz(n)",
  "  for i = 1, n do",
  "    if i % 3 == 0 and i % 5 == 0 then",
  '      print("FizzBuzz")',
  '    elseif i % 3 == 0 then print("Fizz")',
  '    elseif i % 5 == 0 then print("Buzz")',
  "    else print(i) end",
  "  end",
  "end",
  "",
  "fizzbuzz(15)",
}, sample)
vim.cmd.cd(dir)
vim.cmd.edit(sample)

local map = vim.keymap.set
map("n", "<leader>ac", "<cmd>Harnt open claude<cr>", { desc = "harnt: Claude" })
map("n", "<leader>ax", "<cmd>Harnt open codex<cr>", { desc = "harnt: Codex" })
map("n", "<leader>ag", "<cmd>Harnt open antigravity<cr>", { desc = "harnt: Antigravity" })
map("n", "<leader>at", "<cmd>Harnt toggle<cr>", { desc = "harnt: toggle terminal" })
map({ "n", "x" }, "<leader>as", "<cmd>Harnt send<cr>", { desc = "harnt: send file/selection" })
map("n", "<leader>aC", "<cmd>Harnt changes<cr>", { desc = "harnt: change-log" })

local help = table.concat({
  "  harnt · demo mode  (leader = <Space>)",
  "",
  "  <leader>ac / ax / ag   open Claude / Codex / Antigravity",
  "  <leader>as             send this file (or selection) to the agent",
  "  F9 / F10               accept / reject a proposed diff",
  "  <leader>c  / <leader>R comment on a line / submit review",
  "  <leader>aC             browse the change-log",
  "",
  "  Try: open an agent, ask it to fix the off-by-one, accept the diff.",
}, "\n")

vim.schedule(function()
  vim.notify(help, vim.log.levels.INFO, { title = "harnt demo" })
end)
