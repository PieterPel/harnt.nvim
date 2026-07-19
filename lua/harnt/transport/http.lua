--- Minimal local HTTP/1.1 server (`vim.uv`).
---
--- The listen side for HTTP-based agent channels — currently Antigravity's
--- **Connect** (`connect+proto`) ExtensionServer, which the exa language server
--- dials for editor actions. This layer is *just HTTP*: it parses the request
--- line, headers, and a Content-Length body, hands the request to a handler, and
--- writes the response; keep-alive connections are supported (multiple requests
--- per socket). The Connect framing + protobuf messages live above this, in the
--- provider. Pure Lua on `vim.uv`, loopback only.
---
--- Why hand-rolled: no in-process HTTP server library works under Neovim's libuv
--- loop (`lua-http` needs its own `cqueues` loop), and HTTP/1.1 parsing is simpler
--- than the RFC-6455 framing already hand-rolled in `ws.lua`. HTTP/1.1 is
--- sufficient — the exa language server's Connect client speaks it (verified).
--- The connection state machine is split from the socket so it's unit-testable.

local M = {}

--- A parsed HTTP request.
---@class harnt.http.Request
---@field method string
---@field path string
---@field headers table<string, string> lowercased header names → values
---@field body string

--- A response a handler returns. For a buffered (unary) response set `body`. For
--- a server-streaming response (Connect streaming) set `stream`: it's called with
--- a writer and may push frames over time (the response is chunked-encoded and the
--- connection stays open until `finish()`).
---@class harnt.http.Response
---@field status integer
---@field headers? table<string, string>
---@field body? string
---@field stream? fun(w: harnt.http.StreamWriter)

--- Writer for a streaming response: `write` sends one chunk, `finish` ends the
--- chunked body.
---@class harnt.http.StreamWriter
---@field write fun(bytes: string)
---@field finish fun()

--- Reason phrases for the statuses we emit.
local REASON = {
  [200] = "OK",
  [400] = "Bad Request",
  [404] = "Not Found",
  [500] = "Internal Server Error",
}

--- Parse a raw header block into method, path, and a lowercased-key table.
---@param head string request head, up to (not including) the blank line
---@return string method, string path, table<string, string> headers
local function parse_head(head)
  local method, path = head:match("^(%u+)%s+(%S+)%s+HTTP/1%.[01]")
  local headers = {}
  for line in head:gmatch("[^\r\n]+") do
    local name, value = line:match("^([%w%-]+):%s*(.-)%s*$")
    if name then
      headers[name:lower()] = value
    end
  end
  return method or "", path or "", headers
end

--- Serialize a response to bytes. Always sets Content-Length and keeps the
--- connection alive unless the handler set those headers itself.
---@param res harnt.http.Response
---@return string
function M.encode_response(res)
  local body = res.body or ""
  local headers = vim.tbl_extend("keep", res.headers or {}, {
    ["content-length"] = tostring(#body),
    ["connection"] = "keep-alive",
  })
  local lines = { ("HTTP/1.1 %d %s"):format(res.status, REASON[res.status] or "OK") }
  for name, value in pairs(headers) do
    lines[#lines + 1] = ("%s: %s"):format(name, value)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = body
  return table.concat(lines, "\r\n")
end

--- Serialize a streaming response head (chunked, no Content-Length).
---@param res harnt.http.Response
---@return string
function M.encode_stream_head(res)
  local headers = vim.tbl_extend("keep", res.headers or {}, {
    ["transfer-encoding"] = "chunked",
    ["connection"] = "keep-alive",
  })
  local lines = { ("HTTP/1.1 %d %s"):format(res.status, REASON[res.status] or "OK") }
  for name, value in pairs(headers) do
    lines[#lines + 1] = ("%s: %s"):format(name, value)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = ""
  return table.concat(lines, "\r\n")
end

--- A connection state machine: feed bytes; it parses requests and, per request,
--- calls `on_request(req)` and writes the returned response via `on_write`.
---@class harnt.http.Connection
---@field feed fun(self: harnt.http.Connection, chunk: string)

---@class harnt.http.ConnectionOpts
---@field on_write fun(bytes: string)
---@field on_request fun(req: harnt.http.Request): harnt.http.Response

---@param opts harnt.http.ConnectionOpts
---@return harnt.http.Connection
function M.connection(opts)
  local buffer = ""

  --- Parse + dispatch one request from the front of the buffer, if complete.
  ---@return boolean progressed
  local function step()
    local ends = buffer:find("\r\n\r\n", 1, true)
    if not ends then
      return false
    end
    local method, path, headers = parse_head(buffer:sub(1, ends - 1))
    local len = tonumber(headers["content-length"] or "0") or 0
    local body_start = ends + 4
    if #buffer < body_start + len - 1 then
      return false -- body not fully arrived yet
    end
    local body = buffer:sub(body_start, body_start + len - 1)
    buffer = buffer:sub(body_start + len)

    local res = opts.on_request({ method = method, path = path, headers = headers, body = body })
    if res.stream then
      -- Server-streaming: chunked head, then the handler pushes frames (each one
      -- HTTP chunk) via the writer and ends the body with `finish`.
      opts.on_write(M.encode_stream_head(res))
      res.stream({
        write = function(bytes)
          opts.on_write(("%x\r\n"):format(#bytes) .. bytes .. "\r\n")
        end,
        finish = function()
          opts.on_write("0\r\n\r\n")
        end,
      })
    else
      opts.on_write(M.encode_response(res))
    end
    return true
  end

  return {
    feed = function(_self, chunk)
      buffer = buffer .. chunk
      local progressed = true
      while progressed do
        progressed = step()
      end
    end,
  }
end

---@class harnt.http.Server
---@field port integer
---@field close fun()

---@class harnt.http.ServerOpts
---@field host? string defaults to 127.0.0.1
---@field port? integer defaults to 0 (OS-assigned)
---@field on_request fun(req: harnt.http.Request): harnt.http.Response

--- Start a loopback HTTP server. Returns nil + err on bind failure. The request
--- handler runs in libuv callbacks; if it touches the Neovim API it must schedule.
---@param opts harnt.http.ServerOpts
---@return harnt.http.Server? server, string? err
function M.server(opts)
  local uv = vim.uv
  local tcp = assert(uv.new_tcp())
  local ok, err = pcall(function()
    assert(tcp:bind(opts.host or "127.0.0.1", opts.port or 0))
  end)
  if not ok then
    pcall(function()
      tcp:close()
    end)
    return nil, tostring(err)
  end

  local sockets = {}
  tcp:listen(128, function(lerr)
    if lerr then
      return
    end
    local sock = assert(uv.new_tcp())
    tcp:accept(sock)
    sockets[sock] = true
    local conn = M.connection({
      on_write = function(bytes)
        if not sock:is_closing() then
          sock:write(bytes)
        end
      end,
      on_request = opts.on_request,
    })
    sock:read_start(function(rerr, chunk)
      if rerr or not chunk then
        if not sock:is_closing() then
          sock:close()
        end
        sockets[sock] = nil
        return
      end
      conn:feed(chunk)
    end)
  end)

  local name = tcp:getsockname()
  return {
    port = name and name.port or 0,
    close = function()
      for sock in pairs(sockets) do
        if not sock:is_closing() then
          sock:close()
        end
      end
      if not tcp:is_closing() then
        tcp:close()
      end
    end,
  }
end

return M
