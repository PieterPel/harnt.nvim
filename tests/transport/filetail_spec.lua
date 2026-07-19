---@diagnostic disable: undefined-field, need-check-nil
-- luassert narrowing is invisible to emmylua.

local filetail = require("harnt.transport.filetail")

describe("filetail.tail", function()
  it("delivers lines appended after the tail starts", function()
    local path = vim.fn.tempname()
    vim.fn.writefile({}, path)

    local got = {}
    local handle = filetail.tail(path, function(line)
      got[#got + 1] = line
    end, { interval = 50 })

    vim.fn.writefile({ "one", "two" }, path, "a")
    vim.wait(3000, function()
      return #got >= 2
    end, 20)
    handle.stop()
    vim.fn.delete(path)

    assert.same({ "one", "two" }, got)
  end)

  it("ignores content written before the tail starts", function()
    local path = vim.fn.tempname()
    vim.fn.writefile({ "old" }, path)

    local got = {}
    local handle = filetail.tail(path, function(line)
      got[#got + 1] = line
    end, { interval = 50 })

    vim.fn.writefile({ "new" }, path, "a")
    vim.wait(3000, function()
      return #got >= 1
    end, 20)
    handle.stop()
    vim.fn.delete(path)

    assert.same({ "new" }, got)
  end)
end)
