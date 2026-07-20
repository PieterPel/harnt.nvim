--- Unix-domain socket server primitive.
---
--- A generic `vim.uv` pipe server bound to a filesystem path: accept connections,
--- stream raw bytes in, write raw bytes back. Framing is the caller's job — the
--- codex `/ide` channel uses a u32-LE length prefix, the agent hook bridge uses
--- parse-until-complete JSON — so this layer stays byte-oriented and
--- agent-agnostic, exactly like `ws`/`stdio`/`http`.
---
--- Two consumers today: codex's `/ide` context socket (`providers/codex`) and the
--- Antigravity hook decision socket (`transport/reqsock` → `providers/antigravity`).

local M = {}

--- One accepted connection. Plain closures (no `self`).
---@class harnt.unixsock.Conn
---@field read_start fun(on_chunk: fun(chunk: string)) start streaming inbound bytes
---@field write fun(data: string) write raw bytes back
---@field close fun() close this connection

--- A listening server.
---@class harnt.unixsock.Server
---@field path string the bound socket path
---@field close fun() stop listening, drop clients, unlink the socket

---@class harnt.unixsock.Opts
---@field path string filesystem path to bind
---@field on_connection fun(conn: harnt.unixsock.Conn) called once per accepted client
---@field backlog? integer listen backlog (default 16)

--- Wrap an accepted `uv_pipe_t` as a Conn. Inbound chunks are dispatched on the
--- main loop (`vim.schedule`) so handlers may touch the Neovim API.
---@param client uv.uv_pipe_t
---@return harnt.unixsock.Conn
local function wrap(client)
  return {
    read_start = function(on_chunk)
      client:read_start(function(err, chunk)
        if err or not chunk then
          if not client:is_closing() then
            client:close()
          end
          return
        end
        vim.schedule(function()
          on_chunk(chunk)
        end)
      end)
    end,
    write = function(data)
      if not client:is_closing() then
        client:write(data)
      end
    end,
    close = function()
      if not client:is_closing() then
        client:close()
      end
    end,
  }
end

--- Bind + listen on a unix socket. The path must be free (see `free_stale`).
--- Returns nil + an error message if the bind fails (e.g. `EADDRINUSE`).
---@param opts harnt.unixsock.Opts
---@return harnt.unixsock.Server? server, string? err
function M.server(opts)
  local uv = vim.uv
  local pipe = assert(uv.new_pipe(false))

  local ok, err = pcall(function()
    assert(pipe:bind(opts.path))
    assert(pipe:listen(opts.backlog or 16, function(listen_err)
      if listen_err then
        return
      end
      local client = assert(uv.new_pipe(false))
      pipe:accept(client)
      opts.on_connection(wrap(client))
    end))
  end)
  if not ok then
    if not pipe:is_closing() then
      pipe:close()
    end
    return nil, tostring(err)
  end

  local closed = false
  return {
    path = opts.path,
    close = function()
      if closed then
        return
      end
      closed = true
      if not pipe:is_closing() then
        pipe:close()
      end
      -- Best-effort: remove our socket file so a later bind at the same path
      -- (a fresh session) starts clean.
      pcall(os.remove, opts.path)
    end,
  }
end

--- Decide whether the socket at `path` is free to bind: absent, or present but
--- dead (a stale file left by a crashed process). A *live* socket — someone is
--- accepting connections — is left untouched, so we never clobber another
--- editor that legitimately owns a shared rendezvous path.
---
--- `cb(true)` means the path is now free (it was absent, or was stale and has
--- been unlinked); `cb(false)` means a live server owns it — do not bind.
---@param path string
---@param cb fun(free: boolean)
function M.free_stale(path, cb)
  local uv = vim.uv
  if not uv.fs_stat(path) then
    cb(true)
    return
  end
  -- A file exists. Probe it: a successful connect means a live listener.
  local probe = assert(uv.new_pipe(false))
  local decided = false
  local function decide(free)
    if decided then
      return
    end
    decided = true
    if not probe:is_closing() then
      probe:close()
    end
    vim.schedule(function()
      cb(free)
    end)
  end
  probe:connect(path, function(err)
    if err then
      -- Nobody listening (ECONNREFUSED / ENOENT): the file is stale.
      pcall(os.remove, path)
      decide(true)
    else
      -- Live listener owns it.
      decide(false)
    end
  end)
end

return M
