---@diagnostic disable: undefined-field, need-check-nil, param-type-mismatch
-- luassert narrowing is invisible to emmylua; deep protobuf decoding returns optionals.

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

  describe("oauth", function()
    it("oauth_token() returns nil or a token table", function()
      local t = antigravity.oauth_token()
      assert.is_true(t == nil or (type(t) == "table" and type(t.access_token) == "string"))
    end)

    it("oauth_state_response builds the exact structure that authed the real LS", function()
      local resp = antigravity.oauth_state_response({
        access_token = "AT",
        token_type = "Bearer",
        refresh_token = "RT",
      })
      -- SubscribeResponse { initial_state = field 1 }
      local initial_state = pb.field(pb.decode(resp), 1).bytes
      -- initial_state has repeated rows (field 1)
      local rows = {}
      for _, f in ipairs(pb.decode(initial_state)) do
        if f.no == 1 then
          rows[#rows + 1] = f.bytes
        end
      end
      assert.equals(2, #rows)

      local function key_of(row)
        return pb.field(pb.decode(row), 1).bytes
      end
      local function payload_of(row)
        return pb.field(pb.decode(pb.field(pb.decode(row), 2).bytes), 1).bytes
      end
      local auth_payload, token_payload
      for _, row in ipairs(rows) do
        local k = key_of(row)
        if k == "authStateWithContextSentinelKey" then
          auth_payload = payload_of(row)
        elseif k == "oauthTokenInfoSentinelKey" then
          token_payload = payload_of(row)
        end
      end
      -- auth row: plain JSON, signed in
      assert.equals("signedIn", vim.json.decode(auth_payload).state)
      -- token row: base64(protobuf OAuthTokenInfo{ access_token=1, token_type=2 })
      local proto = pb.decode(vim.base64.decode(token_payload))
      assert.equals("AT", pb.field(proto, 1).bytes)
      assert.equals("Bearer", pb.field(proto, 2).bytes)
      assert.equals("RT", pb.field(proto, 3).bytes)
    end)
  end)
end)
