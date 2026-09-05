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

  it("wires a diff.style into the diff service as the active presenter", function()
    config.setup({ diff = { style = "inline" } })
    local id = diff.open(
      { path = "/tmp/x.lua", proposed = { "a" }, original = { "a" } },
      function() end
    )
    local pbuf = diff.proposed_bufnr(id)
    assert(pbuf)
    -- the inline presenter puts the proposal in the (only) window of a new tab
    assert.equals(pbuf, vim.api.nvim_win_get_buf(vim.fn.win_findbuf(pbuf)[1]))
    diff.reject(id)
  end)

  it("diff.presenter takes precedence over diff.style when both are set", function()
    local used = false
    config.setup({
      diff = {
        style = "inline",
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

  it("rejects an unknown diff.style", function()
    assert.has_error(function()
      config.setup({ diff = { style = "nonexistent" } })
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

  it('wires diff.style = "docked" into the diff service too', function()
    config.setup({ diff = { style = "docked" } })
    local baseline_tab = vim.fn.tabpagenr("$")
    local id = diff.open(
      { path = "/tmp/x.lua", proposed = { "a" }, original = { "a" } },
      function() end
    )
    assert.equals(baseline_tab, vim.fn.tabpagenr("$")) -- docked: no new tab
    diff.reject(id)
  end)

  it("wires keymaps.jump_agent into the manager's jump key", function()
    local manager = require("harnt.manager")
    local registry = require("harnt.providers")
    local provider = require("tests.support.provider")

    config.setup({ keymaps = { jump_agent = "<leader>gg" } })
    registry.register(provider("cfgtest", { cmd = { "agent" } }))
    local term_buf = vim.api.nvim_create_buf(false, true)
    manager.launch("cfgtest", {
      open_terminal = function()
        return { buf = term_buf, win = 0, job = 0 }
      end,
    })

    diff.set_presenter(nil)
    local id = diff.open(
      { path = "/tmp/x", proposed = { "a" }, origin = "cfgtest" },
      function() end
    )
    local maps = vim.api.nvim_buf_get_keymap(term_buf, "n")
    local bound = vim.tbl_filter(function(m)
      return m.lhs == "<leader>gg" or m.lhs == vim.keycode("<leader>gg")
    end, maps)
    assert.equals(1, #bound)

    diff.reject(id)
    manager.stop("cfgtest")
    registry.clear()
    manager.set_jump_key("<leader>t") -- restore default
  end)
end)
