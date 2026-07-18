--- RFC-6455 WebSocket primitives + a minimal server.
---
--- Powers Claude's reverse-MCP: the editor hosts this WS server, Claude's CLI
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

return M
