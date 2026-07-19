--- Child-process JSON-lines transport.
---
--- A generic primitive: spawn a subprocess, read its stdout as newline-delimited
--- JSON, decode each line to a table, and deliver it; `send` encodes a value and
--- newline-frames it onto stdin. Knows nothing about any agent — an `app-server`,
--- an LSP-ish helper, any newline-delimited-JSON child speaks this.
---
--- The line framing is a pure function (`line_buffer`) so it's unit-testable
--- without a process; `spawn` wires it to a real `vim.uv` child.

local M = {}

--- A pure newline framer: feed it arbitrary byte chunks, get back complete lines
--- (trailing CR stripped). Partial trailing data is retained until completed.
---@class harnt.stdio.LineBuffer
---@field feed fun(self: harnt.stdio.LineBuffer, chunk: string): string[]

--- Create a line buffer.
---@return harnt.stdio.LineBuffer
function M.line_buffer()
  local buf = ""
  return {
    feed = function(_self, chunk)
      buf = buf .. chunk
      local lines = {}
      while true do
        local nl = buf:find("\n", 1, true)
        if not nl then
          break
        end
        local line = buf:sub(1, nl - 1)
        buf = buf:sub(nl + 1)
        if line:sub(-1) == "\r" then
          line = line:sub(1, -2)
        end
        lines[#lines + 1] = line
      end
      return lines
    end,
  }
end

--- A running child. All methods are plain closures (no `self`).
---@class harnt.stdio.Handle
---@field send fun(value: any) encode `value` as JSON + newline onto stdin
---@field write fun(text: string) raw write onto stdin
---@field stop fun() SIGTERM the child and close pipes
---@field pid integer

---@class harnt.stdio.Opts
---@field cmd string[] argv; cmd[1] is the executable
---@field cwd? string
---@field env? table<string, string> extra env vars (merged over the inherited environment)
---@field on_message? fun(value: any, line: string) one decoded stdout line (`value` is nil if the line wasn't valid JSON)
---@field on_stderr? fun(chunk: string)
---@field on_exit? fun(code: integer, signal: integer)

--- Build the `{ "K=V" }` env array libuv wants: the inherited environment with
--- `overrides` applied on top. Returns nil to signal "inherit unchanged".
---@param overrides? table<string, string>
---@return string[]?
local function build_env(overrides)
  if not overrides or next(overrides) == nil then
    return nil
  end
  local merged = vim.fn.environ()
  for k, v in pairs(overrides) do
    merged[k] = v
  end
  local out = {}
  for k, v in pairs(merged) do
    out[#out + 1] = k .. "=" .. v
  end
  return out
end

--- Spawn a child and stream its stdout as JSON lines. Raises if the process
--- cannot be spawned.
---@param opts harnt.stdio.Opts
---@return harnt.stdio.Handle
function M.spawn(opts)
  local uv = vim.uv
  local stdin = assert(uv.new_pipe(false))
  local stdout = assert(uv.new_pipe(false))
  local stderr = assert(uv.new_pipe(false))

  local exe = assert(opts.cmd[1], "stdio.spawn: opts.cmd must be non-empty")
  ---@type uv.uv_process_t?
  local handle
  handle = uv.spawn(exe, {
    args = vim.list_slice(opts.cmd, 2),
    cwd = opts.cwd,
    env = build_env(opts.env),
    stdio = { stdin, stdout, stderr },
  }, function(code, signal)
    for _, pipe in ipairs({ stdin, stdout, stderr }) do
      if not pipe:is_closing() then
        pipe:close()
      end
    end
    if handle and not handle:is_closing() then
      handle:close()
    end
    if opts.on_exit then
      vim.schedule(function()
        opts.on_exit(code, signal)
      end)
    end
  end)
  assert(handle, ("stdio.spawn: could not spawn %q"):format(opts.cmd[1]))

  local lb = M.line_buffer()
  stdout:read_start(function(err, chunk)
    if err or not chunk then
      return
    end
    local lines = lb:feed(chunk)
    if #lines > 0 and opts.on_message then
      -- Decode + dispatch on the main loop: order is preserved (vim.schedule is
      -- FIFO) and handlers may touch the Neovim API.
      vim.schedule(function()
        for _, line in ipairs(lines) do
          if line ~= "" then
            local ok, value = pcall(vim.json.decode, line)
            opts.on_message(ok and value or nil, line)
          end
        end
      end)
    end
  end)

  if opts.on_stderr then
    stderr:read_start(function(err, chunk)
      if err or not chunk then
        return
      end
      vim.schedule(function()
        opts.on_stderr(chunk)
      end)
    end)
  end

  local function write(text)
    if not stdin:is_closing() then
      stdin:write(text)
    end
  end

  return {
    pid = handle:get_pid(),
    write = write,
    send = function(value)
      write(vim.json.encode(value) .. "\n")
    end,
    stop = function()
      if handle and not handle:is_closing() then
        pcall(function()
          handle:kill("sigterm")
        end)
      end
    end,
  }
end

return M
