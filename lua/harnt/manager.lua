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
---@field ctx_group? integer autocmd group pushing context to the agent

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

  -- PUSH-mode providers stream the selection as the cursor moves. This guard is a
  -- real either/or, not a silent gap: pull-mode providers (Codex, Antigravity)
  -- answer selection on demand instead and legitimately have no push hook. The
  -- contract's `validate()` guarantees every provider serves selection one way.
  if provider.push_selection then
    local push_selection = provider.push_selection
    local group = vim.api.nvim_create_augroup("harnt_ctx_" .. name, { clear = true })
    vim.api.nvim_create_autocmd({ "CursorHold", "ModeChanged" }, {
      group = group,
      callback = function()
        push_selection(session)
      end,
    })
    instance.ctx_group = group
  end

  -- Run the agent's own TUI. `cmd` may be static (Claude) or a function of the
  -- session (Codex needs the proxy's ws port in its `--remote` argument); `env`
  -- carries reverse-MCP discovery vars for providers that use them. An empty `cmd`
  -- means no external process (e.g. the Fake provider).
  local cmd = type(provider.cmd) == "function" and provider.cmd(session) or provider.cmd
  ---@cast cmd string[]
  if #cmd > 0 then
    local info = (session --[[@as { info: harnt.reverse_mcp.Info }]]).info
    local env = provider.env(info)
    local open = opts.open_terminal or terminal.open
    instance.terminal = open({
      cmd = cmd,
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
  if instance.ctx_group then
    pcall(vim.api.nvim_del_augroup_by_id, instance.ctx_group)
  end
  if instance.terminal then
    pcall(terminal.close, instance.terminal)
  end
  instance.session:stop()
end

--- Type `text` into a running provider's terminal and submit it (as if typed).
---@param name string
---@param text string
function M.send_text(name, text)
  local instance = instances[name]
  if not instance or not instance.terminal then
    return
  end
  local job = instance.terminal.job
  if not job or job <= 0 then
    return
  end
  vim.fn.chansend(job, text)
  -- Submit as a separate keystroke — many TUIs treat text+CR in one write as a
  -- pasted newline rather than Enter.
  vim.defer_fn(function()
    pcall(vim.fn.chansend, job, "\r")
  end, 300)
end

--- Submit a diff review. The generic layer only gathers the comments and hands
--- the provider primitives (reject / send_text / session); each provider decides
--- how to deliver the feedback in its native way. With no review-capable agent,
--- it's a plain reject.
---@param id integer
function M.review(id)
  local diff = require("harnt.services.diff")
  local reject = function()
    diff.reject(id)
  end

  -- Route to the agent that opened this diff (tagged via the diff's origin), so
  -- feedback reaches the right TUI when several agents run at once. Fall back to
  -- the sole running instance when the diff wasn't tagged.
  local origin = diff.origin(id)
  local target = (origin and instances[origin]) or nil
  if not target then
    local names = M.running()
    target = names[1] and instances[names[1]] or nil
  end
  local provider = target and registry.get(target.name) or nil

  -- Every provider implements `review` (it's required), so the only fallback is
  -- "no agent is running to hand this to" — then we just reject the diff.
  if not (target and provider) then
    reject()
    return
  end

  provider.review({
    comments = diff.comments(id),
    path = diff.target(id),
    reject = reject,
    send_text = function(text)
      M.send_text(target.name, text)
    end,
    session = target.session,
  })
end

--- Ask every running agent to @-mention the current file/selection (`:Harnt
--- send`; select first to send a range). The provider shapes + delivers it.
function M.send()
  for _, name in ipairs(M.running()) do
    local instance = instances[name]
    local provider = registry.get(name)
    -- `on_mention` is required, so no capability guard — just deliver. The provider
    -- picks its native shape: a protocol notification (Claude's `at_mentioned`) or
    -- typed prose (Codex/Antigravity type an `@path` into their TUI via send_text).
    if instance and provider then
      provider.on_mention({
        session = instance.session,
        send_text = function(text)
          M.send_text(name, text)
        end,
      })
    end
  end
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
