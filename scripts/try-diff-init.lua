---@diagnostic disable
-- Init for `just try-diff [style]`: a clean Neovim with ONLY harnt loaded,
-- seeded with an already-open diff you can review immediately — no real agent
-- CLI, no auth. Compares the built-in presenters: `just try-diff` (default,
-- side-by-side split) vs `just try-diff inline` (the VSCode-style overlay).
-- Not used at runtime; purely a manual harness.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":h:h")

vim.g.mapleader = " "
vim.o.number = true
vim.o.termguicolors = true

vim.opt.runtimepath:prepend(root)
vim.cmd("runtime plugin/harnt.lua")

local style = vim.env.HARNT_DIFF_STYLE or "split"
require("harnt").setup({ diff = { style = style } })

-- One changed line, one removed line, one added line — enough to see every
-- overlay kind (line-change highlight, removed-line virt_lines, pure add) at
-- once, in both presenters.
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local path = dir .. "/sample.lua"
local original = {
  "local function greet(name)",
  "  print('hello ' .. name)",
  "  print('goodbye')",
  "end",
  "",
  "greet('world')",
}
local proposed = {
  "local function greet(name)",
  "  print('hi ' .. name) -- changed",
  "end",
  "",
  "greet('world')",
  "greet('harnt')",
}
vim.fn.writefile(original, path)
vim.cmd.edit(path)

vim.schedule(function()
  require("harnt.services.diff").open({ path = path, proposed = proposed }, function(result)
    vim.notify(
      ("harnt: diff %s"):format(result.accepted and "accepted" or "rejected"),
      vim.log.levels.INFO
    )
  end)
  vim.notify(
    table.concat({
      ("  harnt · try-diff  (style = %s)"):format(style),
      "",
      "  <leader>a   accept       <leader>r   reject",
      "  <leader>c   comment      <leader>R   review",
      "",
      "  switch style:  just try-diff inline   (or split)",
    }, "\n"),
    vim.log.levels.INFO,
    { title = "harnt" }
  )
end)
