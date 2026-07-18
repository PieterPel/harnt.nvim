--- Reverse-MCP provider base.
---
--- The shared machinery for every "editor as tool-server" agent (Claude, Codex
--- `/ide`, Gemini companion): host a local server, advertise it via a discovery
--- file with an auth token, speak MCP so the agent can call our editor tools,
--- and expose a Session. A concrete provider is a thin config table — transport,
--- discovery format, and the editor tool set — layered on top.
---
--- Only the WebSocket transport is wired here (Claude). The HTTP/SSE transport
--- (Codex/Gemini) plugs in at `config.transport` later without changing this.

local events = require("harnt.events")
local mcp = require("harnt.transport.mcp")
local ws = require("harnt.transport.ws")

local M = {}

--- Connection info advertised to the agent (written into the discovery file).
---@class harnt.reverse_mcp.Info
---@field host string
---@field port integer
---@field auth_token string
---@field pid integer

--- How a provider advertises + retracts the running server.
---@class harnt.reverse_mcp.Discovery
---@field write fun(info: harnt.reverse_mcp.Info) write the lockfile/discovery entry
---@field remove fun(info: harnt.reverse_mcp.Info) remove it on shutdown

---@class harnt.reverse_mcp.Config
---@field name string provider name
---@field host? string bind host (default 127.0.0.1)
---@field port? integer bind port (default 0 = OS-assigned)
---@field auth_header? string header the agent must send carrying the auth token
---@field discovery harnt.reverse_mcp.Discovery
---@field tools fun(ctx: harnt.SessionContext): harnt.mcp.Tool[] editor tools to expose
---@field server_info? { name: string, version: string }

--- A reverse-MCP session; `info` lets the frontend spawn the agent's CLI with
--- the right discovery env vars.
---@class harnt.reverse_mcp.Session : harnt.Session
---@field info harnt.reverse_mcp.Info

--- Generate a 32-char lowercase-hex auth token (128 bits from the OS CSPRNG when
--- available, otherwise a hashed high-resolution fallback).
---@return string
local function generate_token()
  local ok, bytes = pcall(function()
    return vim.uv.random(16)
  end)
  if ok and type(bytes) == "string" and #bytes == 16 then
    return (bytes:gsub(".", function(ch)
      return ("%02x"):format(ch:byte())
    end))
  end
  local seed = ("%d:%d:%s"):format(vim.uv.hrtime(), vim.uv.os_getpid(), tostring(os.clock()))
  return vim.fn.sha256(seed):sub(1, 32)
end

--- Start a reverse-MCP session for `config`.
---@param config harnt.reverse_mcp.Config
---@param ctx? harnt.SessionContext
---@return harnt.reverse_mcp.Session
function M.start(config, ctx)
  ctx = ctx or {}
  local bus = events.new()
  local auth_token = generate_token()

  ---@type (fun(headers: table<string, string>): boolean)?
  local authenticate
  if config.auth_header then
    local header = config.auth_header:lower()
    authenticate = function(headers)
      return headers[header] == auth_token
    end
  end

  ---@type table<harnt.ws.Connection, harnt.mcp.Server?>
  local servers = {}

  local server, err = ws.server({
    host = config.host,
    port = config.port,
    authenticate = authenticate,
    on_open = function(client)
      -- Pure setup (no Neovim API) so it's safe in the libuv callback.
      servers[client] = mcp.server({
        send = function(payload)
          client:send(payload)
        end,
        server_info = config.server_info,
        tools = config.tools(ctx),
      })
      vim.schedule(function()
        bus:emit(events.TYPES.session_started, { provider = config.name })
      end)
    end,
    on_message = function(client, payload)
      local mcp_server = servers[client]
      if mcp_server then
        -- Tool handlers touch the Neovim API; defer out of the fast callback.
        vim.schedule(function()
          mcp_server:feed(payload)
        end)
      end
    end,
    on_close = function(client)
      servers[client] = nil
    end,
  })
  assert(server, "reverse_mcp: could not start server: " .. tostring(err))

  ---@type harnt.reverse_mcp.Info
  local info = {
    host = config.host or "127.0.0.1",
    port = server.port,
    auth_token = auth_token,
    pid = vim.uv.os_getpid() --[[@as integer]],
  }
  config.discovery.write(info)

  local stopped = false

  ---@type harnt.reverse_mcp.Session
  local session = {
    info = info,
    ---@param event string
    ---@param handler harnt.events.Handler
    on = function(_self, event, handler)
      return bus:on(event, handler)
    end,
    -- The editor answers the agent via MCP tool results, so there are no
    -- outstanding server-initiated requests to respond to here.
    respond = function() end,
    interrupt = function() end,
    stop = function()
      if stopped then
        return
      end
      stopped = true
      config.discovery.remove(info)
      server.close()
      bus:emit(events.TYPES.session_completed, { provider = config.name })
    end,
  }
  return session
end

return M
