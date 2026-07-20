---@diagnostic disable: need-check-nil, undefined-field

local unixsock = require("harnt.transport.unixsock")

local function sock_path()
  return ("/tmp/harnt-unixsock-%d.sock"):format(vim.uv.hrtime() % 1e9)
end

describe("unixsock", function()
  it("accepts a connection and streams raw bytes both ways", function()
    local path = sock_path()
    local received
    local server = assert(unixsock.server({
      path = path,
      on_connection = function(conn)
        conn.read_start(function(chunk)
          received = chunk
          conn.write("pong")
        end)
      end,
    }))

    local reply
    local client = assert(vim.uv.new_pipe(false))
    client:connect(path, function(err)
      assert(not err, err)
      client:write("ping")
      client:read_start(function(_e, chunk)
        if chunk then
          reply = chunk
        end
      end)
    end)

    vim.wait(3000, function()
      return received ~= nil and reply ~= nil
    end, 20)
    if not client:is_closing() then
      client:close()
    end
    server.close()

    assert.equals("ping", received)
    assert.equals("pong", reply)
  end)

  it("fails to bind a path already held by a live server", function()
    local path = sock_path()
    local first = assert(unixsock.server({ path = path, on_connection = function() end }))
    local second, err = unixsock.server({ path = path, on_connection = function() end })
    first.close()
    assert.is_nil(second)
    assert.is_string(err)
  end)

  describe("free_stale", function()
    it("reports an absent path as free", function()
      local path = sock_path()
      local free
      unixsock.free_stale(path, function(f)
        free = f
      end)
      vim.wait(2000, function()
        return free ~= nil
      end, 20)
      assert.is_true(free)
    end)

    it("unlinks a stale (dead) socket file and reports free", function()
      local path = sock_path()
      -- a plain file at the path: nothing is listening, so it's stale
      vim.fn.writefile({ "stale" }, path)
      local free
      unixsock.free_stale(path, function(f)
        free = f
      end)
      vim.wait(2000, function()
        return free ~= nil
      end, 20)
      assert.is_true(free)
      assert.equals(0, vim.fn.filereadable(path))
    end)

    it("leaves a live socket alone and reports not-free", function()
      local path = sock_path()
      local server = assert(unixsock.server({ path = path, on_connection = function() end }))
      local free
      unixsock.free_stale(path, function(f)
        free = f
      end)
      vim.wait(2000, function()
        return free ~= nil
      end, 20)
      server.close()
      assert.is_false(free)
    end)
  end)
end)
