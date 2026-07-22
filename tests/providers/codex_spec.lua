---@diagnostic disable: undefined-field, need-check-nil, missing-fields
-- luassert narrowing is invisible to emmylua; session stubs are partial by design.

local codex = require("harnt.providers.codex")

describe("codex provider", function()
  it("detect() returns a boolean", function()
    assert.is_boolean(codex.detect())
  end)

  it("health() emits diagnostics via the report adapter", function()
    local calls = {}
    local function rec(m)
      calls[#calls + 1] = m
    end
    codex.health({ ok = rec, warn = rec, error = rec, info = rec })
    assert.is_true(#calls > 0)
  end)

  it("cmd() launches the native TUI against the proxy ws endpoint", function()
    local cmd =
      codex.cmd({ info = { remote_url = "ws://127.0.0.1:4500", port = 4500 } } --[[@as harnt.codex.Session]])
    assert.same({ "codex", "--remote", "ws://127.0.0.1:4500" }, cmd)
  end)

  describe("proxy tap (_router)", function()
    --- Build a router wired to recording fakes.
    local function harness()
      local cap =
        { sent = {}, forwarded = {}, reviews = {}, cmds = {}, recorded = {}, emitted = {} }
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
        record_change = function(change)
          table.insert(cap.recorded, change)
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

    it("records a change to the log when its fileChange item completes", function()
      local r, cap = harness()
      local item = {
        type = "fileChange",
        id = "exec1",
        changes = { { path = "/z.txt", kind = { type = "update" }, diff = "@@\n-a\n+b\n" } },
      }
      -- started: captured for correlation, but NOT recorded yet
      r.feed_upstream({ method = "item/started", params = { item = item } }, "RAW_S")
      assert.equals(0, #cap.recorded)
      -- completed: recorded for on-demand review
      r.feed_upstream({ method = "item/completed", params = { item = item } }, "RAW_C")
      assert.equals(1, #cap.recorded)
      assert.equals("/z.txt", cap.recorded[1].path)
      assert.equals("update", cap.recorded[1].kind)
    end)
  end)

  describe("review (diff feedback)", function()
    it("declines the patch and types the comments into the TUI", function()
      local rejected = false
      local sent ---@type string?
      codex.review({
        comments = { { line = 3, text = "guard nil" }, { line = 8, text = "loop alloc" } },
        path = "/repo/x.lua",
        reject = function()
          rejected = true
        end,
        send_text = function(text)
          sent = text
        end,
        session = {} --[[@as harnt.Session]],
      })
      assert.is_true(rejected)
      local s = assert(sent)
      assert.is_truthy(s:find("x.lua", 1, true))
      assert.is_truthy(s:find("L3: guard nil", 1, true))
      assert.is_truthy(s:find("L8: loop alloc", 1, true))
    end)

    it("declines with no follow-up text when there are no comments", function()
      local rejected, sent = false, false
      codex.review({
        comments = {},
        path = "/repo/x.lua",
        reject = function()
          rejected = true
        end,
        send_text = function()
          sent = true
        end,
        session = {} --[[@as harnt.Session]],
      })
      assert.is_true(rejected)
      assert.is_false(sent)
    end)
  end)

  describe("/ide context channel", function()
    it("frame reader round-trips a length-prefixed JSON frame, tolerating chunking", function()
      local reader = codex._ide_frame_reader()
      local frame =
        codex._ide_response({ type = "request", requestId = "r1", method = "ide-context" })
      local mid = math.floor(#frame / 2)
      -- a partial frame yields nothing yet
      assert.same({}, reader.feed(frame:sub(1, mid)))
      local out = reader.feed(frame:sub(mid + 1))
      assert.equals(1, #out)
      assert.equals("response", out[1].type)
      assert.equals("r1", out[1].requestId)
      assert.equals("success", out[1].resultType)
      assert.equals("ide-context", out[1].method)
      assert.is_table(out[1].result.ideContext)
    end)

    it("reads two frames from one chunk", function()
      local reader = codex._ide_frame_reader()
      local two = codex._ide_response({ requestId = "a" })
        .. codex._ide_response({ requestId = "b" })
      local out = reader.feed(two)
      assert.equals(2, #out)
      assert.equals("a", out[1].requestId)
      assert.equals("b", out[2].requestId)
    end)

    it("_ide_context exposes activeFile + an openTabs list", function()
      local ctx = codex._ide_context()
      assert.is_not_nil(ctx.activeFile)
      assert.is_table(ctx.openTabs)
    end)
  end)

  describe("_reconstruct (full-file before/after)", function()
    --- Write lines to a fresh temp file and return its path.
    ---@param lines string[]
    local function tmpfile(lines)
      local p = vim.fn.tempname()
      vim.fn.writefile(lines, p)
      return p
    end

    it("applies a unified diff against the on-disk file to rebuild the whole file", function()
      local path = tmpfile({ "line one", "line two", "line three" })
      local diff = "@@ -2,1 +2,1 @@\n-line two\n+LINE TWO\n"
      local old, new = codex._reconstruct({ path = path, kind = "update", diff = diff })
      assert.same({ "line one", "line two", "line three" }, old)
      -- untouched lines preserved, only the hunk line changed
      assert.same({ "line one", "LINE TWO", "line three" }, new)
    end)

    it("handles a multi-line hunk with adds and removals, keeping the tail", function()
      local path = tmpfile({ "a", "b", "c", "d", "e" })
      local diff = "@@ -2,3 +2,2 @@\n b\n-c\n-d\n+C\n e\n"
      local _, new = codex._reconstruct({ path = path, kind = "update", diff = diff })
      assert.same({ "a", "b", "C", "e" }, new)
    end)

    it("treats an `add` with no hunk headers as full content, old empty", function()
      local old, new = codex._reconstruct({ path = "/nope.txt", kind = "add", diff = "hi\nthere" })
      assert.same({}, old)
      assert.same({ "hi", "there" }, new)
    end)

    it("empties the file for a `delete`", function()
      local path = tmpfile({ "gone", "soon" })
      local old, new = codex._reconstruct({ path = path, kind = "delete", diff = "" })
      assert.same({ "gone", "soon" }, old)
      assert.same({}, new)
    end)
  end)
end)
