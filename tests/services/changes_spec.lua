---@diagnostic disable: undefined-field, need-check-nil
-- luassert narrowing is invisible to emmylua.

local changes = require("harnt.services.changes")

describe("changes service", function()
  before_each(function()
    changes.clear()
  end)

  it("records changes and reports the count + list order", function()
    changes.record({ path = "/a", kind = "add", diff = "x", provider = "codex" })
    changes.record({ path = "/b", kind = "update", diff = "y", provider = "codex" })
    assert.equals(2, changes.count())
    assert.same({ "/a", "/b" }, {
      changes.list()[1].path,
      changes.list()[2].path,
    })
  end)

  it("open() routes the recorded change to the (injectable) viewer", function()
    local seen
    changes.set_viewer(function(c)
      seen = c
    end)
    local i = changes.record({ path = "/c", kind = "delete", diff = "-gone" })
    changes.open(i)
    assert.equals("/c", seen.path)
    assert.equals("delete", seen.kind)
    changes.set_viewer(nil)
  end)

  it("open() with an out-of-range index is a no-op", function()
    local called = false
    changes.set_viewer(function()
      called = true
    end)
    changes.open(99)
    assert.is_false(called)
    changes.set_viewer(nil)
  end)

  it("clear() empties the log", function()
    changes.record({ path = "/x", kind = "add", diff = "z" })
    changes.clear()
    assert.equals(0, changes.count())
  end)
end)
