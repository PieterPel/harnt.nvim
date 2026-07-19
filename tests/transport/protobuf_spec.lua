---@diagnostic disable: undefined-field, need-check-nil
-- luassert narrowing is invisible to emmylua.

local pb = require("harnt.transport.protobuf")

-- \xHH escapes aren't valid Lua 5.1; build expected bytes from char codes.
local function b(...)
  return string.char(...)
end

describe("protobuf.varint", function()
  it("encodes single-byte and multi-byte varints", function()
    assert.equals(b(0), pb.encode_varint(0))
    assert.equals(b(1), pb.encode_varint(1))
    assert.equals(b(127), pb.encode_varint(127))
    assert.equals(b(172, 2), pb.encode_varint(300)) -- classic protobuf example: 0xac 0x02
  end)

  it("round-trips varints", function()
    for _, n in ipairs({ 0, 1, 127, 128, 300, 16384, 1000000 }) do
      local v, i = pb.decode_varint(pb.encode_varint(n), 1)
      assert.equals(n, v)
      assert.equals(#pb.encode_varint(n) + 1, i)
    end
  end)
end)

describe("protobuf.encode", function()
  it("encodes a length-delimited string field with the right tag", function()
    -- field 1, wire 2 => tag 10; len 6; "Neovim"
    assert.equals(b(10, 6) .. "Neovim", pb.encode({ { no = 1, str = "Neovim" } }))
  end)

  it("encodes a bool as a varint field", function()
    -- field 6, wire 0 => tag 48; value 1/0
    assert.equals(b(48, 1), pb.encode({ { no = 6, bool = true } }))
    assert.equals(b(48, 0), pb.encode({ { no = 6, bool = false } }))
  end)

  it("encodes a varint field", function()
    -- field 3, wire 0 => tag 24; varint 300
    assert.equals(b(24, 172, 2), pb.encode({ { no = 3, varint = 300 } }))
  end)

  it("encodes an embedded message field (already-encoded bytes)", function()
    local inner = pb.encode({ { no = 1, str = "x" } })
    -- field 2, wire 2 => tag 18; len; inner
    assert.equals(b(18) .. b(#inner) .. inner, pb.encode({ { no = 2, msg = inner } }))
  end)
end)

describe("protobuf round-trip (the real Antigravity Metadata frame)", function()
  it("builds and reads back the LS boot Metadata message", function()
    -- The exact shape that boots the real language_server (field numbers decoded
    -- from its descriptors): ide_name=1, api_key=3, locale=4, disable_telemetry=6,
    -- ide_version=7, extension_name=12, extension_path=17, device_fingerprint=24,
    -- user_tier_id=29.
    local frame = pb.encode({
      { no = 1, str = "Neovim" },
      { no = 7, str = "0.11.0" },
      { no = 12, str = "harnt" },
      { no = 17, str = "/tmp/harnt" },
      { no = 4, str = "en" },
      { no = 24, str = "install-123" },
      { no = 3, str = "the-oauth-token" },
      { no = 6, bool = true },
      { no = 29, str = "" },
    })

    local got = {}
    for _, f in ipairs(pb.decode(frame)) do
      got[f.no] = f.bytes ~= nil and f.bytes or f.varint
    end
    assert.equals("Neovim", got[1])
    assert.equals("the-oauth-token", got[3]) -- api_key
    assert.equals("0.11.0", got[7])
    assert.equals("harnt", got[12])
    assert.equals("install-123", got[24]) -- device_fingerprint
    assert.equals(1, got[6]) -- disable_telemetry (varint 1)
    assert.equals("", got[29])
  end)

  it("pb.field finds a field by number", function()
    local frame = pb.encode({ { no = 3, str = "tok" }, { no = 6, bool = true } })
    local decoded = pb.decode(frame)
    assert.equals("tok", pb.field(decoded, 3).bytes)
    assert.equals(1, pb.field(decoded, 6).varint)
    assert.is_nil(pb.field(decoded, 99))
  end)
end)
