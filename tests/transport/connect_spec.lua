---@diagnostic disable: undefined-field, need-check-nil
-- luassert narrowing is invisible to emmylua.

local connect = require("harnt.transport.connect")
local pb = require("harnt.transport.protobuf")

local function from_hex(h)
  return (
    h:gsub("%x%x", function(byte)
      return string.char(tonumber(byte, 16) --[[@as integer]])
    end)
  )
end

describe("connect envelope", function()
  it("round-trips a frame", function()
    local frame = connect.encode("hello")
    local dec = connect.decode(frame)
    assert.equals(0, dec.flag)
    assert.equals("hello", dec.payload)
    assert.equals(5 + 5, dec.size)
  end)

  it("returns nil for an incomplete frame", function()
    assert.is_nil(connect.decode("\0\0\0")) -- shorter than the 5-byte header
    assert.is_nil(connect.decode(connect.encode("abcdef"):sub(1, 8))) -- header ok, payload short
  end)

  it("decodes the REAL captured SubscribeToUnifiedStateSyncTopic frame", function()
    -- Exact bytes the real language server sent (see ANTIGRAVITY.md capture):
    -- flag 00, BE32 len 0x16 (22), then protobuf { field1 = "uss-agentPreferences" }.
    local body = from_hex("00000000160a147573732d6167656e74507265666572656e636573")
    local frame = connect.decode(body)
    assert.equals(0, frame.flag)
    assert.equals(22, #frame.payload)
    -- and our protobuf codec reads the topic out of the payload
    local topic = pb.field(pb.decode(frame.payload), 1)
    assert.equals("uss-agentPreferences", topic.bytes)
  end)

  it("end_of_stream sets the end-stream flag with a JSON payload", function()
    local frame = connect.decode(connect.end_of_stream())
    assert.equals(connect.FLAG_END_STREAM, frame.flag)
    assert.equals("{}", frame.payload)
  end)

  it("end_of_stream carries an error object when given one", function()
    local frame = connect.decode(connect.end_of_stream({ code = "unknown", message = "boom" }))
    assert.equals(connect.FLAG_END_STREAM, frame.flag)
    local obj = vim.json.decode(frame.payload)
    assert.equals("unknown", obj.error.code)
    assert.equals("boom", obj.error.message)
  end)
end)
