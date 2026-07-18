--- Session manager: launch / track / stop / toggle provider sessions.
---
--- Ties a provider's session to its frontend. For a Shape A provider (a `cmd`),
--- that means spawning the agent's own TUI in a terminal split with the session's
--- discovery env injected, so the CLI connects back to our reverse-MCP server.
--- When the process exits, the session is torn down (server closed, lockfile
--- removed).

local registry = require("harnt.providers")
local terminal = require("harnt.terminal")

local M = {}

---@class harnt.manager.Instance
---@field name string
---@field session harnt.Session
---@field terminal? harnt.terminal.Handle

---@type table<string, harnt.manager.Instance?>
local instances = {}

---@class harnt.manager.LaunchOpts
---@field ctx? harnt.SessionContext
---@field open_terminal? fun(opts: harnt.terminal.Opts): harnt.terminal.Handle injectable for tests

--- Launch a provider by name. Idempotent: a second call returns the running
--- instance. Returns nil (after a notification) if the provider is unknown or
--- unavailable.
---@param name string
---@param opts? harnt.manager.LaunchOpts
---@return harnt.manager.Instance?
function M.launch(name, opts)
  opts = opts or {}
  local existing = instances[name]
  if existing then
    return existing
  end

  local provider = registry.get(name)
  if not provider then
    vim.notify(("harnt: unknown provider %q"):format(name), vim.log.levels.ERROR)
    return nil
  end
  if not provider.detect() then
    vim.notify(
      ("harnt: %q is not available — is the CLI installed and authenticated?"):format(name),
      vim.log.levels.ERROR
    )
    return nil
  end

  local session = provider.start(opts.ctx or {})
  ---@type harnt.manager.Instance
  local instance = { name = name, session = session }
  instances[name] = instance

  -- Shape A: run the agent's own TUI with the discovery env.
  if provider.cmd then
    ---@cast session harnt.reverse_mcp.Session
    local env = provider.env and provider.env(session.info) or nil
    local open = opts.open_terminal or terminal.open
    instance.terminal = open({
      cmd = provider.cmd,
      env = env,
      on_exit = function()
        M.stop(name)
      end,
    })
  end

  return instance
end

--- Stop a running provider: close its terminal, stop its session.
---@param name string
function M.stop(name)
  local instance = instances[name]
  if not instance then
    return
  end
  instances[name] = nil
  if instance.terminal then
    pcall(terminal.close, instance.terminal)
  end
  instance.session:stop()
end

--- Stop every running provider.
function M.stop_all()
  for _, name in ipairs(vim.tbl_keys(instances)) do
    M.stop(name)
  end
end

--- Toggle a provider's terminal window: launch it if not running, hide it if its
--- window is visible, or re-show its buffer if it's hidden.
---@param name string
function M.toggle(name)
  local instance = instances[name]
  if not instance then
    M.launch(name)
    return
  end

  local buf = instance.terminal and instance.terminal.buf
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local windows = vim.fn.win_findbuf(buf)
  if #windows > 0 then
    for _, win in ipairs(windows) do
      pcall(vim.api.nvim_win_close, win, false)
    end
  else
    vim.cmd("botright vsplit")
    vim.api.nvim_win_set_buf(0, buf)
    vim.cmd("startinsert")
  end
end

--- The running instance for `name`, if any.
---@param name string
---@return harnt.manager.Instance?
function M.get(name)
  return instances[name]
end

--- Names of running instances, sorted.
---@return string[]
function M.running()
  local names = vim.tbl_keys(instances)
  table.sort(names)
  return names
end

return M
