---@diagnostic disable: undefined-field, need-check-nil, missing-fields
-- luassert narrowing is invisible to emmylua; and the service doubles below are
-- intentionally partial (only the slice the runtime uses).

local runtime = require("harnt.runtime")
local fake = require("harnt.providers.fake")
local events = require("harnt.events")
local real_diff = require("harnt.services.diff")
local real_approvals = require("harnt.services.approvals")

describe("runtime.attach diff flow", function()
  it("translates diff.ready into diff.open and routes the result back to respond", function()
    local session = fake.start({})
    ---@type table
    local opened
    local diff = {
      open = function(spec, callback)
        opened = { spec = spec, callback = callback }
        return 1
      end,
    }
    runtime.attach(session, { diff = diff })

    session:emit(events.TYPES.diff_ready, {
      id = 5,
      path = "/tmp/a.lua",
      proposed = { "new" },
      original = { "old" },
    })
    assert.same({ path = "/tmp/a.lua", proposed = { "new" }, original = { "old" } }, opened.spec)

    -- simulate the user accepting the diff
    opened.callback({ accepted = true, content = { "new" } })
    assert.same({ accepted = true, content = { "new" } }, session:response_for(5))
  end)

  it("does not respond when the diff.ready carries no id", function()
    local session = fake.start({})
    ---@type table
    local opened
    runtime.attach(session, {
      diff = {
        open = function(spec, callback)
          opened = { spec = spec, callback = callback }
          return 1
        end,
      },
    })
    session:emit(events.TYPES.diff_ready, { path = "/tmp/x", proposed = {} })
    assert.has_no.errors(function()
      opened.callback({ accepted = false })
    end)
  end)
end)

describe("runtime.attach approval flow", function()
  it("translates approval.requested into approvals.request and responds", function()
    local session = fake.start({})
    local requested
    runtime.attach(session, {
      approvals = {
        request = function(req, callback)
          requested = req
          callback(true, "allow_once")
        end,
      },
    })

    session:emit(events.TYPES.approval_requested, { id = 8, key = "cmd:ls", prompt = "run ls?" })
    assert.equals("cmd:ls", requested.key)
    assert.same({ allowed = true, decision = "allow_once" }, session:response_for(8))
  end)
end)

describe("runtime.attach detach", function()
  it("stops routing events after detach", function()
    local session = fake.start({})
    local calls = 0
    local detach = runtime.attach(session, {
      diff = {
        open = function()
          calls = calls + 1
          return 1
        end,
      },
    })
    session:emit(events.TYPES.diff_ready, { path = "/x", proposed = {} })
    detach()
    session:emit(events.TYPES.diff_ready, { path = "/x", proposed = {} })
    assert.equals(1, calls)
  end)
end)

describe("runtime end-to-end with real services", function()
  it("drives an approval through the real approvals service", function()
    real_approvals.reset()
    real_approvals.set_chooser(function(_req, on_choice)
      on_choice("allow_always")
    end)

    local session = fake.start({})
    runtime.attach(session) -- real services
    session:emit(events.TYPES.approval_requested, { id = 1, key = "k", prompt = "?" })

    assert.same({ allowed = true, decision = "allow_always" }, session:response_for(1))

    real_approvals.set_chooser(nil)
    real_approvals.reset()
  end)

  it("drives a diff through the real diff service: accept writes the file and responds", function()
    real_diff.set_presenter(function()
      return { teardown = function() end }
    end)

    local session = fake.start({})
    -- capture the real diff id so the test can accept it
    ---@type integer?
    local diff_id
    runtime.attach(session, {
      diff = {
        open = function(spec, callback)
          diff_id = real_diff.open(spec, callback)
          return diff_id
        end,
      },
    })

    local path = vim.fn.tempname() .. ".txt"
    session:emit(events.TYPES.diff_ready, { id = 42, path = path, proposed = { "hello" } })

    assert(diff_id, "runtime should have opened a diff")
    real_diff.accept(diff_id)

    assert.same({ "hello" }, vim.fn.readfile(path))
    local resp = session:response_for(42)
    assert.is_true(resp.accepted)
    assert.same({ "hello" }, resp.content)

    real_diff.set_presenter(nil)
  end)
end)
