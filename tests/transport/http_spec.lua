---@diagnostic disable: undefined-field, need-check-nil
-- luassert narrowing is invisible to emmylua.

local http = require("harnt.transport.http")

describe("http.connection", function()
  it("parses a request and writes the handler's response", function()
    ---@type string
    local written
    ---@type harnt.http.Request
    local got
    local conn = http.connection({
      on_write = function(b)
        written = b
      end,
      on_request = function(req)
        got = req
        return { status = 200, headers = { ["content-type"] = "application/json" }, body = "{}" }
      end,
    })
    conn:feed(
      "POST /svc.Service/Method HTTP/1.1\r\n"
        .. "Content-Length: 5\r\n"
        .. "Content-Type: application/connect+proto\r\n\r\nhello"
    )
    assert.equals("POST", got.method)
    assert.equals("/svc.Service/Method", got.path)
    assert.equals("application/connect+proto", got.headers["content-type"])
    assert.equals("hello", got.body)
    assert.is_truthy(written:find("HTTP/1.1 200 OK", 1, true))
    assert.is_truthy(written:find("content-length: 2", 1, true))
    assert.is_truthy(written:find("{}", 1, true))
  end)

  it("waits for a partial body, then dispatches once complete", function()
    local n = 0
    local conn = http.connection({
      on_write = function() end,
      on_request = function()
        n = n + 1
        return { status = 200 }
      end,
    })
    conn:feed("POST /x HTTP/1.1\r\nContent-Length: 4\r\n\r\nab")
    assert.equals(0, n)
    conn:feed("cd")
    assert.equals(1, n)
  end)

  it("handles keep-alive: two requests in one stream", function()
    local paths = {}
    local conn = http.connection({
      on_write = function() end,
      on_request = function(req)
        paths[#paths + 1] = req.path
        return { status = 200 }
      end,
    })
    conn:feed("GET /a HTTP/1.1\r\n\r\nGET /b HTTP/1.1\r\n\r\n")
    assert.same({ "/a", "/b" }, paths)
  end)
end)

describe("http.server", function()
  it("serves a request over a real loopback socket", function()
    local server = assert(http.server({
      on_request = function(req)
        return { status = 200, body = "pong:" .. req.path }
      end,
    }))
    assert.is_true(server.port > 0)

    ---@type string
    local resp
    local client = assert(vim.uv.new_tcp())
    client:connect("127.0.0.1", server.port, function()
      client:write("GET /ping HTTP/1.1\r\nContent-Length: 0\r\n\r\n")
      client:read_start(function(_err, chunk)
        if chunk then
          resp = (resp or "") .. chunk
        end
      end)
    end)

    vim.wait(2000, function()
      return resp ~= nil and resp:find("pong", 1, true) ~= nil
    end, 20)
    pcall(function()
      client:close()
    end)
    server.close()

    assert.is_truthy(resp:find("pong:/ping", 1, true))
  end)
end)
