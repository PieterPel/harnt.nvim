--- Minimal protobuf wire codec (pure Lua).
---
--- Just enough of the protobuf wire format for the messages harnt exchanges with
--- agents that speak protobuf — the Antigravity language-server stdin `Metadata`
--- frame and its `connect+proto` ExtensionServer channel. This is NOT a full
--- protobuf implementation: no reflection, no `.proto` schema, no 64-bit/float
--- niceties. Callers pass field numbers + wire kinds explicitly (we read those
--- off the LS's own descriptors). The wire format itself is tiny — tag =
--- `(field << 3) | wire_type`, then a varint / length-delimited payload — which
--- is exactly why hosting a proto channel by hand is tractable.
---
--- Uses plain number arithmetic (no bit ops): field tags, lengths, and the ints
--- we handle are all well within 2^53.
---
--- NOTE / escape hatch: if this hand-rolled codec turns out buggy or a
--- maintenance burden as the Antigravity ExtensionServer surface grows (many
--- nested messages), swap in **starwing/lua-protobuf** (a mature C library) for
--- the Antigravity provider *only* — loaded from the exa `FileDescriptorSet`
--- extracted from the language-server binary (`pb.load(descriptor)` then
--- encode/decode by message name), kept an *optional* dependency so the core and
--- the Claude/Codex providers stay pure-Lua / zero-install (docs/BET.md #4). The
--- Connect HTTP/framing layer stays ours either way; only the message codec swaps.

local M = {}

--- Wire types (protobuf spec §5).
M.VARINT = 0
M.I64 = 1
M.LEN = 2
M.I32 = 5

--- Encode an unsigned integer as a base-128 varint.
---@param n integer
---@return string
local function encode_varint(n)
  local bytes = {}
  n = math.floor(n)
  repeat
    local b = n % 128
    n = math.floor(n / 128)
    if n > 0 then
      b = b + 128
    end
    bytes[#bytes + 1] = string.char(b)
  until n == 0
  return table.concat(bytes)
end
M.encode_varint = encode_varint

--- Decode a varint at 1-based `i`. Returns the value and the next index.
---@param s string
---@param i integer
---@return integer value, integer next
local function decode_varint(s, i)
  local result, mult = 0, 1
  while true do
    local b = s:byte(i)
    i = i + 1
    result = result + (b % 128) * mult
    if b < 128 then
      break
    end
    mult = mult * 128
  end
  return result, i
end
M.decode_varint = decode_varint

--- A field to encode. Exactly one payload key is set:
--- `str`/`bytes`/`msg` (length-delimited), `bool`/`varint` (varint).
---@class harnt.pb.Field
---@field no integer field number
---@field str? string
---@field bytes? string
---@field msg? string an already-encoded embedded message
---@field bool? boolean
---@field varint? integer

--- Encode a message from an ordered list of fields.
---@param fields harnt.pb.Field[]
---@return string
function M.encode(fields)
  local out = {}
  for _, f in ipairs(fields) do
    local len_payload = f.str or f.bytes or f.msg
    if len_payload ~= nil then
      out[#out + 1] = encode_varint(f.no * 8 + M.LEN)
      out[#out + 1] = encode_varint(#len_payload)
      out[#out + 1] = len_payload
    elseif f.bool ~= nil then
      out[#out + 1] = encode_varint(f.no * 8 + M.VARINT)
      out[#out + 1] = encode_varint(f.bool and 1 or 0)
    elseif f.varint ~= nil then
      out[#out + 1] = encode_varint(f.no * 8 + M.VARINT)
      out[#out + 1] = encode_varint(f.varint)
    end
  end
  return table.concat(out)
end

--- A decoded field.
---@class harnt.pb.Decoded
---@field no integer
---@field wire integer
---@field varint? integer set for VARINT fields
---@field bytes? string set for LEN / I64 / I32 fields (raw)

--- Decode a message into a flat, ordered list of fields (repeats preserved in
--- order). Callers interpret by field number + wire type. Unknown wire types
--- stop decoding (we only handle what we produce/consume).
---@param s string
---@return harnt.pb.Decoded[]
function M.decode(s)
  local fields, i, n = {}, 1, #s
  while i <= n do
    local key
    key, i = decode_varint(s, i)
    local no = math.floor(key / 8)
    local wire = key % 8
    local f = { no = no, wire = wire }
    if wire == M.VARINT then
      f.varint, i = decode_varint(s, i)
    elseif wire == M.LEN then
      local len
      len, i = decode_varint(s, i)
      f.bytes = s:sub(i, i + len - 1)
      i = i + len
    elseif wire == M.I64 then
      f.bytes = s:sub(i, i + 7)
      i = i + 8
    elseif wire == M.I32 then
      f.bytes = s:sub(i, i + 3)
      i = i + 4
    else
      break
    end
    fields[#fields + 1] = f
  end
  return fields
end

--- Find the first field with number `no` in a decoded list.
---@param decoded harnt.pb.Decoded[]
---@param no integer
---@return harnt.pb.Decoded?
function M.field(decoded, no)
  for _, f in ipairs(decoded) do
    if f.no == no then
      return f
    end
  end
  return nil
end

return M
