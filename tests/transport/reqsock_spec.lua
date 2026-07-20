---@diagnostic disable: need-check-nil, undefined-field

local reqsock = require("harnt.transport.reqsock")

--- A short socket path well under the 104-byte sun_path limit.
local function sock_path()
  return ("/tmp/harnt-reqsock-%d.sock"):format(vim.uv.hrtime() % 1e9)
end

describe("reqsock", function()
  it("answers one JSON request with one JSON response, then closes", function()
    local path = sock_path()
    local server = assert(reqsock.serve({
      path = path,
      on_request = function(req, respond)
        respond({ echo = req.hello, ok = true })
      end,
    }))

    local got, closed
    local client = assert(vim.uv.new_pipe(false))
    client:connect(path, function(err)
      assert(not err, err)
      client:write(vim.json.encode({ hello = "world" }))
      local buf = ""
      client:read_start(function(_rerr, chunk)
        if chunk then
          buf = buf .. chunk
          local ok, value = pcall(vim.json.decode, (buf:gsub("%s+$", "")))
          if ok then
            got = value
          end
        else
          closed = true -- server closed the connection after replying
        end
      end)
    end)

    vim.wait(3000, function()
      return got ~= nil and closed
    end, 20)
    server.close()

    assert.equals("world", got.echo)
    assert.is_true(got.ok)
    assert.is_true(closed)
  end)

  it("assembles a request delivered in several chunks before dispatching", function()
    local path = sock_path()
    local seen
    local server = assert(reqsock.serve({
      path = path,
      on_request = function(req, respond)
        seen = req
        respond({})
      end,
    }))

    local payload = vim.json.encode({ a = 1, b = { c = 2 }, d = "hello" })
    local client = assert(vim.uv.new_pipe(false))
    client:connect(path, function(err)
      assert(not err, err)
      -- dribble the JSON one byte at a time
      for i = 1, #payload do
        client:write(payload:sub(i, i))
      end
      client:read_start(function() end)
    end)

    vim.wait(3000, function()
      return seen ~= nil
    end, 20)
    server.close()

    assert.equals(1, seen.a)
    assert.equals(2, seen.b.c)
    assert.equals("hello", seen.d)
  end)
end)
