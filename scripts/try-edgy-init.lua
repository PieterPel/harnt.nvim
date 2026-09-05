---@diagnostic disable
-- Init for `just try-edgy`: a clean Neovim with harnt + snacks.nvim +
-- edgy.nvim, demonstrating the real docking flow from README.md's "Docking
-- the diff next to the agent" section — a real snacks-backed terminal and a
-- `docked` diff, both managed by edgy, no real agent CLI needed. Needs the
-- dev shell (`nix develop`), which exports $HARNT_SNACKS_NVIM/
-- $HARNT_EDGY_NVIM (see flake/devshells.nix — neither is ever a runtime
-- dependency of harnt itself). Not used at runtime; purely a manual harness.

local script = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(script, ":h:h")

local snacks_rtp = vim.env.HARNT_SNACKS_NVIM
local edgy_rtp = vim.env.HARNT_EDGY_NVIM
if not (snacks_rtp and edgy_rtp) then
  vim.notify(
    "just try-edgy needs the dev shell for snacks.nvim/edgy.nvim — run it via `nix develop -c just try-edgy`",
    vim.log.levels.ERROR
  )
  vim.cmd("cquit 1")
end

vim.g.mapleader = " "
vim.o.number = true
vim.o.termguicolors = true
vim.opt.laststatus = 3 -- edgy: edgebars only fully collapse with the global statusline
vim.opt.splitkeep = "screen" -- edgy's own recommended option; avoids the main split jumping

vim.opt.runtimepath:prepend({ root, snacks_rtp, edgy_rtp })
vim.cmd("runtime plugin/harnt.lua")

-- The exact snippet from README.md's "Docking the diff next to the agent"
-- section — both entries for the terminal, since which filetype it actually
-- gets depends on whether snacks is on the runtimepath (it is, here).
require("edgy").setup({
  right = {
    { ft = "harnt_terminal", title = "Agent" },
    { ft = "snacks_terminal", title = "Agent" },
    { ft = "harnt_diff", title = "Diff" },
  },
})
require("harnt").setup({ diff = { style = "docked" } })

-- A real terminal — harnt autodetects snacks now that it's on the
-- runtimepath — with no real agent CLI, just a shell to dock.
require("harnt.terminal").open({ cmd = { vim.o.shell } })

-- A real file + a real diff against it, so there's something to dock in the
-- other edgy view.
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local path = dir .. "/sample.lua"
vim.fn.writefile({
  "local function greet(name)",
  "  print('hello ' .. name)",
  "end",
}, path)
vim.cmd.edit(path)

vim.schedule(function()
  require("harnt.services.diff").open({
    path = path,
    proposed = {
      "local function greet(name)",
      "  print('hi ' .. name) -- changed",
      "end",
    },
  }, function(result)
    vim.notify(("harnt: diff %s"):format(result.accepted and "accepted" or "rejected"))
  end)
  vim.notify(
    table.concat({
      "  harnt · try-edgy — agent terminal + diff, both docked by edgy.nvim",
      "",
      "  <leader>a   accept       <leader>r   reject",
      "  ]w / [w     next/prev open edgy window     q   close it",
    }, "\n"),
    vim.log.levels.INFO,
    { title = "harnt" }
  )
end)
