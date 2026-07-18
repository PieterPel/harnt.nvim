--- JSON-RPC 2.0 message codec + peer.
---
--- Transport-agnostic: framing (Content-Length headers, WebSocket frames,
--- newline delimiting) is the transport's responsibility. A `Peer` turns method
--- calls into encoded payload strings (handed to a `send` callback) and routes
--- decoded payloads back to the right request callback or method handler.
---
--- This layer has no dependency on any agent or on `vim.uv`; it only uses
--- `vim.json`, which makes it exhaustively unit-testable against a fake `send`.

local M = {}

M.VERSION = "2.0"

--- Standard JSON-RPC 2.0 error codes.
M.errors = {
  parse_error = -32700,
  invalid_request = -32600,
  method_not_found = -32601,
  invalid_params = -32602,
  internal_error = -32603,
}

---@alias harnt.jsonrpc.Id integer|string

---@class harnt.jsonrpc.Error
---@field code integer
---@field message string
---@field data? any

---@class harnt.jsonrpc.Message
---@field jsonrpc string
---@field id? harnt.jsonrpc.Id
---@field method? string
---@field params? any
---@field result? any
---@field error? harnt.jsonrpc.Error

--- Encode any value to a JSON string.
---@param value any
---@return string
function M.encode(value)
  return vim.json.encode(value)
end

--- Decode a JSON string. Returns `nil, err` on parse failure rather than raising,
--- so a transport can drop malformed frames without crashing the peer.
---@param str string
---@return table? decoded, string? err
function M.decode(str)
  local ok, decoded = pcall(vim.json.decode, str)
  if not ok then
    return nil, tostring(decoded)
  end
  if type(decoded) ~= "table" then
    return nil, "expected a JSON object"
  end
  return decoded
end

---@alias harnt.jsonrpc.Callback fun(err: harnt.jsonrpc.Error?, result: any?)
---@alias harnt.jsonrpc.Respond fun(result: any?, err: harnt.jsonrpc.Error?)
--- A handler for an inbound method. For notifications `respond` is nil; for
--- server-initiated requests, call `respond(result)` or `respond(nil, error)`.
---@alias harnt.jsonrpc.Handler fun(params: any, respond: harnt.jsonrpc.Respond?)

---@class harnt.jsonrpc.Peer
---@field private _send fun(payload: string)
---@field private _next_id integer
---@field private _pending table<harnt.jsonrpc.Id, harnt.jsonrpc.Callback?>
---@field private _handlers table<string, harnt.jsonrpc.Handler?>
local Peer = {}
Peer.__index = Peer

--- Create a peer. `opts.send` receives fully-encoded JSON payload strings; the
--- caller's transport is responsible for framing and writing them.
---@param opts { send: fun(payload: string) }
---@return harnt.jsonrpc.Peer
function M.new(opts)
  assert(
    type(opts) == "table" and type(opts.send) == "function",
    "jsonrpc.new: opts.send must be a function"
  )
  return setmetatable({
    _send = opts.send,
    _next_id = 0,
    _pending = {},
    _handlers = {},
  }, Peer)
end

--- Send a request and register `callback` to fire when its response arrives.
---@param method string
---@param params? any
---@param callback? harnt.jsonrpc.Callback
---@return harnt.jsonrpc.Id id the request id assigned
function Peer:request(method, params, callback)
  self._next_id = self._next_id + 1
  local id = self._next_id
  if callback then
    self._pending[id] = callback
  end
  self._send(M.encode({ jsonrpc = M.VERSION, id = id, method = method, params = params }))
  return id
end

--- Send a notification (a request with no id; no response is expected).
---@param method string
---@param params? any
function Peer:notify(method, params)
  self._send(M.encode({ jsonrpc = M.VERSION, method = method, params = params }))
end

--- Register a handler for an inbound method (notification or server-initiated
--- request). Passing nil removes the handler.
---@param method string
---@param handler harnt.jsonrpc.Handler?
function Peer:on(method, handler)
  self._handlers[method] = handler
end

--- How many requests are still awaiting a response.
---@return integer
function Peer:pending_count()
  return vim.tbl_count(self._pending)
end

--- Feed a raw inbound payload string. Malformed JSON is dropped and the error
--- returned so the transport can log it.
---@param payload string
---@return string? err
function Peer:feed(payload)
  local msg, err = M.decode(payload)
  if not msg then
    return err
  end
  self:route(msg)
end

--- Route an already-decoded message to the appropriate callback/handler.
---@param msg harnt.jsonrpc.Message
function Peer:route(msg)
  if type(msg) ~= "table" then
    return
  end

  if msg.method ~= nil then
    -- Inbound request (has id) or notification (no id).
    local handler = self._handlers[msg.method]
    if msg.id ~= nil then
      self:_dispatch_request(msg, handler)
    elseif handler then
      handler(msg.params, nil)
    end
  elseif msg.id ~= nil then
    -- Response to one of our requests.
    local cb = self._pending[msg.id]
    if cb then
      self._pending[msg.id] = nil
      if msg.error ~= nil then
        cb(msg.error, nil)
      else
        cb(nil, msg.result)
      end
    end
  end
end

---@private
---@param msg harnt.jsonrpc.Message
---@param handler harnt.jsonrpc.Handler?
function Peer:_dispatch_request(msg, handler)
  local responded = false
  ---@param result? any
  ---@param err? harnt.jsonrpc.Error
  local function respond(result, err)
    if responded then
      return
    end
    responded = true
    local resp = { jsonrpc = M.VERSION, id = msg.id }
    if err ~= nil then
      resp.error = err
    else
      resp.result = result
    end
    self._send(M.encode(resp))
  end

  if handler then
    handler(msg.params, respond)
  else
    respond(nil, {
      code = M.errors.method_not_found,
      message = "method not found: " .. tostring(msg.method),
    })
  end
end

return M
