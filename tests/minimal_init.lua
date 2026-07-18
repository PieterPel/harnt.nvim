-- busted helper (see .busted `helper`): make the plugin requireable and give
-- tests the real Neovim API. Runs once, before the suite, under nlua.

local cwd = vim.fn.getcwd()

-- Put lua/ on package.path so `require("harnt.…")` resolves without installing.
package.path = ("%s/lua/?.lua;%s/lua/?/init.lua;%s"):format(cwd, cwd, package.path)

-- Expose the repo on the runtimepath, matching how Neovim loads the plugin.
vim.opt.runtimepath:prepend(cwd)
