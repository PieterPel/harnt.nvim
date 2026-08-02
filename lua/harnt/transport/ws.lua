--- RFC-6455 WebSocket primitives + a minimal server.
---
--- Powers WebSocket reverse-MCP: the editor hosts this server, an agent's CLI
--- connects in and speaks JSON-RPC over text frames. This file holds the wire
--- pieces (handshake accept-key, frame encode/decode); the TCP server is added
--- on top. Neovim ships no SHA-1 (only sha256), so the handshake needs a small
--- pure-Lua SHA-1 — verified against RFC test vectors in the spec.

local bit = require("bit")
local band, bor, bxor = bit.band, bit.bor, bit.bxor
local lshift, rshift, rol = bit.lshift, bit.rshift, bit.rol

local M = {}

--- WebSocket frame opcodes.
M.opcodes = {
  continuation = 0x0,
  text = 0x1,
  binary = 0x2,
  close = 0x8,
  ping = 0x9,
  pong = 0xA,
}

--- Magic GUID appended to the client key before hashing (RFC 6455 §4.2.2).
M.GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

--- Big-endian 8-byte encoding of a bit-length (n < 2^53), avoiding the 32-bit
--- limit of the bitop library.
---@param n integer
---@return string
local function u64_be(n)
  local bytes = {}
  for i = 8, 1, -1 do
    bytes[i] = string.char(n % 256)
    n = math.floor(n / 256)
  end
  return table.concat(bytes)
end

--- Four big-endian bytes of a 32-bit word.
---@param w integer
---@return string
local function word_be(w)
  return string.char(
    band(rshift(w, 24), 0xFF),
    band(rshift(w, 16), 0xFF),
    band(rshift(w, 8), 0xFF),
    band(w, 0xFF)
  )
end

--- SHA-1 digest of `msg` as a raw 20-byte string.
---@param msg string
---@return string
local function sha1_raw(msg)
  local h0, h1, h2, h3, h4 = 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0
  local bitlen = #msg * 8

  msg = msg .. "\128"
  while #msg % 64 ~= 56 do
    msg = msg .. "\0"
  end
  msg = msg .. u64_be(bitlen)

  local w = {}
  for chunk = 1, #msg, 64 do
    for i = 0, 15 do
      local o = chunk + i * 4
      w[i] = bor(
        lshift(msg:byte(o), 24),
        lshift(msg:byte(o + 1), 16),
        lshift(msg:byte(o + 2), 8),
        msg:byte(o + 3)
      )
    end
    for i = 16, 79 do
      w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
    end

    local a, b, c, d, e = h0, h1, h2, h3, h4
    for i = 0, 79 do
      local f, k
      if i < 20 then
        f = bor(band(b, c), band(bit.bnot(b), d))
        k = 0x5A827999
      elseif i < 40 then
        f = bxor(b, c, d)
        k = 0x6ED9EBA1
      elseif i < 60 then
        f = bor(bor(band(b, c), band(b, d)), band(c, d))
        k = 0x8F1BBCDC
      else
        f = bxor(b, c, d)
        k = 0xCA62C1D6
      end
      local temp = band(rol(a, 5) + f + e + k + w[i], 0xFFFFFFFF)
      e, d, c, b, a = d, c, rol(b, 30), a, temp
    end

    h0 = band(h0 + a, 0xFFFFFFFF)
    h1 = band(h1 + b, 0xFFFFFFFF)
    h2 = band(h2 + c, 0xFFFFFFFF)
    h3 = band(h3 + d, 0xFFFFFFFF)
    h4 = band(h4 + e, 0xFFFFFFFF)
  end

  return word_be(h0) .. word_be(h1) .. word_be(h2) .. word_be(h3) .. word_be(h4)
end

--- SHA-1 digest as a lowercase hex string (exposed for tests).
---@param msg string
---@return string
function M.sha1_hex(msg)
  return (sha1_raw(msg):gsub(".", function(ch)
    return ("%02x"):format(ch:byte())
  end))
end

--- Compute the `Sec-WebSocket-Accept` value for a client's key (RFC 6455).
---@param client_key string the value of the client's Sec-WebSocket-Key header
---@return string
function M.accept_key(client_key)
  return vim.base64.encode(sha1_raw(client_key .. M.GUID))
end

--- Encode a server->client frame (unmasked, per RFC 6455 §5.1).
---@param payload string
---@param opcode? integer defaults to text
---@param fin? boolean defaults to true
---@return string
function M.encode_frame(payload, opcode, fin)
  opcode = opcode or M.opcodes.text
  local b1 = bor((fin ~= false) and 0x80 or 0x00, opcode)
  local len = #payload

  local header
  if len < 126 then
    header = string.char(b1, len)
  elseif len <= 0xFFFF then
    header = string.char(b1, 126, band(rshift(len, 8), 0xFF), band(len, 0xFF))
  else
    header = string.char(b1, 127) .. u64_be(len)
  end
  return header .. payload
end

--- A decoded WebSocket frame.
---@class harnt.ws.Frame
---@field fin boolean
---@field opcode integer
---@field payload string

--- Decode one frame from the front of `data`. Client->server frames are masked
--- and unmasked here. Returns nil when `data` doesn't yet hold a full frame.
---@param data string
---@return harnt.ws.Frame? frame, integer? consumed bytes consumed from `data`
function M.decode_frame(data)
  if #data < 2 then
    return nil
  end
  local b1, b2 = data:byte(1, 2)
  local fin = band(b1, 0x80) ~= 0
  local opcode = band(b1, 0x0F)
  local masked = band(b2, 0x80) ~= 0
  local len = band(b2, 0x7F)
  local offset = 2

  if len == 126 then
    if #data < 4 then
      return nil
    end
    len = bor(lshift(data:byte(3), 8), data:byte(4))
    offset = 4
  elseif len == 127 then
    if #data < 10 then
      return nil
    end
    len = 0
    for i = 3, 10 do
      len = len * 256 + data:byte(i)
    end
    offset = 10
  end

  local mask
  if masked then
    if #data < offset + 4 then
      return nil
    end
    mask = { data:byte(offset + 1, offset + 4) }
    offset = offset + 4
  end

  local consumed = offset + len --[[@as integer]]
  if #data < consumed then
    return nil
  end
  local payload = data:sub(offset + 1, consumed)
  if masked and mask then
    local out = {}
    for i = 1, #payload do
      out[i] = string.char(bxor(payload:byte(i), mask[(i - 1) % 4 + 1] or 0))
    end
    payload = table.concat(out)
  end

  return { fin = fin, opcode = opcode, payload = payload }, consumed
end

--- A transport-agnostic server-side connection state machine: feed it raw bytes,
--- it drives the HTTP upgrade handshake then dispatches decoded frames. All I/O
--- is via callbacks, so it's testable without a socket.
---@class harnt.ws.Connection
---@field feed fun(self: harnt.ws.Connection, chunk: string)
---@field send fun(self: harnt.ws.Connection, text: string)
---@field close fun(self: harnt.ws.Connection)

---@class harnt.ws.ConnectionOpts
---@field on_write fun(bytes: string) write bytes back to the peer
---@field on_message? fun(payload: string) a complete text/binary message arrived
---@field on_open? fun() the handshake completed
---@field on_close? fun() the connection closed
---@field authenticate? fun(headers: table<string, string>): boolean reject the handshake if this returns false

--- Parse HTTP request headers into a table keyed by lowercased name.
---@param head string the raw request head (through the blank line)
---@return table<string, string>
local function parse_headers(head)
  local headers = {}
  for line in head:gmatch("[^\r\n]+") do
    local name, value = line:match("^([%w%-]+):%s*(.-)%s*$")
    if name then
      headers[name:lower()] = value
    end
  end
  return headers
end

---@param opts harnt.ws.ConnectionOpts
---@return harnt.ws.Connection
function M.connection(opts)
  local conn = {
    _buffer = "",
    ---@type boolean
    _upgraded = false,
    ---@type boolean
    _closed = false,
  }

  --- Try to complete the opening handshake from the buffered request.
  ---@return boolean upgraded
  local function handshake()
    local ends = conn._buffer:find("\r\n\r\n", 1, true)
    if not ends then
      return false
    end
    local head = conn._buffer:sub(1, ends + 3)
    conn._buffer = conn._buffer:sub(ends + 4)

    local key = head:match("[Ss]ec%-[Ww]eb[Ss]ocket%-[Kk]ey:%s*([%w%+/=]+)")
    if not key then
      opts.on_write("HTTP/1.1 400 Bad Request\r\n\r\n")
      conn._closed = true
      if opts.on_close then
        opts.on_close()
      end
      return false
    end

    local headers = parse_headers(head)

    if opts.authenticate and not opts.authenticate(headers) then
      opts.on_write("HTTP/1.1 401 Unauthorized\r\n\r\n")
      conn._closed = true
      if opts.on_close then
        opts.on_close()
      end
      return false
    end

    -- Echo the client's offered subprotocol (Claude sends "mcp"). Some WS
    -- client libraries treat an unacknowledged Sec-WebSocket-Protocol as a
    -- negotiation failure and tear down the connection right after the
    -- opening handshake, before ever speaking MCP — reproduced against
    -- claude-code/2.1.220: the client closed the socket ~8ms after our 101
    -- response, having sent no further bytes.
    local response_lines = {
      "HTTP/1.1 101 Switching Protocols",
      "Upgrade: websocket",
      "Connection: Upgrade",
      "Sec-WebSocket-Accept: " .. M.accept_key(key),
    }
    if headers["sec-websocket-protocol"] then
      table.insert(response_lines, "Sec-WebSocket-Protocol: " .. headers["sec-websocket-protocol"])
    end
    table.insert(response_lines, "")
    table.insert(response_lines, "")

    opts.on_write(table.concat(response_lines, "\r\n"))
    conn._upgraded = true
    if opts.on_open then
      opts.on_open()
    end
    return true
  end

  function conn:feed(chunk)
    if self._closed then
      return
    end
    self._buffer = self._buffer .. chunk
    if not self._upgraded and not handshake() then
      return
    end

    while not self._closed do
      local frame, consumed = M.decode_frame(self._buffer)
      if not frame or not consumed then
        break
      end
      self._buffer = self._buffer:sub(consumed + 1)

      if frame.opcode == M.opcodes.text or frame.opcode == M.opcodes.binary then
        if opts.on_message then
          opts.on_message(frame.payload)
        end
      elseif frame.opcode == M.opcodes.ping then
        opts.on_write(M.encode_frame(frame.payload, M.opcodes.pong))
      elseif frame.opcode == M.opcodes.close then
        self:close()
      end
    end
  end

  function conn:send(text)
    if self._upgraded and not self._closed then
      opts.on_write(M.encode_frame(text, M.opcodes.text))
    end
  end

  function conn:close()
    if self._closed then
      return
    end
    self._closed = true
    opts.on_write(M.encode_frame("", M.opcodes.close))
    if opts.on_close then
      opts.on_close()
    end
  end

  return conn
end

---@class harnt.ws.Server
---@field port integer the bound port (useful when binding to port 0)
---@field close fun() stop listening and close all clients

---@class harnt.ws.ServerOpts
---@field host? string defaults to 127.0.0.1
---@field port? integer defaults to 0 (an OS-assigned port)
---@field authenticate? fun(headers: table<string, string>): boolean reject the handshake if this returns false
---@field on_open? fun(client: harnt.ws.Connection)
---@field on_message? fun(client: harnt.ws.Connection, payload: string)
---@field on_close? fun(client: harnt.ws.Connection)

--- Start a loopback WebSocket server on `vim.uv`. Returns nil + err if the bind
--- fails. Frame processing runs in libuv fast-event callbacks (pure string work
--- + socket writes only); handlers that touch the Neovim API must schedule.
---@param opts? harnt.ws.ServerOpts
---@return harnt.ws.Server? server, string? err
function M.server(opts)
  opts = opts or {}
  local uv = vim.uv
  local tcp = assert(uv.new_tcp())

  local bound, berr = pcall(function()
    assert(tcp:bind(opts.host or "127.0.0.1", opts.port or 0))
  end)
  if not bound then
    pcall(function()
      tcp:close()
    end)
    return nil, tostring(berr)
  end

  local sockets = {}

  tcp:listen(128, function(lerr)
    if lerr then
      return
    end
    local sock = assert(uv.new_tcp())
    tcp:accept(sock)
    sockets[sock] = true

    ---@type harnt.ws.Connection
    local conn
    conn = M.connection({
      authenticate = opts.authenticate,
      on_write = function(bytes)
        if not sock:is_closing() then
          sock:write(bytes)
        end
      end,
      on_open = function()
        if opts.on_open then
          opts.on_open(conn)
        end
      end,
      on_message = function(payload)
        if opts.on_message then
          opts.on_message(conn, payload)
        end
      end,
      on_close = function()
        if opts.on_close then
          opts.on_close(conn)
        end
        if not sock:is_closing() then
          sock:close()
        end
        sockets[sock] = nil
      end,
    })

    sock:read_start(function(rerr, chunk)
      if rerr or not chunk then
        conn:close()
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
