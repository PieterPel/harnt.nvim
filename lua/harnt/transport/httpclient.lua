--- Local HTTP/1.1 *client* (`vim.uv`).
---
--- The dial-out counterpart to `transport/http.lua` (which listens). Some agents
--- host their own HTTP server and expect the editor to connect *in* as a client —
--- OpenCode is the first: its native TUI is a client of an `opencode serve` HTTP
--- server, so harnt joins as a second client, subscribing to the Server-Sent
--- Events stream (`GET /event`) for diffs/approvals and POSTing replies back.
---
--- Two shapes, both loopback-only and pure Lua on `vim.uv` (no curl, no runtime —
--- BET.md #4):
---  * `request` — a one-shot request; buffers the response (Content-Length or
---    chunked) and calls back once with `{status, body}`.
---  * `stream` — a long-lived GET whose `text/event-stream` body is parsed into
---    SSE events, delivered one at a time until the server or caller closes it.
---
--- The wire-parsing pieces (`parse_head`, `chunked_decoder`, `sse_parser`) are
--- pure and separately exported so they're unit-testable without a socket.

local M = {}

--- Parse an HTTP response head (status line + headers).
---@param head string bytes up to (not including) the CRLFCRLF terminator
---@return integer status, table<string, string> headers lowercased header names → values
function M.parse_head(head)
  local status = math.floor(tonumber(head:match("^HTTP/1%.[01]%s+(%d+)")) or 0)
  local headers = {}
  for line in head:gmatch("[^\r\n]+") do
    local name, value = line:match("^([%w%-]+):%s*(.-)%s*$")
    if name then
      headers[name:lower()] = value
    end
  end
  return status, headers
end

--- A stateful decoder for `Transfer-Encoding: chunked` bodies. Feed raw body
--- bytes; get back the decoded payload as it completes. Pure: the only state is
--- the partial buffer, so it's unit-testable frame by frame.
---@return { feed: fun(chunk: string): string }
function M.chunked_decoder()
  local buf = ""
  return {
    feed = function(chunk)
      buf = buf .. chunk
      local out = {}
      while true do
        -- Each chunk is "<hexlen>\r\n<data>\r\n"; the size line ends at the CRLF.
        local size_end = buf:find("\r\n", 1, true)
        if not size_end then
          break
        end
        local hex = buf:sub(1, size_end - 1):gsub(";.*$", "") -- strip any extensions
        local len = tonumber(hex, 16)
        if not len then
          -- Not a valid size line yet (or garbage) — wait for more bytes.
          break
        end
        local data_start = size_end + 2
        if #buf < data_start + len + 2 - 1 then
          break -- data + trailing CRLF not all here yet
        end
        out[#out + 1] = buf:sub(data_start, data_start + len - 1)
        buf = buf:sub(data_start + len + 2) -- skip data and its trailing CRLF
        if len == 0 then
          break -- terminal chunk
        end
      end
      return table.concat(out)
    end,
  }
end

--- A stateful Server-Sent-Events parser. Feed decoded body text; get back one
--- string per completed event (the concatenated `data:` field values). Comments
--- (`:` lines) and non-`data` fields are ignored — enough for OpenCode's stream,
--- which only uses `data:`. Pure.
---@return { feed: fun(text: string): string[] }
function M.sse_parser()
  local buf = ""
  return {
    feed = function(text)
      buf = buf .. text
      local events = {}
      while true do
        -- Events are separated by a blank line (\n\n, tolerating \r\n\r\n).
        local sep_start, sep_end = buf:find("\r?\n\r?\n")
        if not sep_start or not sep_end then
          break
        end
        local block = buf:sub(1, sep_start - 1)
        buf = buf:sub(sep_end + 1)
        local data = {}
        for line in (block .. "\n"):gmatch("(.-)\n") do
          line = line:gsub("\r$", "")
          local value = line:match("^data:%s?(.*)$")
          if value then
            data[#data + 1] = value
          end
        end
        if #data > 0 then
          events[#events + 1] = table.concat(data, "\n")
        end
      end
      return events
    end,
  }
end

--- Build the raw request bytes.
---@param opts { method: string, path: string, host: string, port: integer, headers?: table<string,string>, body?: string }
---@return string
local function encode_request(opts)
  local body = opts.body or ""
  local headers = vim.tbl_extend("keep", opts.headers or {}, {
    ["host"] = ("%s:%d"):format(opts.host, opts.port),
    ["connection"] = "close",
  })
  if opts.body ~= nil then
    headers["content-length"] = tostring(#body)
  end
  local lines = { ("%s %s HTTP/1.1"):format(opts.method, opts.path) }
  for name, value in pairs(headers) do
    lines[#lines + 1] = ("%s: %s"):format(name, value)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = body
  return table.concat(lines, "\r\n")
end

--- Connect a loopback TCP socket and write `request_bytes`. `on_chunk` receives
--- raw response bytes as they arrive; `on_end` fires once on close/EOF/error.
--- Returns a handle with `close`.
---@param host string
---@param port integer
---@param request_bytes string
---@param on_chunk fun(chunk: string)
---@param on_end fun(err?: string)
---@return { close: fun() }
local function dial(host, port, request_bytes, on_chunk, on_end)
  local uv = vim.uv
  local tcp = assert(uv.new_tcp())
  local done = false
  local function finish(err)
    if done then
      return
    end
    done = true
    if not tcp:is_closing() then
      tcp:close()
    end
    on_end(err)
  end

  tcp:connect(host, port, function(cerr)
    if cerr then
      finish(cerr)
      return
    end
    tcp:write(request_bytes, function(werr)
      if werr then
        finish(werr)
      end
    end)
    tcp:read_start(function(rerr, chunk)
      if rerr then
        finish(rerr)
      elseif chunk then
        on_chunk(chunk)
      else
        finish() -- EOF
      end
    end)
  end)

  return {
    close = function()
      finish()
    end,
  }
end

--- A stateful reader that separates the response head from the body and decodes
--- the body (chunked or identity). `on_head(status, headers)` fires once; each
--- decoded body slice is delivered to `on_body(bytes)`; `on_complete` fires once
--- the body is definitively finished (declared Content-Length consumed, or the
--- chunked terminator seen) — a Content-Length body can't rely on the connection
--- closing, since keep-alive servers hold the socket open. A stream with neither
--- (SSE) never completes on its own; the caller closes it. Pure aside from the
--- decoder state, so `request`/`stream` share one body pipeline.
---@param on_head fun(status: integer, headers: table<string,string>)
---@param on_body fun(bytes: string)
---@param on_complete? fun()
---@return { feed: fun(chunk: string) }
function M.body_reader(on_head, on_body, on_complete)
  local buf = ""
  local head_done = false
  local completed = false
  local content_length ---@type integer?
  local body_seen = 0
  local dechunk ---@type { feed: fun(chunk: string): string }?

  local function complete()
    if not completed then
      completed = true
      if on_complete then
        on_complete()
      end
    end
  end

  return {
    feed = function(chunk)
      if completed then
        return
      end
      if not head_done then
        buf = buf .. chunk
        local ends = buf:find("\r\n\r\n", 1, true)
        if not ends then
          return
        end
        local status, headers = M.parse_head(buf:sub(1, ends - 1))
        head_done = true
        local rest = buf:sub(ends + 4)
        buf = ""
        if (headers["transfer-encoding"] or ""):lower():find("chunked", 1, true) then
          dechunk = M.chunked_decoder()
        else
          content_length = tonumber(headers["content-length"] or "")
        end
        on_head(status, headers)
        chunk = rest
        if content_length == 0 then
          complete()
          return
        end
      end
      if chunk == "" then
        return
      end
      body_seen = body_seen + #chunk
      on_body(dechunk and dechunk.feed(chunk) or chunk)
      if content_length and body_seen >= content_length then
        complete()
      end
    end,
  }
end

--- The result of a one-shot request.
---@class harnt.httpclient.Response
---@field status integer
---@field body string

---@class harnt.httpclient.RequestOpts
---@field host? string defaults to 127.0.0.1
---@field port integer
---@field method? string defaults to GET
---@field path string
---@field headers? table<string, string>
---@field body? string sending a body implies Content-Length; JSON callers set content-type
---@field json? any convenience: encode as JSON body + set content-type

--- Perform a one-shot HTTP request and buffer the full response. `cb` fires once
--- with `{status, body}`, or with `nil, err` on transport failure. The body
--- callback runs on the main loop (safe to touch Neovim / caller schedules).
---@param opts harnt.httpclient.RequestOpts
---@param cb fun(res: harnt.httpclient.Response?, err?: string)
function M.request(opts, cb)
  local host = opts.host or "127.0.0.1"
  local headers = opts.headers or {}
  local body = opts.body
  if opts.json ~= nil then
    body = vim.json.encode(opts.json)
    headers = vim.tbl_extend("keep", { ["content-type"] = "application/json" }, headers)
  end
  local req = encode_request({
    method = opts.method or "GET",
    path = opts.path,
    host = host,
    port = opts.port,
    headers = headers,
    body = body,
  })

  local status = 0
  local chunks = {}
  local delivered = false
  ---@type { close: fun() }?
  local conn

  local function deliver(err)
    if delivered then
      return
    end
    delivered = true
    vim.schedule(function()
      if err and status == 0 then
        cb(nil, tostring(err))
      else
        cb({ status = status, body = table.concat(chunks) })
      end
    end)
  end

  local reader = M.body_reader(function(s)
    status = s
  end, function(bytes)
    chunks[#chunks + 1] = bytes
  end, function()
    -- Body fully received (Content-Length consumed) — deliver now rather than
    -- waiting for a keep-alive server to close the socket, then close ourselves.
    deliver()
    if conn then
      conn.close()
    end
  end)

  conn = dial(host, opts.port, req, function(chunk)
    reader.feed(chunk)
  end, function(err)
    deliver(err) -- EOF path (connection: close, or chunked-until-close)
  end)
end

---@class harnt.httpclient.StreamOpts
---@field host? string defaults to 127.0.0.1
---@field port integer
---@field path string
---@field headers? table<string, string>
---@field on_open? fun(status: integer, headers: table<string,string>)
---@field on_event fun(data: string) one SSE event's concatenated data payload
---@field on_close? fun(err?: string)

--- Subscribe to a Server-Sent-Events stream (`GET path`). Delivers each event's
--- data payload to `on_event` (on the main loop) until the server closes the
--- connection or the caller calls `close`. Returns a handle with `close`.
---@param opts harnt.httpclient.StreamOpts
---@return { close: fun() }
function M.stream(opts)
  local host = opts.host or "127.0.0.1"
  local req = encode_request({
    method = "GET",
    path = opts.path,
    host = host,
    port = opts.port,
    headers = vim.tbl_extend(
      "keep",
      { ["accept"] = "text/event-stream", ["connection"] = "keep-alive" },
      opts.headers or {}
    ),
    -- No body; the server holds the connection open and streams events.
  })

  local sse = M.sse_parser()
  local reader = M.body_reader(function(status, headers)
    if opts.on_open then
      vim.schedule(function()
        opts.on_open(status, headers)
      end)
    end
  end, function(bytes)
    local events = sse.feed(bytes)
    if #events > 0 then
      vim.schedule(function()
        for _, data in ipairs(events) do
          opts.on_event(data)
        end
      end)
    end
  end)

  local handle = dial(host, opts.port, req, function(chunk)
    reader.feed(chunk)
  end, function(err)
    if opts.on_close then
      vim.schedule(function()
        opts.on_close(err and tostring(err) or nil)
      end)
    end
  end)

  return { close = handle.close }
end

return M
