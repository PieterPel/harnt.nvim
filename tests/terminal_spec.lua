---@diagnostic disable: undefined-field, need-check-nil
-- (luassert extends `assert`; its narrowing is invisible to emmylua)

local terminal = require("harnt.terminal")

after_each(function()
  terminal.set_opener(nil) -- restore autodetect (built-in when snacks absent)
end)

describe("terminal.open", function()
  it("runs a command in a terminal buffer", function()
    local handle = terminal.open({ cmd = { "cat" } })
    assert.is_true(handle.job > 0)
    assert.equals("terminal", vim.bo[handle.buf].buftype)
    terminal.close(handle)
  end)

  it("fires on_exit with the exit code", function()
    local code
    terminal.open({
      cmd = { "sh", "-c", "exit 0" },
      on_exit = function(c)
        code = c
      end,
    })
    local ok = vim.wait(2000, function()
      return code ~= nil
    end, 10)
    assert.is_true(ok)
    assert.equals(0, code)
  end)

  it("injects env vars into the child process", function()
    local code
    terminal.open({
      cmd = { "sh", "-c", '[ "$HARNT_TEST" = "yes" ]' },
      env = { HARNT_TEST = "yes" },
      on_exit = function(c)
        code = c
      end,
    })
    local ok = vim.wait(2000, function()
      return code ~= nil
    end, 10)
    assert.is_true(ok)
    assert.equals(0, code) -- 0 only if $HARNT_TEST was "yes"
  end)
end)

describe("terminal.close", function()
  it("stops the job and wipes the buffer", function()
    local handle = terminal.open({ cmd = { "cat" } })
    local buf = handle.buf
    terminal.close(handle)
    assert.is_false(vim.api.nvim_buf_is_valid(buf))
  end)
end)

describe("terminal opener seam", function()
  it("dispatches open/close to an injected opener", function()
    local opened, closed
    terminal.set_opener({
      open = function(opts)
        opened = opts
        return { buf = 1, win = 1, job = 1 }
      end,
      close = function(handle)
        closed = handle
      end,
    })

    local handle = terminal.open({ cmd = { "claude" }, env = { X = "1" } })
    assert.same({ "claude" }, opened.cmd)
    assert.equals(1, handle.buf)
    terminal.close(handle)
    assert.equals(handle, closed)
  end)

  it("exposes the built-in opener", function()
    assert.is_function(terminal.builtin.open)
    assert.is_function(terminal.builtin.close)
  end)
end)
