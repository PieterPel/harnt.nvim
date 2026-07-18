---@diagnostic disable: undefined-field, need-check-nil
-- (luassert extends `assert`; its narrowing is invisible to emmylua)

local mcp = require("harnt.transport.mcp")
local jsonrpc = require("harnt.transport.jsonrpc")

--- Build an MCP server plus a `sent` list of decoded outbound payloads.
local function server_with_capture(tools)
  local sent = {}
  local server = mcp.server({
    send = function(payload)
      local decoded = jsonrpc.decode(payload)
      table.insert(sent, decoded)
    end,
    server_info = { name = "harnt.nvim", version = "test" },
    tools = tools,
  })
  return server, sent
end

--- Simulate the agent calling a method and return the decoded response.
local function call(server, sent, id, method, params)
  server:feed(jsonrpc.encode({ jsonrpc = "2.0", id = id, method = method, params = params }))
  return sent[#sent]
end

describe("mcp initialize", function()
  it("echoes the client protocolVersion and reports serverInfo + tools capability", function()
    local server, sent = server_with_capture()
    local resp = call(server, sent, 1, "initialize", { protocolVersion = "2025-06-18" })
    assert.equals(1, resp.id)
    assert.equals("2025-06-18", resp.result.protocolVersion)
    assert.equals("harnt.nvim", resp.result.serverInfo.name)
    assert.is_table(resp.result.capabilities.tools)
  end)

  it("falls back to a default protocol version", function()
    local server, sent = server_with_capture()
    local resp = call(server, sent, 1, "initialize", {})
    assert.equals(mcp.PROTOCOL_VERSION, resp.result.protocolVersion)
  end)
end)

describe("mcp tools/list", function()
  it("lists registered tools with name, description, inputSchema", function()
    local server, sent = server_with_capture({
      {
        name = "openDiff",
        description = "open a diff",
        inputSchema = { type = "object" },
        handler = function() end,
      },
    })
    local resp = call(server, sent, 2, "tools/list")
    assert.equals(1, #resp.result.tools)
    assert.equals("openDiff", resp.result.tools[1].name)
    assert.equals("open a diff", resp.result.tools[1].description)
    assert.same({ type = "object" }, resp.result.tools[1].inputSchema)
  end)
end)

describe("mcp tools/call", function()
  it("dispatches to the tool handler with its arguments and forwards the result", function()
    local got_args
    local server, sent = server_with_capture({
      {
        name = "echo",
        description = "",
        inputSchema = {},
        handler = function(args, respond)
          got_args = args
          respond(mcp.content("ok"))
        end,
      },
    })
    local resp = call(server, sent, 3, "tools/call", { name = "echo", arguments = { x = 1 } })
    assert.same({ x = 1 }, got_args)
    assert.equals("ok", resp.result.content[1].text)
    assert.is_false(resp.result.isError)
  end)

  it("supports an async tool that responds later", function()
    local deferred
    local server, sent = server_with_capture({
      {
        name = "slow",
        description = "",
        inputSchema = {},
        handler = function(_args, respond)
          deferred = respond
        end,
      },
    })
    server:feed(
      jsonrpc.encode({ jsonrpc = "2.0", id = 4, method = "tools/call", params = { name = "slow" } })
    )
    assert.equals(0, #sent) -- no response yet
    deferred(mcp.content("done later"))
    assert.equals("done later", sent[#sent].result.content[1].text)
  end)

  it("returns an isError result for an unknown tool", function()
    local server, sent = server_with_capture()
    local resp = call(server, sent, 5, "tools/call", { name = "ghost" })
    assert.is_true(resp.result.isError)
    assert.is_truthy(resp.result.content[1].text:find("unknown tool"))
  end)

  it("returns an isError result when a handler throws", function()
    local server, sent = server_with_capture({
      {
        name = "boom",
        description = "",
        inputSchema = {},
        handler = function()
          error("kaboom")
        end,
      },
    })
    local resp = call(server, sent, 6, "tools/call", { name = "boom" })
    assert.is_true(resp.result.isError)
    assert.is_truthy(resp.result.content[1].text:find("tool error"))
  end)
end)

describe("mcp misc", function()
  it("ignores notifications without crashing", function()
    local server, sent = server_with_capture()
    assert.has_no.errors(function()
      server:feed(jsonrpc.encode({ jsonrpc = "2.0", method = "notifications/initialized" }))
    end)
    assert.equals(0, #sent)
  end)

  it("sends server-initiated notifications", function()
    local server, sent = server_with_capture()
    server:notify("harnt/context", { file = "a.lua" })
    assert.equals("harnt/context", sent[1].method)
    assert.is_nil(sent[1].id)
  end)

  it("exposes sorted tool names", function()
    local server = server_with_capture({
      { name = "b", description = "", inputSchema = {}, handler = function() end },
      { name = "a", description = "", inputSchema = {}, handler = function() end },
    })
    assert.same({ "a", "b" }, server:tool_names())
  end)
end)
