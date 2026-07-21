--- Terminal split management (pluggable opener).
---
--- For Shape A providers (Claude, Gemini, …) the agent keeps its own TUI — we
--- just run it in a terminal split with the discovery env vars injected, so it
--- connects back to our reverse-MCP server. We render nothing chat-like.
---
--- The opener is a seam (like the diff presenter / approvals chooser): if
--- folke/snacks.nvim is installed we use `Snacks.terminal` (toggle, float, reuse);
--- otherwise a tiny built-in split. Neither is a hard dependency (bet #4).

local M = {}

---@class harnt.terminal.Opts
---@field cmd string|string[] command to run
---@field env? table<string, string> extra environment variables
---@field cwd? string working directory
---@field split? string window command for the built-in opener (default "botright vsplit")
---@field on_exit? fun(code: integer) called when the process exits

---@class harnt.terminal.Handle
---@field buf integer terminal buffer
---@field win integer window it opened in
---@field job integer job id
---@field package _snacks? any the snacks.win, when the snacks opener is used

--- open/close a terminal. Implementations: `builtin` and (optional) snacks.
---@class harnt.terminal.Opener
---@field open fun(opts: harnt.terminal.Opts): harnt.terminal.Handle
---@field close fun(handle: harnt.terminal.Handle)

--- Minimal built-in opener: a plain terminal in a split via jobstart.
---@type harnt.terminal.Opener
local builtin = {
  open = function(opts)
    vim.cmd(opts.split or "botright vsplit")
    local win = vim.api.nvim_get_current_win()
    local buf = vim.api.nvim_create_buf(false, false)
    vim.api.nvim_win_set_buf(win, buf)

    local on_exit = opts.on_exit
    -- jobstart rejects an empty Lua table for `env` (it serializes to a vim list,
    -- not a dict → E475). Pass nil when there are no vars to inject.
    local env = (opts.env and next(opts.env) ~= nil) and opts.env or nil
    local job = vim.fn.jobstart(opts.cmd, {
      term = true,
      env = env,
      cwd = opts.cwd,
      on_exit = on_exit and function(_id, code)
        on_exit(code)
      end or nil,
    })
    vim.cmd("startinsert") -- drop the user straight into the agent's TUI
    return { buf = buf, win = win, job = job }
  end,

  close = function(handle)
    if handle.job and handle.job > 0 then
      pcall(vim.fn.jobstop, handle.job)
    end
    if handle.buf and vim.api.nvim_buf_is_valid(handle.buf) then
      pcall(vim.api.nvim_buf_delete, handle.buf, { force = true })
    end
  end,
}

--- Build a snacks-backed opener, or nil when snacks isn't available.
---@return harnt.terminal.Opener?
local function snacks_opener()
  local ok, snacks = pcall(require, "snacks")
  if not ok or not snacks.terminal then
    return nil
  end
  return {
    open = function(opts)
      local swin = snacks.terminal.open(opts.cmd, {
        env = opts.env,
        cwd = opts.cwd,
        interactive = true,
        win = { position = "right" },
      })
      if opts.on_exit then
        vim.api.nvim_create_autocmd("TermClose", {
          buffer = swin.buf,
          once = true,
          callback = function()
            local ev = vim.v.event
            opts.on_exit(type(ev) == "table" and ev.status or 0)
          end,
        })
      end
      return {
        buf = swin.buf,
        win = swin.win,
        job = vim.b[swin.buf].terminal_job_id or 0,
        _snacks = swin,
      }
    end,
    close = function(handle)
      if handle._snacks then
        pcall(function()
          handle._snacks:close()
        end)
      elseif handle.buf and vim.api.nvim_buf_is_valid(handle.buf) then
        pcall(vim.api.nvim_buf_delete, handle.buf, { force = true })
      end
    end,
  }
end

--- The built-in opener, exposed so users can force it.
M.builtin = builtin

---@type harnt.terminal.Opener
local active = snacks_opener() or builtin

--- Override the opener (tests, or force builtin/snacks). nil re-runs autodetect.
---@param opener harnt.terminal.Opener?
function M.set_opener(opener)
  active = opener or snacks_opener() or builtin
end

--- Open `opts.cmd` in a terminal via the active opener.
---@param opts harnt.terminal.Opts
---@return harnt.terminal.Handle
function M.open(opts)
  return active.open(opts)
end

--- Close a terminal handle.
---@param handle harnt.terminal.Handle
function M.close(handle)
  active.close(handle)
end

return M
