--- harnt.nvim public API.
---
--- `require("harnt").setup{}` to configure, `register_provider{}` to add an
--- agent, and `dispatch()` behind the `:Harnt` command. Kept thin: the real work
--- lives in the services, event bus, registry, and runtime.

local M = {}

--- `:Harnt <sub> [args]` handlers. Grows as the frontend lands (open/new/stop/
--- diff-accept/…). Third parties and later milestones add entries here.
---@type table<string, fun(args: string[])>
M.subcommands = {
  --- `:Harnt open [provider]` — launch a provider (default: claude).
  open = function(args)
    require("harnt.manager").launch(args[1] or "claude")
  end,
  --- `:Harnt stop [provider]` — stop one provider, or all of them.
  stop = function(args)
    local manager = require("harnt.manager")
    if args[1] then
      manager.stop(args[1])
    else
      manager.stop_all()
    end
  end,
  health = function()
    vim.cmd("checkhealth harnt")
  end,
}

--- Configure harnt (see harnt.config) and register the built-in providers.
---@param opts? table
---@return harnt.Config
function M.setup(opts)
  local config = require("harnt.config").setup(opts)
  require("harnt.providers").register(require("harnt.providers.claude"))
  return config
end

--- Register an agent provider (see harnt.providers).
---@param provider harnt.Provider
function M.register_provider(provider)
  require("harnt.providers").register(provider)
end

--- Run a `:Harnt` subcommand. Unknown names notify rather than raise.
---@param name? string
---@param args? string[]
function M.dispatch(name, args)
  if not name or name == "" then
    vim.notify(
      "harnt: usage — :Harnt <" .. table.concat(M.subcommand_names(), "|") .. ">",
      vim.log.levels.INFO
    )
    return
  end
  local handler = M.subcommands[name]
  if not handler then
    vim.notify(("harnt: unknown subcommand %q"):format(name), vim.log.levels.ERROR)
    return
  end
  handler(args or {})
end

--- Sorted subcommand names (for completion + usage).
---@return string[]
function M.subcommand_names()
  local names = vim.tbl_keys(M.subcommands)
  table.sort(names)
  return names
end

return M
