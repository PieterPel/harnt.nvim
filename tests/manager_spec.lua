---@diagnostic disable: undefined-field, need-check-nil, return-type-mismatch, missing-fields, duplicate-set-field, param-type-mismatch, call-non-callable
-- luassert narrowing is invisible to emmylua; synthetic providers/handles below
-- are intentionally partial.

local manager = require("harnt.manager")
local registry = require("harnt.providers")

local notifications
local orig_notify

--- A synthetic provider so tests don't depend on a real agent being installed.
---@param name string
---@param opts { available?: boolean, cmd?: string[] }
local function make_provider(name, opts)
  return {
    name = name,
    cmd = opts.cmd,
    detect = function()
      return opts.available ~= false
    end,
    env = opts.cmd and function(info)
      return { PORT = tostring(info.port) }
    end or nil,
    start = function()
      return {
        info = { host = "127.0.0.1", port = 4321, auth_token = "t", pid = 1 },
        on = function() end,
        respond = function() end,
        interrupt = function() end,
        stop = function() end,
      }
    end,
  }
end

local function fake_terminal()
  return { buf = 0, win = 0, job = 0 }
end

before_each(function()
  registry.clear()
  notifications = {}
  orig_notify = vim.notify
  vim.notify = function(msg, level)
    table.insert(notifications, { msg = msg, level = level })
  end
end)

after_each(function()
  manager.stop_all()
  registry.clear()
  vim.notify = orig_notify
end)

describe("manager.launch guards", function()
  it("notifies + returns nil for an unknown provider", function()
    assert.is_nil(manager.launch("ghost"))
    assert.equals(vim.log.levels.ERROR, notifications[#notifications].level)
  end)

  it("notifies + returns nil for an unavailable provider", function()
    registry.register(make_provider("off", { available = false }))
    assert.is_nil(manager.launch("off"))
    assert.is_truthy(notifications[#notifications].msg:find("not available"))
  end)
end)

describe("manager.launch", function()
  it("launches a cmd-less provider without spawning a terminal", function()
    registry.register(make_provider("headless", {}))
    local spawned = false
    local inst = manager.launch("headless", {
      open_terminal = function()
        spawned = true
        return fake_terminal()
      end,
    })
    assert.is_false(spawned)
    assert.is_nil(inst.terminal)
    assert.is_true(vim.tbl_contains(manager.running(), "headless"))
  end)

  it("spawns a Shape A TUI with the discovery env", function()
    registry.register(make_provider("shapea", { cmd = { "agent" } }))
    ---@type table
    local captured
    local inst = manager.launch("shapea", {
      open_terminal = function(o)
        captured = o
        return fake_terminal()
      end,
    })
    assert.same({ "agent" }, captured.cmd)
    assert.equals("4321", captured.env.PORT)
    assert.is_not_nil(inst.terminal)
  end)

  it("is idempotent", function()
    registry.register(make_provider("shapea", { cmd = { "agent" } }))
    local count = 0
    local first = manager.launch("shapea", {
      open_terminal = function()
        count = count + 1
        return fake_terminal()
      end,
    })
    local second = manager.launch("shapea", {
      open_terminal = function()
        count = count + 1
        return fake_terminal()
      end,
    })
    assert.equals(first, second)
    assert.equals(1, count)
  end)
end)

describe("manager.stop", function()
  it("drops the provider from running()", function()
    registry.register(make_provider("headless", {}))
    manager.launch("headless", { open_terminal = fake_terminal })
    manager.stop("headless")
    assert.is_false(vim.tbl_contains(manager.running(), "headless"))
  end)

  it("stop_all stops everything", function()
    registry.register(make_provider("a", {}))
    registry.register(make_provider("b", {}))
    manager.launch("a", { open_terminal = fake_terminal })
    manager.launch("b", { open_terminal = fake_terminal })
    manager.stop_all()
    assert.same({}, manager.running())
  end)
end)

describe("manager.toggle", function()
  it("shows a hidden terminal, then hides it", function()
    registry.register(make_provider("shapea", { cmd = { "agent" } }))
    local buf = vim.api.nvim_create_buf(false, true)
    manager.launch("shapea", {
      open_terminal = function()
        return { buf = buf, win = 0, job = 0 }
      end,
    })

    assert.equals(0, #vim.fn.win_findbuf(buf))
    manager.toggle("shapea")
    assert.equals(1, #vim.fn.win_findbuf(buf))
    manager.toggle("shapea")
    assert.equals(0, #vim.fn.win_findbuf(buf))
  end)
end)

describe("manager.send", function()
  it("delegates to the provider's on_mention for running agents", function()
    local mentioned = false
    registry.register({
      name = "mentioner",
      detect = function()
        return true
      end,
      start = function()
        return {
          on = function() end,
          respond = function() end,
          interrupt = function() end,
          stop = function() end,
        }
      end,
      on_mention = function(_session)
        mentioned = true
      end,
    })
    manager.launch("mentioner", { open_terminal = fake_terminal })
    manager.send()
    assert.is_true(mentioned)
  end)
end)

describe("manager.review", function()
  it("delegates to the provider's review with reject + send_text primitives", function()
    local diff = require("harnt.services.diff")
    diff.set_presenter(function()
      return { teardown = function() end }
    end)

    local reviewed = false
    registry.register({
      name = "reviewer",
      detect = function()
        return true
      end,
      cmd = { "agent" },
      start = function()
        return {
          on = function() end,
          respond = function() end,
          interrupt = function() end,
          stop = function() end,
        }
      end,
      review = function(ctx)
        reviewed = true
        ctx.reject()
        ctx.send_text(("feedback: %d on %s"):format(#ctx.comments, tostring(ctx.path)))
      end,
    })
    manager.launch("reviewer", {
      open_terminal = function()
        return { buf = 0, win = 0, job = 1 }
      end,
    })

    local sent
    local orig = manager.send_text
    manager.send_text = function(_name, text)
      sent = text
    end

    local rejected = false
    local id = diff.open({ path = "/tmp/f.lua", proposed = { "x" } }, function(r)
      rejected = not r.accepted
    end)
    diff.add_comment(id, 1, "x")
    manager.review(id)

    manager.send_text = orig
    diff.set_presenter(nil)

    assert.is_true(reviewed)
    assert.is_true(rejected)
    assert.equals(0, diff.open_count())
    assert.is_truthy(sent:find("feedback: 1 on /tmp/f.lua"))
  end)

  it("routes review feedback to the diff's origin provider, not running()[1]", function()
    local diff = require("harnt.services.diff")
    diff.set_review_presenter(function()
      return { teardown = function() end }
    end)

    local reviewed_by
    local function make_reviewer(name)
      return {
        name = name,
        cmd = { "agent" },
        detect = function()
          return true
        end,
        start = function()
          return {
            info = {},
            on = function() end,
            respond = function() end,
            interrupt = function() end,
            stop = function() end,
          }
        end,
        review = function(ctx)
          reviewed_by = name
          ctx.reject()
        end,
      }
    end
    -- "alpha" sorts first, so running()[1] would pick it; the diff is beta's.
    registry.register(make_reviewer("alpha"))
    registry.register(make_reviewer("beta"))
    manager.launch("alpha", { open_terminal = fake_terminal })
    manager.launch("beta", { open_terminal = fake_terminal })

    local id = diff.open_review({ path = "/x", patch = "y", origin = "beta" }, function() end)
    manager.review(id)

    diff.set_review_presenter(nil)
    assert.equals("beta", reviewed_by)
  end)

  it("plain-rejects when the agent has no review capability", function()
    local diff = require("harnt.services.diff")
    diff.set_presenter(function()
      return { teardown = function() end }
    end)
    registry.register(make_provider("plain", { cmd = { "agent" } }))
    manager.launch("plain", {
      open_terminal = function()
        return { buf = 0, win = 0, job = 1 }
      end,
    })
    local rejected = false
    local id = diff.open({ path = "/x", proposed = {} }, function(r)
      rejected = not r.accepted
    end)
    diff.add_comment(id, 1, "x")
    manager.review(id)
    diff.set_presenter(nil)
    assert.is_true(rejected)
  end)
end)

describe("harnt.statusline", function()
  it("is empty when idle and names running providers otherwise", function()
    local harnt = require("harnt")
    assert.equals("", harnt.statusline())
    registry.register(make_provider("headless", {}))
    manager.launch("headless", { open_terminal = fake_terminal })
    assert.is_truthy(harnt.statusline():find("headless"))
  end)
end)
