---@diagnostic disable: undefined-field, need-check-nil
-- (luassert extends `assert`; its narrowing is invisible to emmylua)

local ws = require("harnt.transport.ws")

describe("ws.sha1_hex", function()
  it("matches known SHA-1 test vectors", function()
    assert.equals("da39a3ee5e6b4b0d3255bfef95601890afd80709", ws.sha1_hex(""))
    assert.equals("a9993e364706816aba3e25717850c26c9cd0d89d", ws.sha1_hex("abc"))
    assert.equals(
      "2fd4e1c67a2d28fced849ee1bb76e7391b93eb12",
      ws.sha1_hex("The quick brown fox jumps over the lazy dog")
    )
  end)
end)

describe("ws.accept_key", function()
  it("computes the RFC 6455 example accept value", function()
    -- RFC 6455 §1.3
    assert.equals("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", ws.accept_key("dGhlIHNhbXBsZSBub25jZQ=="))
  end)
end)

describe("ws.encode_frame", function()
  it("encodes a short unmasked text frame", function()
    local frame = ws.encode_frame("Hi")
    assert.equals(string.char(0x81, 0x02) .. "Hi", frame)
  end)

  it("uses a 2-byte extended length for payloads >= 126", function()
    local payload = string.rep("x", 200)
    local frame = ws.encode_frame(payload)
    assert.equals(0x81, frame:byte(1))
    assert.equals(126, frame:byte(2))
    assert.equals(0x00, frame:byte(3))
    assert.equals(200, frame:byte(4))
    assert.equals(payload, frame:sub(5))
  end)

  it("uses an 8-byte extended length for payloads > 65535", function()
    local payload = string.rep("y", 70000)
    local frame = ws.encode_frame(payload)
    assert.equals(127, frame:byte(2))
    -- 70000 = 0x00011170 -> low bytes at positions 9 and 10
    assert.equals(payload, frame:sub(11))
  end)

  it("honors opcode and fin", function()
    local frame = ws.encode_frame("", ws.opcodes.close, true)
    assert.equals(0x88, frame:byte(1))
  end)
end)

describe("ws.decode_frame", function()
  it("round-trips a frame produced by encode_frame", function()
    local frame, consumed = ws.decode_frame(ws.encode_frame("hello world"))
    assert.is_table(frame)
    assert.equals(ws.opcodes.text, frame.opcode)
    assert.is_true(frame.fin)
    assert.equals("hello world", frame.payload)
    assert.equals(13, consumed)
  end)

  it("unmasks a masked client frame (RFC 6455 §5.7 example)", function()
    local masked = string.char(0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58)
    local frame = ws.decode_frame(masked)
    assert.is_table(frame)
    assert.equals("Hello", frame.payload)
  end)

  it("returns nil for an incomplete frame", function()
    assert.is_nil(ws.decode_frame(""))
    assert.is_nil(ws.decode_frame(string.char(0x81))) -- header only
    assert.is_nil(ws.decode_frame(string.char(0x81, 0x05, 0x48))) -- says 5 bytes, has 1
  end)

  it("reports bytes consumed so a buffer can hold trailing data", function()
    local two = ws.encode_frame("aa") .. ws.encode_frame("bb")
    local frame, consumed = ws.decode_frame(two)
    assert.equals("aa", frame.payload)
    local frame2 = ws.decode_frame(two:sub(consumed + 1))
    assert.equals("bb", frame2.payload)
  end)
end)
