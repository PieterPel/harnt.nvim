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
  --- `:Harnt open [provider] [--prompt-file <path>]` — launch a provider (default:
  --- claude), optionally with the file's contents as its initial prompt.
  open = function(args)
    local name, prompt_file ---@type string?, string?
    local i = 1
    while i <= #args do
      if args[i] == "--prompt-file" then
        prompt_file = args[i + 1]
        if not prompt_file then
          vim.notify("harnt: --prompt-file needs a path", vim.log.levels.ERROR)
          return
        end
        i = i + 2
      else
        name = name or args[i]
        i = i + 1
      end
    end

    local prompt
    if prompt_file then
      local path = vim.fs.normalize(prompt_file)
      if vim.fn.filereadable(path) ~= 1 then
        vim.notify(("harnt: cannot read prompt file %q"):format(path), vim.log.levels.ERROR)
        return
      end
      prompt = table.concat(vim.fn.readfile(path), "\n")
    end
    require("harnt.manager").launch(name or "claude", { prompt = prompt })
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
  --- `:Harnt toggle [provider]` — show/hide (or launch) a provider's TUI.
  toggle = function(args)
    require("harnt.manager").toggle(args[1] or "claude")
  end,
  --- `:Harnt send` — send the current file/selection to running agents (@-mention).
  send = function()
    require("harnt.manager").send()
  end,
  --- `:Harnt review` — reject the current diff and send its comments as feedback.
  review = function()
    local diff = require("harnt.services.diff")
    local id = diff.current()
    if id then
      require("harnt.manager").review(id)
    else
      vim.notify("harnt: no diff to review", vim.log.levels.WARN)
    end
  end,
  --- `:Harnt accept` — accept the current diff.
  accept = function()
    local diff = require("harnt.services.diff")
    local id = diff.current()
    if id then
      diff.accept(id)
    else
      vim.notify("harnt: no diff to accept", vim.log.levels.WARN)
    end
  end,
  --- `:Harnt reject` — reject the current diff.
  reject = function()
    local diff = require("harnt.services.diff")
    local id = diff.current()
    if id then
      diff.reject(id)
    else
      vim.notify("harnt: no diff to reject", vim.log.levels.WARN)
    end
  end,
  --- `:Harnt changes` — pick a recorded agent change to view (read-only).
  changes = function()
    require("harnt.services.changes").pick()
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
  local registry = require("harnt.providers")
  registry.register(require("harnt.providers.claude"))
  registry.register(require("harnt.providers.codex"))
  registry.register(require("harnt.providers.antigravity"))
  registry.register(require("harnt.providers.opencode"))
  -- Route the diff review key to the manager (reject + send comments to agents).
  require("harnt.services.diff").set_review_handler(function(id)
    require("harnt.manager").review(id)
  end)
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

--- `:Harnt` completion: the subcommand, then provider names for the subcommands
--- that take one, and a file path after `open --prompt-file`.
---@param arglead string
---@param cmdline string
---@return string[]
function M.complete(arglead, cmdline)
  local words = vim.split(cmdline, "%s+", { trimempty = true })
  local done = #words - (arglead == "" and 0 or 1)
  local sub = words[2]

  local candidates ---@type string[]
  if done <= 1 then
    candidates = M.subcommand_names()
  elseif sub == "open" and words[done] == "--prompt-file" then
    return vim.fn.getcompletion(arglead, "file")
  elseif sub == "open" or sub == "toggle" or sub == "stop" then
    candidates = require("harnt.providers").list()
    if sub == "open" then
      candidates[#candidates + 1] = "--prompt-file"
    end
  else
    return {}
  end
  return vim.tbl_filter(function(candidate)
    return candidate:find(arglead, 1, true) == 1
  end, candidates)
end

--- A statusline fragment naming the running providers (empty when idle). Drop
--- into your statusline: `%{v:lua.require'harnt'.statusline()}`.
---@return string
function M.statusline()
  local running = require("harnt.manager").running()
  if #running == 0 then
    return ""
  end
  return "harnt:" .. table.concat(running, ",")
end

return M
