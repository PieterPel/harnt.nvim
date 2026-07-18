---@diagnostic disable: undefined-field, need-check-nil, return-type-mismatch
-- luassert narrowing is invisible to emmylua; session.info is on the reverse-MCP
-- subtype and the fake terminal handles are partial.

local manager = require("harnt.manager")
local registry = require("harnt.providers")

local orig_config_dir

--- A terminal opener stub that never spawns a process.
local function fake_terminal()
  return { buf = 0, win = 0, job = 0 }
end

before_each(function()
  registry.clear()
  registry.register(require("harnt.providers.fake"))
  registry.register(require("harnt.providers.claude"))
  orig_config_dir = vim.env.CLAUDE_CONFIG_DIR
  vim.env.CLAUDE_CONFIG_DIR = vim.fn.tempname()
end)

after_each(function()
  manager.stop_all()
  registry.clear()
  vim.env.CLAUDE_CONFIG_DIR = orig_config_dir
end)

describe("manager.launch", function()
  it("errors on an unknown provider", function()
    assert.has_error(function()
      manager.launch("ghost")
    end)
  end)

  it("launches a cmd-less provider without spawning a terminal", function()
    local spawned = false
    local inst = manager.launch("fake", {
      open_terminal = function()
        spawned = true
        return fake_terminal()
      end,
    })
    assert.is_false(spawned)
    assert.is_nil(inst.terminal)
    assert.is_true(vim.tbl_contains(manager.running(), "fake"))
  end)

  it("spawns a Shape A TUI with the discovery env", function()
    ---@type table
    local captured
    local inst = manager.launch("claude", {
      open_terminal = function(o)
        captured = o
        return fake_terminal()
      end,
    })
    assert.same({ "claude" }, captured.cmd)
    assert.equals(tostring(inst.session.info.port), captured.env.CLAUDE_CODE_SSE_PORT)
    assert.equals("true", captured.env.ENABLE_IDE_INTEGRATION)
    assert.is_not_nil(inst.terminal)
  end)

  it("is idempotent — a second launch reuses the instance", function()
    local count = 0
    local first = manager.launch("claude", {
      open_terminal = function()
        count = count + 1
        return fake_terminal()
      end,
    })
    local second = manager.launch("claude", {
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
  it("stops a provider and drops it from running()", function()
    manager.launch("claude", { open_terminal = fake_terminal })
    assert.is_true(vim.tbl_contains(manager.running(), "claude"))
    manager.stop("claude")
    assert.is_false(vim.tbl_contains(manager.running(), "claude"))
  end)

  it("stop_all stops everything", function()
    manager.launch("fake", { open_terminal = fake_terminal })
    manager.launch("claude", { open_terminal = fake_terminal })
    manager.stop_all()
    assert.same({}, manager.running())
  end)
end)
