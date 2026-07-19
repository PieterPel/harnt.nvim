---@diagnostic disable: undefined-field, need-check-nil
-- luassert narrowing is invisible to emmylua.

local codex = require("harnt.providers.codex")

describe("codex provider", function()
  it("detect() returns a boolean", function()
    assert.is_boolean(codex.detect())
  end)

  it("env() exposes the Codex discovery vars", function()
    local env = codex.env({ host = "127.0.0.1", port = 4567, auth_token = "t", pid = 1 })
    assert.equals("4567", env.CODEX_CODE_SSE_PORT)
    assert.equals("true", env.ENABLE_IDE_INTEGRATION)
  end)

  it("shares the cc_ide tool set", function()
    local names = {}
    for _, tool in ipairs(codex.tools({})) do
      names[tool.name] = true
    end
    assert.is_true(names.openDiff)
    assert.is_true(names.getCurrentSelection)
    assert.is_true(names.getDiagnostics)
  end)

  it("reuses the shared cc_ide capabilities (same fns as claude)", function()
    local claude = require("harnt.providers.claude")
    assert.equals(claude.tools, codex.tools)
    assert.equals(claude.review, codex.review)
    assert.equals(claude.on_selection, codex.on_selection)
  end)

  it("uses env-only discovery (no lockfile writes)", function()
    assert.has_no.errors(function()
      codex.discovery.write({ host = "127.0.0.1", port = 1, auth_token = "t", pid = 1 })
      codex.discovery.remove({ host = "127.0.0.1", port = 1, auth_token = "t", pid = 1 })
    end)
  end)

  it("start() returns a session with connection info", function()
    local session = codex.start({})
    assert.is_true(session.info.port > 0)
    session:stop()
  end)
end)
