---@diagnostic disable: undefined-field, need-check-nil, return-type-mismatch, missing-fields, duplicate-set-field, param-type-mismatch, call-non-callable
-- luassert narrowing is invisible to emmylua; synthetic providers/handles below
-- are intentionally partial.

local manager = require("harnt.manager")
local registry = require("harnt.providers")
local provider = require("tests.support.provider")

local notifications
local orig_notify

--- A synthetic (complete, valid) provider so tests don't depend on a real agent.
--- Built from the shared no-op fixture, overriding only availability + cmd.
---@param name string
---@param opts { available?: boolean, cmd?: string[] }
local function make_provider(name, opts)
  return provider(name, {
    cmd = opts.cmd or {},
    detect = function()
      return opts.available ~= false
    end,
    -- Shape A providers carry discovery env keyed off the session info; the
    -- no-op fixture returns {}, so opt into a real env when there's a cmd.
    env = opts.cmd and function(info)
      return { PORT = tostring(info.port) }
    end or nil,
  })
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
    local mention_ctx
    registry.register(provider("mentioner", {
      on_mention = function(ctx)
        mention_ctx = ctx
      end,
    }))
    manager.launch("mentioner", { open_terminal = fake_terminal })
    manager.send()
    -- The manager hands on_mention a MentionContext with both delivery primitives.
    assert.is_table(mention_ctx)
    assert.is_table(mention_ctx.session)
    assert.is_function(mention_ctx.send_text)
  end)
end)

describe("manager.review", function()
  it("delegates to the provider's review with reject + send_text primitives", function()
    local diff = require("harnt.services.diff")
    diff.set_presenter(function()
      return { teardown = function() end }
    end)

    local reviewed = false
    registry.register(provider("reviewer", {
      cmd = { "agent" },
      review = function(ctx)
        reviewed = true
        ctx.reject()
        ctx.send_text(("feedback: %d on %s"):format(#ctx.comments, tostring(ctx.path)))
      end,
    }))
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
      return provider(name, {
        cmd = { "agent" },
        review = function(ctx)
          reviewed_by = name
          ctx.reject()
        end,
      })
    end
    -- "alpha" sorts first, so running()[1] would pick it; the diff is beta's.
    registry.register(make_reviewer("alpha"))
    registry.register(make_reviewer("beta"))
    manager.launch("alpha", { open_terminal = fake_terminal })
    manager.launch("beta", { open_terminal = fake_terminal })

    local id = diff.open_review({ path = "/x", diff = "y", origin = "beta" }, function() end)
    manager.review(id)

    diff.set_review_presenter(nil)
    assert.equals("beta", reviewed_by)
  end)

  it("plain-rejects when no agent is running to hand the review to", function()
    -- `review` is a required capability now, so the only fallback is "no target":
    -- with nothing running, a review just rejects the diff.
    local diff = require("harnt.services.diff")
    diff.set_presenter(function()
      return { teardown = function() end }
    end)
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

describe("manager jump-to-agent fallback", function()
  -- Only meaningful without edgy.nvim (see manager.lua's `has_edgy` guard) —
  -- true in this dev shell, so the keymaps are expected to be bound.

  --- Real (not the shared `fake_terminal` buf=0 placeholder) buffer + floating
  --- window, so window-focus assertions below are meaningful.
  local function real_terminal()
    local buf = vim.api.nvim_create_buf(false, true)
    local win = vim.api.nvim_open_win(buf, false, {
      relative = "editor",
      row = 0,
      col = 0,
      width = 10,
      height = 5,
    })
    return { buf = buf, win = win, job = 0 }
  end

  --- The callback bound to `key` on `buf` (nil if nothing's bound there).
  ---@param buf integer
  ---@param key string
  ---@return function?
  local function mapping_callback(buf, key)
    local maps = vim.api.nvim_buf_get_keymap(buf, "n")
    for _, m in ipairs(maps) do
      if m.lhs == key or m.lhs == vim.keycode(key) then
        return m.callback
      end
    end
    return nil
  end

  it("binds a key on the diff that focuses the agent, and back on the agent", function()
    registry.register(make_provider("shapea", { cmd = { "agent" } }))
    local term = real_terminal()
    manager.launch("shapea", {
      open_terminal = function()
        return term
      end,
    })

    local diff = require("harnt.services.diff")
    diff.set_presenter(nil) -- the real side-by-side split, so the buffer has a window
    local id = diff.open(
      { path = "/tmp/x.lua", proposed = { "a" }, origin = "shapea" },
      function() end
    )
    local diff_buf = diff.proposed_bufnr(id)
    local diff_win = vim.fn.win_findbuf(diff_buf)[1]

    local to_agent = mapping_callback(diff_buf, "<leader>t")
    assert(to_agent, "expected a jump-to-agent mapping on the diff buffer")
    to_agent()
    assert.equals(term.win, vim.api.nvim_get_current_win())

    local to_diff = mapping_callback(term.buf, "<leader>t")
    assert(to_diff, "expected a jump-to-diff mapping on the terminal buffer")
    to_diff()
    assert.equals(diff_win, vim.api.nvim_get_current_win())

    diff.reject(id)
  end)

  it("does not bind anything when the diff has no matching running instance", function()
    local diff = require("harnt.services.diff")
    diff.set_presenter(nil)
    local id = diff.open({ path = "/tmp/y.lua", proposed = { "a" } }, function() end) -- no origin
    local diff_buf = diff.proposed_bufnr(id)
    assert.is_nil(mapping_callback(diff_buf, "<leader>t"))
    diff.reject(id)
  end)
end)
