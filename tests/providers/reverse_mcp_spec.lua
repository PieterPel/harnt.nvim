---@diagnostic disable: undefined-field, need-check-nil
-- (luassert extends `assert`; its narrowing is invisible to emmylua)

local reverse_mcp = require("harnt.providers.reverse_mcp")
local mcp = require("harnt.transport.mcp")
local ws = require("harnt.transport.ws")
local jsonrpc = require("harnt.transport.jsonrpc")
local bit = require("bit")

local HANDSHAKE = "GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
  .. "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n\r\n"

--- Encode a masked client->server text frame (browsers/agents must mask).
---@param payload string
local function client_frame(payload)
  local key = { 0x21, 0x43, 0x65, 0x87 }
  local masked = {}
  for i = 1, #payload do
    masked[i] = string.char(bit.bxor(payload:byte(i), key[(i - 1) % 4 + 1] or 0))
  end
  local len = #payload
  local header
  if len < 126 then
    header = string.char(0x81, 0x80 + len)
  else
    header = string.char(0x81, 0x80 + 126, math.floor(len / 256), len % 256)
  end
  return header .. string.char(key[1], key[2], key[3], key[4]) .. table.concat(masked)
end

describe("reverse_mcp.start", function()
  it("advertises discovery info with a port and auth token", function()
    local written
    local session = reverse_mcp.start({
      name = "test",
      port = 0,
      discovery = {
        write = function(info)
          written = info
        end,
        remove = function() end,
      },
      tools = function()
        return {}
      end,
    })

    assert.is_table(written)
    assert.is_true(written.port > 0)
    assert.is_true(#written.auth_token > 0)
    assert.equals(written.port, session.info.port)

    session:stop()
  end)

  it("removes the discovery entry and emits session.completed on stop", function()
    local removed = false
    local completed = false
    local session = reverse_mcp.start({
      name = "test",
      port = 0,
      discovery = {
        write = function() end,
        remove = function()
          removed = true
        end,
      },
      tools = function()
        return {}
      end,
    })
    session:on("session.completed", function()
      completed = true
    end)

    session:stop()
    assert.is_true(removed)
    assert.is_true(completed)
  end)

  it("serves MCP over a real websocket: initialize then a tool call", function()
    local session = reverse_mcp.start({
      name = "test",
      port = 0,
      discovery = { write = function() end, remove = function() end },
      tools = function()
        return {
          {
            name = "ping",
            description = "ping",
            inputSchema = {},
            handler = function(_args, respond)
              respond(mcp.content("pong"))
            end,
          },
        }
      end,
    })

    local responses = {}
    local buf, upgraded = "", false
    local client = vim.uv.new_tcp()
    client:connect("127.0.0.1", session.info.port, function()
      client:write(HANDSHAKE)
    end)
    client:read_start(function(_err, chunk)
      if not chunk then
        return
      end
      buf = buf .. chunk
      if not upgraded then
        local e = buf:find("\r\n\r\n", 1, true)
        if not e then
          return
        end
        upgraded = true
        buf = buf:sub(e + 4)
        client:write(client_frame(jsonrpc.encode({
          jsonrpc = "2.0",
          id = 1,
          method = "initialize",
          params = {},
        })))
      end
      while true do
        local frame, consumed = ws.decode_frame(buf)
        if not frame or not consumed then
          break
        end
        buf = buf:sub(consumed + 1)
        if frame.opcode == ws.opcodes.text then
          local msg = jsonrpc.decode(frame.payload)
          table.insert(responses, msg)
          if msg and msg.id == 1 then
            client:write(client_frame(jsonrpc.encode({
              jsonrpc = "2.0",
              id = 2,
              method = "tools/call",
              params = { name = "ping" },
            })))
          end
        end
      end
    end)

    local ok = vim.wait(3000, function()
      for _, r in ipairs(responses) do
        if r.id == 2 then
          return true
        end
      end
      return false
    end, 10)
    pcall(function()
      client:close()
    end)
    session:stop()

    assert.is_true(ok)
    local pong
    for _, r in ipairs(responses) do
      if r.id == 2 then
        pong = r
      end
    end
    assert.equals("pong", pong.result.content[1].text)
  end)
end)
