---@diagnostic disable: undefined-field, need-check-nil, missing-fields
-- luassert narrowing is invisible to emmylua; session stubs are partial by design.

local codex = require("harnt.providers.codex")

describe("codex provider", function()
  it("detect() returns a boolean", function()
    assert.is_boolean(codex.detect())
  end)

  it("cmd() launches the native TUI against the proxy ws endpoint", function()
    local cmd =
      codex.cmd({ info = { remote_url = "ws://127.0.0.1:4500", port = 4500 } } --[[@as harnt.codex.Session]])
    assert.same({ "codex", "--remote", "ws://127.0.0.1:4500" }, cmd)
  end)

  describe("proxy tap (_router)", function()
    --- Build a router wired to recording fakes.
    local function harness()
      local cap = { sent = {}, forwarded = {}, reviews = {}, cmds = {}, emitted = {} }
      local router = codex._router({
        send_upstream = function(obj)
          table.insert(cap.sent, obj)
        end,
        forward_to_tui = function(raw)
          table.insert(cap.forwarded, raw)
        end,
        open_review = function(changes, resolve)
          table.insert(cap.reviews, { changes = changes, resolve = resolve })
        end,
        request_command = function(params, resolve)
          table.insert(cap.cmds, { params = params, resolve = resolve })
        end,
        emit = function(ev, p)
          table.insert(cap.emitted, { ev = ev, p = p })
        end,
      })
      return router, cap
    end

    it("relays ordinary notifications and captures fileChange items", function()
      local r, cap = harness()
      r.feed_upstream(
        { method = "item/started", params = { item = { type = "agentMessage", id = "m1" } } },
        "RAW1"
      )
      r.feed_upstream({
        method = "item/started",
        params = {
          item = {
            type = "fileChange",
            id = "exec1",
            changes = { { path = "/x.txt", kind = { type = "add" }, diff = "hi\n" } },
          },
        },
      }, "RAW2")
      -- both relayed to the TUI untouched
      assert.same({ "RAW1", "RAW2" }, cap.forwarded)
    end)

    it("intercepts a v2 file approval: renders the diff, answers accept, does NOT relay", function()
      local r, cap = harness()
      -- the fileChange item arrives first so the diff correlates by itemId
      r.feed_upstream({
        method = "item/started",
        params = {
          item = {
            type = "fileChange",
            id = "exec1",
            changes = { { path = "/x.txt", kind = { type = "add" }, diff = "hi there\n" } },
          },
        },
      }, "RAW_ITEM")
      r.feed_upstream(
        { id = 7, method = "item/fileChange/requestApproval", params = { itemId = "exec1" } },
        "RAW_APPROVAL"
      )
      -- only the item was relayed; the approval frame was intercepted
      assert.same({ "RAW_ITEM" }, cap.forwarded)
      assert.equals(1, #cap.reviews)
      assert.equals("/x.txt", cap.reviews[1].changes[1].path)
      assert.equals("add", cap.reviews[1].changes[1].kind)
      -- accepting answers app-server with the v2 decision
      cap.reviews[1].resolve(true)
      assert.same({ id = 7, result = { decision = "accept" } }, cap.sent[1])
    end)

    it("answers decline (v2) on reject", function()
      local r, cap = harness()
      r.feed_upstream(
        { id = 8, method = "item/fileChange/requestApproval", params = { itemId = "gone" } },
        "RAW"
      )
      cap.reviews[1].resolve(false)
      assert.same({ id = 8, result = { decision = "decline" } }, cap.sent[1])
    end)

    it("handles v1 applyPatchApproval (inline diff, v1 decisions)", function()
      local r, cap = harness()
      r.feed_upstream({
        id = 9,
        method = "applyPatchApproval",
        params = {
          fileChanges = { ["/y.txt"] = { type = "update", unified_diff = "@@ -1 +1 @@\n-a\n+b\n" } },
        },
      }, "RAW")
      assert.equals("/y.txt", cap.reviews[1].changes[1].path)
      cap.reviews[1].resolve(true)
      assert.same({ id = 9, result = { decision = "approved" } }, cap.sent[1])
    end)

    it("routes command approvals through request_command (intercepted)", function()
      local r, cap = harness()
      r.feed_upstream({
        id = 10,
        method = "item/commandExecution/requestApproval",
        params = { command = "rm -rf /" },
      }, "RAW")
      assert.equals(0, #cap.forwarded)
      assert.equals("rm -rf /", cap.cmds[1].params.command)
      cap.cmds[1].resolve(false)
      assert.same({ id = 10, result = { decision = "decline" } }, cap.sent[1])
    end)

    it("relays server requests it does not intercept (the TUI answers them)", function()
      local r, cap = harness()
      r.feed_upstream({ id = 11, method = "item/tool/requestUserInput", params = {} }, "RAW_REQ")
      assert.same({ "RAW_REQ" }, cap.forwarded)
      assert.equals(0, #cap.sent)
    end)

    it("relays responses to requests untouched", function()
      local r, cap = harness()
      r.feed_upstream({ id = 3, result = { thread = { id = "t1" } } }, "RAW_RESP")
      assert.same({ "RAW_RESP" }, cap.forwarded)
    end)
  end)
end)
