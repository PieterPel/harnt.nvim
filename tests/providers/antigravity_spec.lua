---@diagnostic disable: undefined-field, need-check-nil
-- luassert narrowing is invisible to emmylua.

local antigravity = require("harnt.providers.antigravity")
local pb = require("harnt.transport.protobuf")

describe("antigravity provider", function()
  it("detect() returns a boolean", function()
    assert.is_boolean(antigravity.detect())
  end)

  it("find_ls() returns a string path or nil", function()
    local ls = antigravity.find_ls()
    assert.is_true(ls == nil or type(ls) == "string")
  end)

  describe("metadata_frame", function()
    it("encodes the boot Metadata with the verified field numbers", function()
      local frame = antigravity.metadata_frame({
        api_key = "tok-123",
        device_fingerprint = "fp-456",
        ide_version = "0.11.0",
        extension_path = "/x",
      })
      local got = {}
      for _, f in ipairs(pb.decode(frame)) do
        got[f.no] = f.bytes ~= nil and f.bytes or f.varint
      end
      assert.equals("Neovim", got[1]) -- ide_name
      assert.equals("tok-123", got[3]) -- api_key
      assert.equals("en", got[4]) -- locale
      assert.equals(1, got[6]) -- disable_telemetry
      assert.equals("0.11.0", got[7]) -- ide_version
      assert.equals("harnt", got[12]) -- extension_name
      assert.equals("/x", got[17]) -- extension_path
      assert.equals("fp-456", got[24]) -- device_fingerprint
    end)

    it("defaults api_key to empty and still produces a decodable frame", function()
      local frame = antigravity.metadata_frame()
      local decoded = pb.decode(frame)
      assert.is_not_nil(pb.field(decoded, 1)) -- ide_name present
      assert.equals("harnt", pb.field(decoded, 12).bytes) -- extension_name
    end)
  end)
end)
