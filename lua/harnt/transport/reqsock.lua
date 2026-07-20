--- JSON request/response over a unix-domain socket.
---
--- A one-shot RPC seam for tools that speak "write one JSON object, read one JSON
--- object back, done" — notably lifecycle hooks bridged from a child process
--- (`sh -c '… | nc -U <sock>'`). The client writes a single JSON request; this
--- server reads until that request parses in full (robust to pretty- or
--- compact-printed input and to chunked delivery, without needing the client to
--- half-close), hands it to `on_request` with a `respond` callback, then writes
--- the JSON reply and closes the connection.
---
--- Agent-agnostic: the Antigravity hook bridge uses it to turn `PreToolUse` into
--- an interactive diff/approval, but nothing here knows about any agent. Built on
--- `transport/unixsock`.

local unixsock = require("harnt.transport.unixsock")

local M = {}

--- Try to decode a complete JSON object from the accumulated buffer. Trailing
--- whitespace is tolerated. Returns the value on success, or nil while the buffer
--- is still a partial object.
---@param buf string
---@return table?
local function try_decode(buf)
  local trimmed = (buf:gsub("%s+$", ""))
  if trimmed == "" then
    return nil
  end
  local ok, value = pcall(vim.json.decode, trimmed)
  if ok and type(value) == "table" then
    return value
  end
  return nil
end

---@class harnt.reqsock.Opts
---@field path string socket path to bind
---@field on_request fun(request: table, respond: fun(response: table)) handle one request

--- Serve JSON request/response on the unix socket at `opts.path`. Returns the
--- underlying server (with `close`) or nil + error if the bind fails.
---@param opts harnt.reqsock.Opts
---@return harnt.unixsock.Server? server, string? err
function M.serve(opts)
  return unixsock.server({
    path = opts.path,
    on_connection = function(conn)
      local buf = ""
      local answered = false
      conn.read_start(function(chunk)
        if answered then
          return
        end
        buf = buf .. chunk
        local request = try_decode(buf)
        if not request then
          return -- keep reading; the object isn't complete yet
        end
        answered = true
        opts.on_request(request, function(response)
          conn.write(vim.json.encode(response) .. "\n")
          conn.close()
        end)
      end)
    end,
  })
end

return M
