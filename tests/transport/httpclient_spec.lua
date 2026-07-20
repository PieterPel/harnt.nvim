---@diagnostic disable: undefined-field, need-check-nil
-- luassert narrowing is invisible to emmylua.

local httpclient = require("harnt.transport.httpclient")

describe("httpclient.parse_head", function()
  it("parses the status line and lowercases header names", function()
    local status, headers = httpclient.parse_head(
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked"
    )
    assert.equals(200, status)
    assert.equals("text/event-stream", headers["content-type"])
    assert.equals("chunked", headers["transfer-encoding"])
  end)

  it("returns status 0 for a non-HTTP head", function()
    local status = httpclient.parse_head("garbage")
    assert.equals(0, status)
  end)
end)

describe("httpclient.chunked_decoder", function()
  it("decodes chunks split across feeds and stops at the terminal chunk", function()
    local d = httpclient.chunked_decoder()
    -- "5\r\nhello\r\n" then "6\r\n world\r\n" then "0\r\n\r\n"
    assert.equals("hello", d.feed("5\r\nhello\r\n"))
    assert.equals(" world", d.feed("6\r\n world\r\n"))
    assert.equals("", d.feed("0\r\n\r\n"))
  end)

  it("retains a partial chunk until the rest arrives", function()
    local d = httpclient.chunked_decoder()
    assert.equals("", d.feed("5\r\nhel")) -- data incomplete
    assert.equals("hello", d.feed("lo\r\n"))
  end)

  it("ignores chunk extensions on the size line", function()
    local d = httpclient.chunked_decoder()
    assert.equals("ab", d.feed("2;foo=bar\r\nab\r\n"))
  end)
end)

describe("httpclient.sse_parser", function()
  it("emits one payload per event, concatenating data lines", function()
    local p = httpclient.sse_parser()
    assert.same({ '{"a":1}' }, p.feed('data: {"a":1}\n\n'))
    assert.same({ "line1\nline2" }, p.feed("data: line1\ndata: line2\n\n"))
  end)

  it("buffers a partial event until the blank-line terminator", function()
    local p = httpclient.sse_parser()
    assert.same({}, p.feed("data: partia"))
    assert.same({ "partial" }, p.feed("l\n\n"))
  end)

  it("ignores comment and non-data fields", function()
    local p = httpclient.sse_parser()
    assert.same({ "x" }, p.feed(": keepalive\nevent: foo\ndata: x\n\n"))
  end)

  it("tolerates CRLF framing", function()
    local p = httpclient.sse_parser()
    assert.same({ "y" }, p.feed("data: y\r\n\r\n"))
  end)
end)

describe("httpclient.body_reader", function()
  it("splits head from an identity (content-length) body", function()
    local status, body = 0, {}
    local r = httpclient.body_reader(function(s)
      status = s
    end, function(bytes)
      body[#body + 1] = bytes
    end)
    r.feed("HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhel")
    r.feed("lo")
    assert.equals(200, status)
    assert.equals("hello", table.concat(body))
  end)

  it("decodes a chunked body after the head", function()
    local body = {}
    local r = httpclient.body_reader(function() end, function(bytes)
      body[#body + 1] = bytes
    end)
    r.feed("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n")
    assert.equals("hello", table.concat(body))
  end)
end)

describe("httpclient over a real loopback server", function()
  local http = require("harnt.transport.http")

  it("performs a one-shot request and reads the body", function()
    local server = assert(http.server({
      on_request = function(_req)
        return { status = 200, body = '{"healthy":true}' }
      end,
    }))

    local res, done
    httpclient.request({ port = server.port, path = "/api/health" }, function(r)
      res = r
      done = true
    end)
    vim.wait(2000, function()
      return done == true
    end, 10)
    server.close()

    assert.is_table(res)
    assert.equals(200, res.status)
    assert.equals('{"healthy":true}', res.body)
  end)

  it("streams SSE events from a chunked response", function()
    -- A server that streams two SSE events then ends the body.
    local server = assert(http.server({
      on_request = function(_req)
        return {
          status = 200,
          headers = { ["content-type"] = "text/event-stream" },
          stream = function(w)
            w.write('data: {"type":"server.connected"}\n\n')
            w.write('data: {"type":"session.idle"}\n\n')
            w.finish()
          end,
        }
      end,
    }))

    local got = {}
    httpclient.stream({
      port = server.port,
      path = "/event",
      on_event = function(data)
        got[#got + 1] = data
      end,
    })
    vim.wait(2000, function()
      return #got >= 2
    end, 10)
    server.close()

    assert.equals('{"type":"server.connected"}', got[1])
    assert.equals('{"type":"session.idle"}', got[2])
  end)
end)
