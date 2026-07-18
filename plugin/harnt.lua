-- harnt.nvim plugin entry: define the :Harnt command. Loaded once at startup.

if vim.g.loaded_harnt then
  return
end
vim.g.loaded_harnt = true

vim.api.nvim_create_user_command("Harnt", function(cmd)
  local name = cmd.fargs[1]
  local args = vim.list_slice(cmd.fargs, 2)
  require("harnt").dispatch(name, args)
end, {
  nargs = "*",
  desc = "harnt.nvim",
  complete = function(arglead)
    return vim.tbl_filter(function(sub)
      return sub:find(arglead, 1, true) == 1
    end, require("harnt").subcommand_names())
  end,
})
