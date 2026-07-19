--- Append-only file tail.
---
--- Watches a file for appended bytes and delivers each complete newline-delimited
--- line to a callback — the read side of a "process writes JSON lines to a file,
--- we consume them" channel (e.g. an agent hook command appending its payload).
--- Dependency-light: a `vim.uv` timer that reads bytes past a tracked offset,
--- plus the shared line buffer. No daemon or socket server. Agent-agnostic.
--- (A timer rather than `fs_poll` — the latter only fires on a change relative to
--- a baseline it samples lazily, racing appends that land right after start.)

local stdio = require("harnt.transport.stdio")

local M = {}

--- A running tail. `stop` halts polling and releases the handle.
---@class harnt.filetail.Handle
---@field stop fun()
---@field drain fun() read any pending bytes now (also used internally by the poll)

---@class harnt.filetail.Opts
---@field interval? integer poll interval in ms (default 250)

--- Tail `path`, calling `on_line` for each complete line appended after the tail
--- starts. The file must already exist (create it empty before launching the
--- writer). Only bytes past the initial size are delivered.
---@param path string
---@param on_line fun(line: string)
---@param opts? harnt.filetail.Opts
---@return harnt.filetail.Handle
function M.tail(path, on_line, opts)
  opts = opts or {}
  local uv = vim.uv
  local timer = assert(uv.new_timer())
  local lb = stdio.line_buffer()

  -- Start from the current end so we only see new appends.
  local stat0 = uv.fs_stat(path)
  local offset = stat0 and stat0.size or 0

  local function drain()
    local fd = uv.fs_open(path, "r", 420)
    if not fd then
      return
    end
    local stat = uv.fs_fstat(fd)
    if stat and stat.size > offset then
      local data = uv.fs_read(fd, stat.size - offset, offset) or ""
      offset = stat.size
      for _, line in ipairs(lb:feed(data)) do
        if line ~= "" then
          on_line(line)
        end
      end
    end
    uv.fs_close(fd)
  end

  local interval = opts.interval or 250
  timer:start(interval, interval, function()
    -- Reading + on_line may touch the Neovim API; hop to the main loop.
    vim.schedule(drain)
  end)

  return {
    drain = function()
      vim.schedule(drain)
    end,
    stop = function()
      if not timer:is_closing() then
        timer:stop()
        timer:close()
      end
    end,
  }
end

return M
