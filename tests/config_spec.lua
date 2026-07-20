---@diagnostic disable: undefined-field, need-check-nil, param-type-mismatch, missing-fields
-- luassert narrowing is invisible to emmylua; some cases feed intentionally
-- invalid options to exercise validation.

local config = require("harnt.config")
local diff = require("harnt.services.diff")
local approvals = require("harnt.services.approvals")

after_each(function()
  diff.set_presenter(nil)
  approvals.set_chooser(nil)
  approvals.reset()
end)

describe("config.setup", function()
  it("returns the defaults when given nothing", function()
    assert.same({ diff = {}, approvals = {}, keymaps = {} }, config.setup())
  end)

  it("wires a diff presenter into the diff service", function()
    local used = false
    config.setup({
      diff = {
        presenter = function()
          used = true
          return { teardown = function() end }
        end,
      },
    })
    local id = diff.open({ path = "/tmp/x", proposed = { "a" } }, function() end)
    assert.is_true(used)
    diff.reject(id)
  end)

  it("wires an approvals chooser into the approvals service", function()
    local used = false
    config.setup({
      approvals = {
        chooser = function(_req, on_choice)
          used = true
          on_choice("deny_once")
        end,
      },
    })
    approvals.request({ key = "k", prompt = "?" }, function() end)
    assert.is_true(used)
  end)

  it("rejects a non-table opts", function()
    assert.has_error(function()
      config.setup("nope")
    end)
  end)

  it("rejects a non-function presenter / chooser", function()
    assert.has_error(function()
      config.setup({ diff = { presenter = 5 } })
    end)
    assert.has_error(function()
      config.setup({ approvals = { chooser = "x" } })
    end)
  end)

  it("wires diff keymaps into the diff service", function()
    config.setup({ keymaps = { diff = { accept = "gA", reject = "gR" } } })
    diff.set_presenter(nil)
    local id = diff.open({ path = "/tmp/x", proposed = { "a" } }, function() end)
    local win = vim.fn.win_findbuf(diff.proposed_bufnr(id))[1]
    assert.is_truthy(vim.wo[win].winbar:find("gA"))
    diff.reject(id)
    diff.set_keys({ accept = "<leader>a", reject = "<leader>r" }) -- restore default
  end)
end)
