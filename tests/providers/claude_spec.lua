---@diagnostic disable: undefined-field, need-check-nil, inject-field, missing-fields, param-type-mismatch, call-non-callable
-- luassert narrowing is invisible to emmylua; tests monkeypatch the diff service,
-- set $CLAUDE_CONFIG_DIR, and pass partial session/ctx literals.

local claude = require("harnt.providers.claude")
local diff = require("harnt.services.diff")

local function by_name(tools, name)
  for _, tool in ipairs(tools) do
    if tool.name == name then
      return tool
    end
  end
end

local function read_json(path)
  return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end

describe("claude.detect", function()
  it("returns a boolean", function()
    assert.is_boolean(claude.detect())
  end)
end)

describe("claude.env", function()
  it("exposes the discovery env vars as strings", function()
    local env = claude.env({ host = "127.0.0.1", port = 1234, auth_token = "t", pid = 1 })
    assert.equals("1234", env.CLAUDE_CODE_SSE_PORT)
    assert.equals("true", env.ENABLE_IDE_INTEGRATION)
  end)
end)

describe("claude.tools", function()
  it("exposes the expected tool set", function()
    local names = {}
    for _, tool in ipairs(claude.tools({})) do
      names[tool.name] = true
    end
    assert.is_true(names.openDiff)
    assert.is_true(names.getDiagnostics)
    assert.is_true(names.getCurrentSelection)
    assert.is_true(names.closeAllDiffTabs)
    assert.is_true(names.close_tab)
  end)

  it("close_tab acks and closes any lingering diff", function()
    diff.set_presenter(function()
      return { teardown = function() end }
    end)
    diff.open({ path = "/x", proposed = {} }, function() end)
    local text
    by_name(claude.tools({}), "close_tab").handler(
      { tab_name = "Proposed changes" },
      function(result)
        text = result.content[1].text
      end
    )
    diff.set_presenter(nil)
    assert.equals("TAB_CLOSED", text)
    assert.equals(0, diff.open_count())
  end)

  it("openDiff proposes the new contents and reports FILE_SAVED on accept", function()
    local orig_open = diff.open
    ---@type table
    local captured
    diff.open = function(spec, cb)
      captured = { spec = spec, cb = cb }
      return 1
    end

    local text
    by_name(claude.tools({}), "openDiff").handler({
      old_file_path = "/a.lua",
      new_file_path = "/b.lua",
      new_file_contents = "line1\nline2",
    }, function(result)
      text = result.content[1].text
    end)
    diff.open = orig_open

    assert.equals("/b.lua", captured.spec.path)
    assert.same({ "line1", "line2" }, captured.spec.proposed)

    local change_log = require("harnt.services.changes")
    change_log.clear()
    captured.cb({ accepted = true, content = { "line1", "line2" } })
    assert.equals("FILE_SAVED", text)
    -- the accepted change is recorded to the session change-log
    assert.equals(1, change_log.count())
    assert.equals("/b.lua", change_log.list()[1].path)
    assert.equals("claude", change_log.list()[1].provider)
  end)

  it("openDiff reports DIFF_REJECTED on reject", function()
    local orig_open = diff.open
    ---@type table
    local captured
    diff.open = function(spec, cb)
      captured = { spec = spec, cb = cb }
      return 1
    end
    local text
    by_name(claude.tools({}), "openDiff").handler(
      { old_file_path = "/a", new_file_path = "/a", new_file_contents = "x" },
      function(result)
        text = result.content[1].text
      end
    )
    diff.open = orig_open
    local change_log = require("harnt.services.changes")
    change_log.clear()
    captured.cb({ accepted = false })
    assert.equals("DIFF_REJECTED", text)
    -- a rejected change is not recorded
    assert.equals(0, change_log.count())
  end)

  it("getCurrentSelection reports success=false with no selection", function()
    vim.cmd("enew")
    pcall(vim.api.nvim_buf_del_mark, 0, "<")
    pcall(vim.api.nvim_buf_del_mark, 0, ">")
    local decoded
    by_name(claude.tools({}), "getCurrentSelection").handler({}, function(result)
      decoded = vim.json.decode(result.content[1].text)
    end)
    assert.is_false(decoded.success)
  end)

  it("closeAllDiffTabs reports the number closed", function()
    diff.set_presenter(function()
      return { teardown = function() end }
    end)
    diff.open({ path = "/x", proposed = {} }, function() end)
    diff.open({ path = "/y", proposed = {} }, function() end)
    local text
    by_name(claude.tools({}), "closeAllDiffTabs").handler({}, function(result)
      text = result.content[1].text
    end)
    diff.set_presenter(nil)
    assert.equals("CLOSED_2_DIFF_TABS", text)
  end)
end)

describe("claude context push", function()
  it("on_selection pushes selection_changed via the session", function()
    vim.cmd("enew")
    local pushed
    claude.on_selection({
      push = function(_s, method, params)
        pushed = { method = method, params = params }
      end,
    })
    assert.equals("selection_changed", pushed.method)
    assert.is_true(pushed.params.selection.isEmpty)
  end)

  it("on_mention pushes at_mentioned via the session", function()
    vim.cmd("enew")
    local pushed
    claude.on_mention({
      push = function(_s, method, params)
        pushed = { method = method, params = params }
      end,
    })
    assert.equals("at_mentioned", pushed.method)
    assert.is_number(pushed.params.lineStart)
  end)
end)

describe("claude.review", function()
  it("rejects and formats comments as a follow-up prompt", function()
    local rejected, sent
    claude.review({
      comments = { { line = 5, text = "guard" }, { line = 9, text = "loop alloc" } },
      path = "/tmp/x.lua",
      reject = function()
        rejected = true
      end,
      send_text = function(text)
        sent = text
      end,
      session = {},
    })
    assert.is_true(rejected)
    assert.is_truthy(sent:find("L5: guard"))
    assert.is_truthy(sent:find("L9: loop alloc"))
  end)

  it("with no comments just rejects", function()
    local rejected, sent
    claude.review({
      comments = {},
      path = "/x",
      reject = function()
        rejected = true
      end,
      send_text = function(text)
        sent = text
      end,
      session = {},
    })
    assert.is_true(rejected)
    assert.is_nil(sent)
  end)
end)

describe("claude discovery + start", function()
  it("writes and removes the lockfile", function()
    local orig = vim.env.CLAUDE_CONFIG_DIR
    local tmp = vim.fn.tempname()
    vim.env.CLAUDE_CONFIG_DIR = tmp

    local info = { host = "127.0.0.1", port = 45678, auth_token = "deadbeef", pid = 42 }
    claude.discovery.write(info)
    local path = tmp .. "/ide/45678.lock"
    assert.equals(1, vim.fn.filereadable(path))

    local data = read_json(path)
    assert.equals("Neovim", data.ideName)
    assert.equals("ws", data.transport)
    assert.equals("deadbeef", data.authToken)
    assert.equals(42, data.pid)

    claude.discovery.remove(info)
    assert.equals(0, vim.fn.filereadable(path))

    vim.env.CLAUDE_CONFIG_DIR = orig
  end)

  it("start() advertises a lockfile whose token matches the session; stop() removes it", function()
    local orig = vim.env.CLAUDE_CONFIG_DIR
    local tmp = vim.fn.tempname()
    vim.env.CLAUDE_CONFIG_DIR = tmp

    local session = claude.start({})
    local path = tmp .. "/ide/" .. session.info.port .. ".lock"
    assert.equals(1, vim.fn.filereadable(path))

    local data = read_json(path)
    assert.equals(session.info.auth_token, data.authToken)
    assert.equals("ws", data.transport)

    session:stop()
    assert.equals(0, vim.fn.filereadable(path))

    vim.env.CLAUDE_CONFIG_DIR = orig
  end)
end)
