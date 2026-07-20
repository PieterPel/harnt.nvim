---@diagnostic disable: undefined-field, need-check-nil, missing-fields, call-non-callable
-- luassert narrowing is invisible to emmylua; session stubs are partial by design,
-- and recorded-callback fields on the fake `cap` table read back as untyped.

local events = require("harnt.events")
local opencode = require("harnt.providers.opencode")

describe("opencode provider", function()
  it("detect() returns a boolean", function()
    assert.is_boolean(opencode.detect())
  end)

  it("health() emits diagnostics via the report adapter", function()
    local calls = {}
    local function rec(m)
      calls[#calls + 1] = m
    end
    opencode.health({ ok = rec, warn = rec, error = rec, info = rec })
    assert.is_true(#calls > 0)
  end)

  it("cmd() attaches the native TUI to the served HTTP endpoint", function()
    local cmd = opencode.cmd({
      info = { server_url = "http://127.0.0.1:4096", port = 4096 },
    } --[[@as harnt.opencode.Session]])
    assert.same({ "opencode", "attach", "http://127.0.0.1:4096" }, cmd)
  end)

  it("on_mention appends a native @path mention to the TUI prompt", function()
    local buf = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(buf, vim.fn.getcwd() .. "/lua/harnt/init.lua")
    vim.api.nvim_set_current_buf(buf)

    local appended
    -- on_mention takes a MentionContext; opencode delivers via its session's
    -- append_prompt (the /tui/append-prompt channel).
    opencode.on_mention({
      session = {
        append_prompt = function(text)
          appended = text
        end,
      },
    } --[[@as harnt.MentionContext]])

    assert.is_string(appended)
    -- workspace-relative @mention (no leading slash), ending with a space
    assert.is_truthy(appended:find("^@"))
    assert.is_truthy(appended:find("init%.lua "))
    assert.is_nil(appended:find("@/")) -- relativized, not absolute
    vim.api.nvim_buf_delete(buf, { force = true })
  end)

  describe("SSE tap (_router)", function()
    --- Build a router wired to recording fakes.
    local function harness()
      local cap = { asks = {}, reviews = {}, replies = {}, recorded = {}, notes = {}, emitted = {} }
      local router = opencode._router({
        ask_permission = function(perm, done)
          table.insert(cap.asks, { perm = perm, done = done })
        end,
        open_edit_review = function(rendered, done)
          table.insert(cap.reviews, { rendered = rendered, done = done })
        end,
        reply_permission = function(sid, rid, reply, message)
          table.insert(cap.replies, { sid = sid, rid = rid, reply = reply, message = message })
        end,
        record_change = function(change)
          table.insert(cap.recorded, change)
        end,
        note_permission = function(perm)
          -- wrap so a `nil` note (permission cleared) is still a recorded call
          cap.notes[#cap.notes + 1] = { perm }
        end,
        emit = function(ev, p)
          table.insert(cap.emitted, { ev = ev, p = p })
        end,
      })
      return router, cap
    end

    it("ignores malformed events", function()
      local r, cap = harness()
      r.feed(nil)
      r.feed({})
      r.feed({ type = 123 })
      assert.equals(0, #cap.asks)
      assert.equals(0, #cap.emitted)
    end)

    it(
      "routes a non-correlatable permission to the approval popup; allow_once → reply 'once'",
      function()
        local r, cap = harness()
        r.feed({
          type = "permission.v2.asked",
          properties = {
            id = "per_1",
            sessionID = "ses_1",
            action = "webfetch", -- no cached tool call → plain approval, not a diff
            resources = { "https://x" },
          },
        })
        assert.equals(1, #cap.asks)
        assert.equals(0, #cap.reviews)
        -- it is remembered as the open permission
        assert.equals("per_1", cap.notes[1][1].id)

        cap.asks[1].done("allow_once")
        assert.same({ sid = "ses_1", rid = "per_1", reply = "once", message = nil }, cap.replies[1])

        -- approval.requested then approval.resolved(allowed=true)
        local kinds = {}
        for _, e in ipairs(cap.emitted) do
          kinds[#kinds + 1] = e.ev
        end
        assert.is_true(vim.tbl_contains(kinds, events.TYPES.approval_requested))
        local resolved = cap.emitted[#cap.emitted]
        assert.equals(events.TYPES.approval_resolved, resolved.ev)
        assert.is_true(resolved.p.allowed)
      end
    )

    it("maps allow_always → 'always' and both deny variants → 'reject'", function()
      for decision, expected in pairs({
        allow_always = "always",
        deny_once = "reject",
        deny_always = "reject",
      }) do
        local r, cap = harness()
        r.feed({
          type = "permission.v2.asked",
          properties = { id = "per", sessionID = "ses", action = "bash" },
        })
        cap.asks[1].done(decision)
        assert.equals(expected, cap.replies[1].reply)
      end
    end)

    it("shows an edit permission as a diff review (correlated via source.callID)", function()
      local r, cap = harness()
      -- the tool call arrives first, carrying the proposed edit...
      r.feed({
        type = "session.next.tool.called",
        properties = {
          tool = "edit",
          callID = "call_9",
          input = { filePath = "src/app.ts", oldString = "old", newString = "new" },
        },
      })
      -- ...then the permission that references it.
      r.feed({
        type = "permission.v2.asked",
        properties = {
          id = "per_2",
          sessionID = "ses_2",
          action = "edit",
          resources = { "src/app.ts" },
          source = { type = "tool", callID = "call_9", messageID = "msg_1" },
        },
      })
      assert.equals(0, #cap.asks) -- NOT a plain approval
      assert.equals(1, #cap.reviews)
      assert.equals("src/app.ts", cap.reviews[1].rendered.path)
      local patch = table.concat(cap.reviews[1].rendered.lines, "\n")
      assert.is_truthy(patch:find("-old", 1, true))
      assert.is_truthy(patch:find("+new", 1, true))

      -- accept → reply 'once'
      cap.reviews[1].done(true, nil)
      assert.same({ sid = "ses_2", rid = "per_2", reply = "once", message = nil }, cap.replies[1])
      local resolved = cap.emitted[#cap.emitted]
      assert.equals(events.TYPES.approval_resolved, resolved.ev)
      assert.is_true(resolved.p.allowed)
    end)

    it("reject on an edit diff replies 'reject' with the comments as feedback", function()
      local r, cap = harness()
      r.feed({
        type = "session.next.tool.called",
        properties = {
          tool = "write",
          callID = "c1",
          input = { filePath = "new.txt", content = "hi" },
        },
      })
      r.feed({
        type = "permission.v2.asked",
        properties = {
          id = "p",
          sessionID = "s",
          action = "write",
          source = { callID = "c1" },
        },
      })
      assert.equals(1, #cap.reviews)
      cap.reviews[1].done(false, "please rename it")
      assert.equals("reject", cap.replies[1].reply)
      assert.equals("please rename it", cap.replies[1].message)
      assert.is_false(cap.emitted[#cap.emitted].p.allowed)
    end)

    it("permission.v2.replied clears the open permission", function()
      local r, cap = harness()
      r.feed({ type = "permission.v2.replied", properties = { id = "per_1" } })
      -- note_permission(nil) called: one recorded call, carrying nil
      assert.equals(1, #cap.notes)
      assert.is_nil(cap.notes[1][1])
    end)

    it("records each changed file from session.diff exactly once (dedup)", function()
      local r, cap = harness()
      local function diff_event(files)
        return { type = "session.diff", properties = { sessionID = "ses", diff = files } }
      end
      -- first snapshot: one file
      r.feed(diff_event({
        { file = "a.txt", status = "modified", patch = "@@ -1 +1 @@\n-x\n+y\n" },
      }))
      -- cumulative snapshot re-sends a.txt (unchanged) + adds b.txt
      r.feed(diff_event({
        { file = "a.txt", status = "modified", patch = "@@ -1 +1 @@\n-x\n+y\n" },
        { file = "b.txt", status = "added", patch = "@@ -0,0 +1 @@\n+hi\n" },
      }))
      assert.equals(2, #cap.recorded)
      assert.equals("a.txt", cap.recorded[1].path)
      assert.equals("b.txt", cap.recorded[2].path)
    end)

    it("re-records a file when its patch changes", function()
      local r, cap = harness()
      local function diff_event(patch)
        return {
          type = "session.diff",
          properties = { diff = { { file = "a.txt", status = "modified", patch = patch } } },
        }
      end
      r.feed(diff_event("v1"))
      r.feed(diff_event("v1")) -- unchanged: skipped
      r.feed(diff_event("v2")) -- changed: recorded again
      assert.equals(2, #cap.recorded)
    end)

    it("maps tool events to canonical tool.started / tool.completed", function()
      local r, cap = harness()
      r.feed({ type = "session.next.tool.called", properties = { tool = "edit" } })
      r.feed({ type = "session.next.tool.success", properties = { tool = "edit" } })
      r.feed({ type = "session.next.tool.failed", properties = { tool = "bash" } })
      assert.equals(events.TYPES.tool_started, cap.emitted[1].ev)
      assert.equals(events.TYPES.tool_completed, cap.emitted[2].ev)
      assert.is_true(cap.emitted[2].p.ok)
      assert.equals(events.TYPES.tool_completed, cap.emitted[3].ev)
      assert.is_false(cap.emitted[3].p.ok)
    end)

    it("maps session.error to session.failed", function()
      local r, cap = harness()
      r.feed({ type = "session.error", properties = {} })
      assert.equals(events.TYPES.session_failed, cap.emitted[1].ev)
    end)
  end)
end)
