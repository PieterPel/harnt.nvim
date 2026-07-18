--- Minimal MCP (Model Context Protocol) server over a JSON-RPC peer.
---
--- In reverse-MCP, the editor IS the MCP server: the agent connects and calls
--- our editor tools (openDiff, getDiagnostics, …). This layer speaks the MCP
--- envelope — `initialize`, `tools/list`, `tools/call` — and dispatches calls to
--- registered tool handlers. It is transport-agnostic (feed it decoded payloads
--- via a JSON-RPC peer) and provider-agnostic (tool names/schemas are supplied
--- by the provider adapter, not baked in here).

local jsonrpc = require("harnt.transport.jsonrpc")

local M = {}

M.PROTOCOL_VERSION = "2025-06-18"
M.VERSION = "0.1.0"

--- A tool the editor exposes to the agent.
---@class harnt.mcp.Tool
---@field name string
---@field description string
---@field inputSchema table JSON Schema for the tool's arguments
---@field handler fun(args: any, respond: fun(result: any, err: harnt.jsonrpc.Error?)) call `respond` with an MCP result table (may be async)

---@class harnt.mcp.ServerOpts
---@field send fun(payload: string) transport write
---@field server_info? { name: string, version: string }
---@field tools? harnt.mcp.Tool[]

---@class harnt.mcp.Server
---@field peer harnt.jsonrpc.Peer
---@field package _tools table<string, harnt.mcp.Tool>
---@field package _server_info { name: string, version: string }
local Server = {}
Server.__index = Server

--- Wrap a MCP result value into the `{ content = { … }, isError }` envelope.
---@param value any
---@param is_error boolean
---@return table
local function content(value, is_error)
  local text = type(value) == "string" and value or vim.json.encode(value)
  return { content = { { type = "text", text = text } }, isError = is_error }
end

--- Create an MCP server bound to a transport `send`.
---@param opts harnt.mcp.ServerOpts
---@return harnt.mcp.Server
function M.server(opts)
  local self = setmetatable({
    peer = jsonrpc.new({ send = opts.send }),
    _tools = {},
    _server_info = opts.server_info or { name = "harnt.nvim", version = M.VERSION },
  }, Server)

  for _, tool in ipairs(opts.tools or {}) do
    self:register(tool)
  end

  self.peer:on("initialize", function(params, respond)
    if not respond then
      return
    end
    respond({
      protocolVersion = (params and params.protocolVersion) or M.PROTOCOL_VERSION,
      capabilities = { tools = vim.empty_dict() },
      serverInfo = self._server_info,
    })
  end)

  self.peer:on("tools/list", function(_params, respond)
    if not respond then
      return
    end
    local list = {}
    for _, tool in pairs(self._tools) do
      list[#list + 1] = {
        name = tool.name,
        description = tool.description,
        inputSchema = tool.inputSchema,
      }
    end
    respond({ tools = list })
  end)

  self.peer:on("tools/call", function(params, respond)
    if not respond then
      return
    end
    local tool = params and self._tools[params.name]
    if not tool then
      respond(content(("unknown tool: %s"):format(params and tostring(params.name)), true))
      return
    end
    local ok, err = pcall(tool.handler, params.arguments or {}, respond)
    if not ok then
      respond(content(("tool error: %s"):format(tostring(err)), true))
    end
  end)

  return self
end

--- Register (or replace) a tool.
---@param tool harnt.mcp.Tool
function Server:register(tool)
  self._tools[tool.name] = tool
end

--- Names of the registered tools.
---@return string[]
function Server:tool_names()
  local names = vim.tbl_keys(self._tools)
  table.sort(names)
  return names
end

--- Feed a raw inbound payload (from the transport).
---@param payload string
---@return string? err
function Server:feed(payload)
  return self.peer:feed(payload)
end

--- Send a server-initiated notification to the agent (e.g. a context update).
---@param method string
---@param params? any
function Server:notify(method, params)
  self.peer:notify(method, params)
end

--- Wrap a value into the MCP `content` result envelope (helper for tools).
---@param value any
---@param is_error? boolean
---@return table
function M.content(value, is_error)
  return content(value, is_error or false)
end

return M
