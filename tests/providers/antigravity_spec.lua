---@diagnostic disable: undefined-field, need-check-nil, missing-fields
-- luassert narrowing is invisible to emmylua; hook payloads are partial by design.

local antigravity = require("harnt.providers.antigravity")
local approvals = require("harnt.services.approvals")
local changes = require("harnt.services.changes")
local diff = require("harnt.services.diff")

describe("antigravity provider", function()
  before_each(function()
    changes.clear()
    approvals.reset()
    -- No-op presentations so the review/approval paths don't open real UI.
    diff.set_review_presenter(function()
      return { teardown = function() end }
    end)
  end)

  after_each(function()
    diff.set_review_presenter(nil)
    approvals.set_chooser(nil)
  end)

  it("detect() returns a boolean", function()
    assert.is_boolean(antigravity.detect())
  end)

  it("cmd is the native agy TUI", function()
    assert.same({ "agy" }, antigravity.cmd)
  end)

  describe("_normalize_edit", function()
    it("renders a real unified diff when path + content are recoverable", function()
      local tmp = vim.fn.tempname()
      vim.fn.writefile({ "line one", "line two" }, tmp)
      local edit = antigravity._normalize_edit("edit_file", {
        path = tmp,
        content = "line one\nline two changed\n",
      })
      assert.equals(tmp, edit.path)
      assert.equals("update", edit.kind)
      local text = table.concat(edit.patch, "\n")
      assert.is_truthy(text:find("line two changed", 1, true))
      os.remove(tmp)
    end)

    it("marks a new file as an add", function()
      local tmp = vim.fn.tempname()
      local edit = antigravity._normalize_edit("write_file", { path = tmp, content = "hi\n" })
      assert.equals("add", edit.kind)
    end)

    it("falls back to showing raw args when fields are unrecognized", function()
      local edit = antigravity._normalize_edit("mystery_tool", { weird = "shape", n = 3 })
      assert.equals("(mystery_tool)", edit.path)
      local text = table.concat(edit.patch, "\n")
      assert.is_truthy(text:find("weird", 1, true))
    end)
  end)

  describe("_deny_reason", function()
    it("is a plain reason with no comments", function()
      assert.equals("Change rejected in the editor.", antigravity._deny_reason(nil))
      assert.equals("Change rejected in the editor.", antigravity._deny_reason({}))
    end)

    it("lists inline comments as feedback", function()
      local reason = antigravity._deny_reason({ { line = 4, text = "nil guard" } })
      assert.is_truthy(reason:find("Feedback:", 1, true))
      assert.is_truthy(reason:find("L4: nil guard", 1, true))
    end)
  end)

  describe("_on_hook dispatch", function()
    it("PreInvocation returns injectSteps (context push)", function()
      local got
      antigravity._on_hook({ invocationNum = 2 }, function(resp)
        got = resp
      end)
      assert.is_table(got.injectSteps)
    end)

    it("PostToolUse (no toolCall, no invocationNum) acks empty", function()
      local got
      antigravity._on_hook({ stepIdx = 5 }, function(resp)
        got = resp
      end)
      assert.same(vim.empty_dict(), got)
    end)

    it("PreToolUse edit → diff review; accept answers allow + records the change", function()
      local tmp = vim.fn.tempname()
      vim.fn.writefile({ "a" }, tmp)
      local got
      antigravity._on_hook({
        toolCall = { name = "edit_file", args = { path = tmp, content = "a\nb\n" } },
      }, function(resp)
        got = resp
      end)
      -- the review is pending; accepting it resolves the decision
      assert.is_nil(got)
      diff.accept(assert(diff.current()))
      assert.equals("allow", got.decision)
      -- accepting the diff grants agy's write permission so it doesn't re-prompt
      assert.same({ ("write_file(%s)"):format(tmp) }, got.permissionOverrides)
      assert.equals(1, changes.count())
      assert.equals(tmp, changes.list()[1].path)
      os.remove(tmp)
    end)

    it("PreToolUse edit → reject answers deny and records nothing", function()
      local tmp = vim.fn.tempname()
      vim.fn.writefile({ "a" }, tmp)
      local got
      antigravity._on_hook({
        toolCall = { name = "edit_file", args = { path = tmp, content = "a\nb\n" } },
      }, function(resp)
        got = resp
      end)
      diff.reject(assert(diff.current()))
      assert.equals("deny", got.decision)
      assert.equals(0, changes.count())
      os.remove(tmp)
    end)

    it("PreToolUse edit → reject folds inline comments into the deny reason", function()
      local tmp = vim.fn.tempname()
      vim.fn.writefile({ "a" }, tmp)
      local got
      antigravity._on_hook({
        toolCall = { name = "edit_file", args = { path = tmp, content = "a\nb\n" } },
      }, function(resp)
        got = resp
      end)
      local id = assert(diff.current())
      diff.add_comment(id, 2, "prefer append")
      diff.reject(id)
      assert.equals("deny", got.decision)
      assert.is_truthy(got.reason:find("L2: prefer append", 1, true))
      assert.equals(0, changes.count())
      os.remove(tmp)
    end)

    it("PreToolUse run_command → approval prompt; allow maps to decision allow", function()
      approvals.set_chooser(function(_req, on_choice)
        on_choice("allow_once")
      end)
      local got
      antigravity._on_hook({
        toolCall = { name = "run_command", args = { CommandLine = "ls" } },
      }, function(resp)
        got = resp
      end)
      assert.equals("allow", got.decision)
      assert.same({ "command(ls)" }, got.permissionOverrides)
    end)

    it("PreToolUse run_command → deny maps to decision deny", function()
      approvals.set_chooser(function(_req, on_choice)
        on_choice("deny_once")
      end)
      local got
      antigravity._on_hook({
        toolCall = { name = "run_command", args = { CommandLine = "rm -rf /" } },
      }, function(resp)
        got = resp
      end)
      assert.equals("deny", got.decision)
    end)
  end)
end)
