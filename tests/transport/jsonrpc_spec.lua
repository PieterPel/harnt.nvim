---@diagnostic disable: undefined-field
-- (luassert extends `assert` with is_*/same/... which emmylua can't see)

local jsonrpc = require("harnt.transport.jsonrpc")

--- Build a peer plus a `sent` list that captures every decoded outbound payload,
--- so assertions read structured tables instead of JSON strings.
local function peer_with_capture()
  local sent = {}
  local peer = jsonrpc.new({
    send = function(payload)
      local decoded = jsonrpc.decode(payload)
      table.insert(sent, decoded)
    end,
  })
  return peer, sent
end

describe("jsonrpc.encode/decode", function()
  it("round-trips an object", function()
    local encoded = jsonrpc.encode({ jsonrpc = "2.0", method = "ping", params = { 1, 2 } })
    assert.is_string(encoded)
    local decoded = jsonrpc.decode(encoded)
    assert.same({ jsonrpc = "2.0", method = "ping", params = { 1, 2 } }, decoded)
  end)

  it("returns nil + error on malformed JSON", function()
    local decoded, err = jsonrpc.decode("{ not json ")
    assert.is_nil(decoded)
    assert.is_string(err)
  end)

  it("rejects non-object JSON", function()
    local decoded, err = jsonrpc.decode("42")
    assert.is_nil(decoded)
    assert.is_string(err)
  end)
end)

describe("jsonrpc.Peer requests", function()
  it("sends a well-formed request with an incrementing id", function()
    local peer, sent = peer_with_capture()
    local id1 = peer:request("a", { x = 1 })
    local id2 = peer:request("b")
    assert.equals(1, id1)
    assert.equals(2, id2)
    assert.same({ jsonrpc = "2.0", id = 1, method = "a", params = { x = 1 } }, sent[1])
    assert.equals("b", sent[2].method)
    assert.is_nil(sent[2].params)
  end)

  it("invokes the callback with the result when the response arrives", function()
    local peer, _ = peer_with_capture()
    local got
    local id = peer:request("sum", { 1, 2 }, function(err, result)
      assert.is_nil(err)
      got = result
    end)
    assert.equals(1, peer:pending_count())
    peer:route({ jsonrpc = "2.0", id = id, result = 3 })
    assert.equals(3, got)
    assert.equals(0, peer:pending_count())
  end)

  it("invokes the callback with the error object on an error response", function()
    local peer, _ = peer_with_capture()
    local got_err
    local id = peer:request("boom", nil, function(err)
      got_err = err
    end)
    peer:route({ jsonrpc = "2.0", id = id, error = { code = -32000, message = "nope" } })
    assert.same({ code = -32000, message = "nope" }, got_err)
  end)

  it("ignores a response for an unknown id", function()
    local peer, _ = peer_with_capture()
    assert.has_no.errors(function()
      peer:route({ jsonrpc = "2.0", id = 999, result = true })
    end)
  end)

  it("only fires a callback once even if the response is delivered twice", function()
    local peer, _ = peer_with_capture()
    local calls = 0
    local id = peer:request("once", nil, function()
      calls = calls + 1
    end)
    peer:route({ jsonrpc = "2.0", id = id, result = 1 })
    peer:route({ jsonrpc = "2.0", id = id, result = 1 })
    assert.equals(1, calls)
  end)
end)

describe("jsonrpc.Peer notifications", function()
  it("sends a notification with no id", function()
    local peer, sent = peer_with_capture()
    peer:notify("changed", { file = "a.lua" })
    assert.is_nil(sent[1].id)
    assert.equals("changed", sent[1].method)
    assert.equals(0, peer:pending_count())
  end)

  it("dispatches inbound notifications to a handler with no respond fn", function()
    local peer, _ = peer_with_capture()
    local seen
    peer:on("selection", function(params, respond)
      seen = params
      assert.is_nil(respond)
    end)
    peer:route({ jsonrpc = "2.0", method = "selection", params = { line = 5 } })
    assert.same({ line = 5 }, seen)
  end)

  it("silently drops an inbound notification with no handler", function()
    local peer, _ = peer_with_capture()
    assert.has_no.errors(function()
      peer:route({ jsonrpc = "2.0", method = "unknown", params = {} })
    end)
  end)
end)

describe("jsonrpc.Peer inbound requests", function()
  it("responds with the handler's result, echoing the id", function()
    local peer, sent = peer_with_capture()
    peer:on("openDiff", function(params, respond)
      assert.is_function(respond)
      respond({ opened = params.path })
    end)
    peer:route({ jsonrpc = "2.0", id = 7, method = "openDiff", params = { path = "x.lua" } })
    assert.same({ jsonrpc = "2.0", id = 7, result = { opened = "x.lua" } }, sent[1])
  end)

  it("lets the handler respond with an error", function()
    local peer, sent = peer_with_capture()
    peer:on("risky", function(_, respond)
      respond(nil, { code = -32000, message = "denied" })
    end)
    peer:route({ jsonrpc = "2.0", id = 8, method = "risky" })
    assert.same({ jsonrpc = "2.0", id = 8, error = { code = -32000, message = "denied" } }, sent[1])
  end)

  it("replies method_not_found when no handler is registered", function()
    local peer, sent = peer_with_capture()
    peer:route({ jsonrpc = "2.0", id = 9, method = "ghost" })
    assert.equals(9, sent[1].id)
    assert.equals(jsonrpc.errors.method_not_found, sent[1].error.code)
  end)

  it("ignores a second respond() call from a handler", function()
    local peer, sent = peer_with_capture()
    peer:on("double", function(_, respond)
      respond(1)
      respond(2)
    end)
    peer:route({ jsonrpc = "2.0", id = 10, method = "double" })
    assert.equals(1, #sent)
    assert.equals(1, sent[1].result)
  end)
end)

describe("jsonrpc.Peer:feed", function()
  it("decodes and routes a raw payload string", function()
    local peer, _ = peer_with_capture()
    local got
    peer:on("hi", function(params)
      got = params
    end)
    local err =
      peer:feed(jsonrpc.encode({ jsonrpc = "2.0", method = "hi", params = { ok = true } }))
    assert.is_nil(err)
    assert.same({ ok = true }, got)
  end)

  it("returns an error for a malformed payload and does not raise", function()
    local peer, _ = peer_with_capture()
    local err = peer:feed("}{")
    assert.is_string(err)
  end)
end)
