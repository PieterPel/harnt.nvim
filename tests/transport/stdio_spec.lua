---@diagnostic disable: undefined-field, need-check-nil
-- luassert narrowing is invisible to emmylua.

local stdio = require("harnt.transport.stdio")

describe("stdio.line_buffer", function()
  it("splits complete newline-delimited lines and retains partials", function()
    local lb = stdio.line_buffer()
    assert.same({ "a", "b" }, lb:feed("a\nb\n"))
    assert.same({}, lb:feed("par")) -- partial: nothing yet
    assert.same({ "partial" }, lb:feed("tial\n")) -- completes the retained partial
  end)

  it("strips a trailing CR (CRLF framing)", function()
    local lb = stdio.line_buffer()
    assert.same({ "x", "y" }, lb:feed("x\r\ny\r\n"))
  end)

  it("handles multiple lines arriving in one chunk", function()
    local lb = stdio.line_buffer()
    assert.same({ "1", "2", "3" }, lb:feed("1\n2\n3\n"))
  end)
end)

describe("stdio.spawn", function()
  it("round-trips JSON lines through a child (cat echoes stdin to stdout)", function()
    local got = {}
    local done = false
    local child = stdio.spawn({
      cmd = { "cat" },
      on_message = function(value, _raw)
        table.insert(got, value)
        if #got >= 2 then
          done = true
        end
      end,
    })
    child.send({ hello = "world" })
    child.send({ n = 42 })

    vim.wait(2000, function()
      return done
    end, 20)
    child.stop()

    assert.equals("world", got[1].hello)
    assert.equals(42, got[2].n)
  end)

  it("delivers nil value for a non-JSON line but keeps the raw text", function()
    local raws = {}
    local done = false
    local child = stdio.spawn({
      cmd = { "cat" },
      on_message = function(value, raw)
        table.insert(raws, { value = value, raw = raw })
        done = true
      end,
    })
    child.write("not json\n")

    vim.wait(2000, function()
      return done
    end, 20)
    child.stop()

    assert.is_nil(raws[1].value)
    assert.equals("not json", raws[1].raw)
  end)
end)
