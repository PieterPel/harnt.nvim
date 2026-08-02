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

local HANDSHAKE = "GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
  .. "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"
local HELLO_MASKED = string.char(0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58)

describe("ws.connection", function()
  local function make()
    local state = { writes = {}, messages = {}, opened = false, closed = false }
    local conn = ws.connection({
      on_write = function(b)
        table.insert(state.writes, b)
      end,
      on_message = function(p)
        table.insert(state.messages, p)
      end,
      on_open = function()
        state.opened = true
      end,
      on_close = function()
        state.closed = true
      end,
    })
    return conn, state
  end

  it("completes the handshake with the correct 101 response", function()
    local conn, state = make()
    conn:feed(HANDSHAKE)
    assert.is_true(state.opened)
    assert.is_truthy(state.writes[1]:find("101 Switching Protocols", 1, true))
    assert.is_truthy(state.writes[1]:find("s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", 1, true))
  end)

  it("echoes an offered Sec-WebSocket-Protocol in the 101 response", function()
    -- Claude Code sends `Sec-WebSocket-Protocol: mcp`; claude-code/2.1.220's WS
    -- client tears the socket down right after the handshake if it isn't echoed.
    local conn, state = make()
    conn:feed(
      "GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        .. "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n"
        .. "Sec-WebSocket-Protocol: mcp\r\n\r\n"
    )
    assert.is_true(state.opened)
    assert.is_truthy(state.writes[1]:find("Sec%-WebSocket%-Protocol: mcp"))
  end)

  it("omits Sec-WebSocket-Protocol when the client offers none", function()
    local conn, state = make()
    conn:feed(HANDSHAKE) -- no Sec-WebSocket-Protocol header
    assert.is_true(state.opened)
    assert.is_nil(state.writes[1]:lower():find("sec%-websocket%-protocol"))
  end)

  it("delivers a masked client message after the handshake", function()
    local conn, state = make()
    conn:feed(HANDSHAKE)
    conn:feed(HELLO_MASKED)
    assert.same({ "Hello" }, state.messages)
  end)

  it("handles a handshake split across chunks", function()
    local conn, state = make()
    conn:feed(HANDSHAKE:sub(1, 20))
    assert.is_false(state.opened)
    conn:feed(HANDSHAKE:sub(21))
    assert.is_true(state.opened)
  end)

  it("buffers a frame fed one byte at a time", function()
    local conn, state = make()
    conn:feed(HANDSHAKE)
    for i = 1, #HELLO_MASKED do
      conn:feed(HELLO_MASKED:sub(i, i))
    end
    assert.same({ "Hello" }, state.messages)
  end)

  it("replies to a ping with a pong", function()
    local conn, state = make()
    conn:feed(HANDSHAKE)
    conn:feed(string.char(0x89, 0x80, 0x00, 0x00, 0x00, 0x00)) -- masked empty ping
    local frame = ws.decode_frame(state.writes[#state.writes])
    assert.equals(ws.opcodes.pong, frame.opcode)
  end)

  it("rejects a request without a Sec-WebSocket-Key", function()
    local conn, state = make()
    conn:feed("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
    assert.is_false(state.opened)
    assert.is_true(state.closed)
    assert.is_truthy(state.writes[1]:find("400", 1, true))
  end)

  it("send() emits an unmasked text frame after open", function()
    local conn, state = make()
    conn:feed(HANDSHAKE)
    conn:send("hi there")
    local frame = ws.decode_frame(state.writes[#state.writes])
    assert.equals("hi there", frame.payload)
  end)
end)

describe("ws.server (loopback over vim.uv)", function()
  it("performs a real TCP handshake and echoes a message", function()
    local server = assert(ws.server({
      on_message = function(client, payload)
        client:send("echo:" .. payload)
      end,
    }))
    assert.is_true(server.port > 0)

    local buf, upgraded, echoed = "", false, nil
    local client = vim.uv.new_tcp()
    client:connect("127.0.0.1", server.port, function()
      client:write(HANDSHAKE)
    end)
    client:read_start(function(_err, chunk)
      if not chunk then
        return
      end
      buf = buf .. chunk
      if not upgraded then
        local e = buf:find("\r\n\r\n", 1, true)
        if e then
          upgraded = true
          buf = buf:sub(e + 4)
          client:write(HELLO_MASKED)
        end
        return
      end
      local frame = ws.decode_frame(buf)
      if frame then
        echoed = frame.payload
      end
    end)

    local ok = vim.wait(2000, function()
      return echoed ~= nil
    end, 10)
    pcall(function()
      client:close()
    end)
    server.close()

    assert.is_true(ok)
    assert.equals("echo:Hello", echoed)
  end)
end)

describe("ws.connection authentication", function()
  local function make(authenticate)
    local state = { writes = {}, opened = false, closed = false }
    local conn = ws.connection({
      authenticate = authenticate,
      on_write = function(b)
        table.insert(state.writes, b)
      end,
      on_open = function()
        state.opened = true
      end,
      on_close = function()
        state.closed = true
      end,
    })
    return conn, state
  end

  it("rejects the handshake with 401 when authenticate returns false", function()
    local conn, state = make(function()
      return false
    end)
    conn:feed(HANDSHAKE)
    assert.is_false(state.opened)
    assert.is_true(state.closed)
    assert.is_truthy(state.writes[1]:find("401", 1, true))
  end)

  it("passes lowercased headers to authenticate and opens on true", function()
    local seen
    local conn, state = make(function(headers)
      seen = headers
      return true
    end)
    conn:feed(HANDSHAKE)
    assert.is_true(state.opened)
    assert.equals("websocket", seen["upgrade"])
    assert.equals("dGhlIHNhbXBsZSBub25jZQ==", seen["sec-websocket-key"])
  end)
end)
