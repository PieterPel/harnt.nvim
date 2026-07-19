--- Connect protocol framing (connectrpc.com) — the streaming envelope.
---
--- Connect streaming RPCs frame each message as `[1 flag byte][4-byte BE length]
--- [payload]`. The final frame of a stream sets flag bit 0x02 ("end of stream")
--- and its payload is a small JSON object (`{}` on success, or `{error, metadata}`).
--- This is exactly what Antigravity's exa language server sends/expects on its
--- `ExtensionServerService` streaming methods (verified: its
--- `SubscribeToUnifiedStateSyncTopic` requests arrive as `00 00000016 <protobuf>`).
---
--- Pure byte work; the protobuf payloads themselves are `transport/protobuf`, and
--- the HTTP/chunked transport is `transport/http`.

local M = {}

--- End-of-stream flag bit (connect spec §"Streaming RPCs").
M.FLAG_END_STREAM = 0x02

--- 4-byte big-endian encoding of a length (< 2^32).
---@param n integer
---@return string
local function be32(n)
  return string.char(
    math.floor(n / 0x1000000) % 256,
    math.floor(n / 0x10000) % 256,
    math.floor(n / 0x100) % 256,
    n % 256
  )
end
M.be32 = be32

--- Decode a 4-byte big-endian length at 1-based `i`.
---@param s string
---@param i integer
---@return integer
local function read_be32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return a * 0x1000000 + b * 0x10000 + c * 0x100 + d
end
M.read_be32 = read_be32

--- Encode one enveloped frame: `[flag][BE32 len][payload]`.
---@param payload string
---@param flag? integer defaults to 0
---@return string
function M.encode(payload, flag)
  return string.char(flag or 0) .. be32(#payload) .. payload
end

--- A decoded envelope frame.
---@class harnt.connect.Frame
---@field flag integer
---@field payload string
---@field size integer total bytes consumed (5 + payload length)

--- Decode the first enveloped frame at the front of `body`. Returns nil if a full
--- frame (5-byte header + declared payload) isn't present yet.
---@param body string
---@return harnt.connect.Frame?
function M.decode(body)
  if #body < 5 then
    return nil
  end
  local flag = body:byte(1)
  local len = read_be32(body, 2)
  if #body < 5 + len then
    return nil
  end
  return { flag = flag, payload = body:sub(6, 5 + len), size = 5 + len }
end

--- The end-of-stream frame. `err` (optional) becomes a Connect error object;
--- success is an empty object.
---@param err? { code: string, message: string }
---@return string
function M.end_of_stream(err)
  local obj = err and { error = err } or vim.empty_dict()
  return M.encode(vim.json.encode(obj), M.FLAG_END_STREAM)
end

return M
