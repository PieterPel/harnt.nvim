---@diagnostic disable: undefined-field, need-check-nil, inject-field, return-type-mismatch
-- luassert narrowing is invisible to emmylua; the tests stub vim.notify and use
-- partial provider doubles.

local harnt = require("harnt")
local registry = require("harnt.providers")

local notifications
local orig_notify

before_each(function()
  notifications = {}
  orig_notify = vim.notify
  vim.notify = function(msg, level)
    table.insert(notifications, { msg = msg, level = level })
  end
end)

after_each(function()
  vim.notify = orig_notify
  registry.clear()
end)

describe("harnt.setup", function()
  it("delegates to config and returns the merged options", function()
    local opts = harnt.setup({})
    assert.same({ diff = {}, approvals = {}, keymaps = {} }, opts)
  end)
end)

describe("harnt.register_provider", function()
  it("registers a provider into the registry", function()
    harnt.register_provider(require("tests.support.provider")("p"))
    assert.is_true(registry.is_available("p"))
  end)
end)

describe("harnt.dispatch", function()
  it("runs a known subcommand with its args", function()
    local got
    harnt.subcommands.spec_probe = function(args)
      got = args
    end
    harnt.dispatch("spec_probe", { "a", "b" })
    assert.same({ "a", "b" }, got)
    harnt.subcommands.spec_probe = nil
  end)

  it("notifies an error for an unknown subcommand", function()
    harnt.dispatch("bogus")
    assert.equals(1, #notifications)
    assert.equals(vim.log.levels.ERROR, notifications[1].level)
    assert.is_truthy(notifications[1].msg:find("unknown"))
  end)

  it("notifies usage when no subcommand is given", function()
    harnt.dispatch(nil)
    assert.equals(1, #notifications)
    assert.equals(vim.log.levels.INFO, notifications[1].level)
  end)

  it("exposes sorted subcommand names", function()
    local names = harnt.subcommand_names()
    assert.is_true(vim.tbl_contains(names, "health"))
  end)
end)

describe("plugin/harnt.lua", function()
  it("defines the :Harnt user command", function()
    vim.g.loaded_harnt = nil
    dofile("plugin/harnt.lua")
    assert.equals(2, vim.fn.exists(":Harnt"))
  end)
end)

describe(":Harnt open", function()
  local manager = require("harnt.manager")
  local orig_launch
  local launched

  before_each(function()
    launched = nil
    orig_launch = manager.launch
    manager.launch = function(name, opts)
      launched = { name = name, opts = opts }
    end
  end)

  after_each(function()
    manager.launch = orig_launch
  end)

  it("defaults to claude with no prompt", function()
    harnt.dispatch("open", {})
    assert.equals("claude", launched.name)
    assert.is_nil(launched.opts.prompt)
  end)

  it("reads --prompt-file into the launch prompt", function()
    local path = vim.fn.tempname()
    vim.fn.writefile({ "line one", "", "line three" }, path)
    harnt.dispatch("open", { "codex", "--prompt-file", path })
    os.remove(path)
    assert.equals("codex", launched.name)
    assert.equals("line one\n\nline three", launched.opts.prompt)
  end)

  it("accepts --prompt-file before the provider", function()
    local path = vim.fn.tempname()
    vim.fn.writefile({ "x" }, path)
    harnt.dispatch("open", { "--prompt-file", path, "opencode" })
    os.remove(path)
    assert.equals("opencode", launched.name)
    assert.equals("x", launched.opts.prompt)
  end)

  it("errors without launching on an unreadable prompt file", function()
    harnt.dispatch("open", { "claude", "--prompt-file", "/nonexistent/harnt-prompt" })
    assert.is_nil(launched)
    assert.equals(vim.log.levels.ERROR, notifications[#notifications].level)
  end)

  it("errors without launching when --prompt-file has no path", function()
    harnt.dispatch("open", { "claude", "--prompt-file" })
    assert.is_nil(launched)
    assert.equals(vim.log.levels.ERROR, notifications[#notifications].level)
  end)
end)

describe("harnt.complete", function()
  local provider = require("tests.support.provider")

  before_each(function()
    registry.register(provider("claude"))
    registry.register(provider("codex"))
  end)

  it("completes subcommands first", function()
    assert.same({ "open" }, harnt.complete("op", "Harnt op"))
  end)

  it("completes providers and --prompt-file after open", function()
    assert.same({ "claude", "codex", "--prompt-file" }, harnt.complete("", "Harnt open "))
    assert.same({ "--prompt-file" }, harnt.complete("--", "Harnt open claude --"))
  end)

  it("completes providers only for toggle/stop", function()
    assert.same({ "codex" }, harnt.complete("co", "Harnt stop co"))
  end)

  it("completes a file path after --prompt-file", function()
    local dir = vim.fn.tempname()
    vim.fn.mkdir(dir, "p")
    vim.fn.writefile({}, dir .. "/task.md")
    assert.same(
      { dir .. "/task.md" },
      harnt.complete(dir .. "/ta", "Harnt open claude --prompt-file " .. dir .. "/ta")
    )
    vim.fn.delete(dir, "rf")
  end)

  it("completes nothing for argument-less subcommands", function()
    assert.same({}, harnt.complete("", "Harnt send "))
  end)
end)

describe("harnt.dispatch diff commands", function()
  it("accept notifies when there is no diff", function()
    harnt.dispatch("accept")
    assert.is_true(#notifications >= 1)
    assert.equals(vim.log.levels.WARN, notifications[#notifications].level)
  end)

  it("reject notifies when there is no diff", function()
    harnt.dispatch("reject")
    assert.equals(vim.log.levels.WARN, notifications[#notifications].level)
  end)
end)
