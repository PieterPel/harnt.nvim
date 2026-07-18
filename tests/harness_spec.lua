---@diagnostic disable: undefined-field
-- (luassert extends `assert` with is_*/same/... which emmylua can't see)

-- Smoke test: proves the toolchain is wired up end to end — busted runs inside
-- Neovim (nlua) with the real API, and the plugin namespace is requireable
-- (the minimal_init helper put lua/ on the path). This is the M0 "loop is green"
-- gate; real service/provider specs replace it as they land.

describe("harness", function()
  it("runs inside Neovim with the real API", function()
    assert.is_table(vim)
    assert.is_function(vim.uv.new_timer)
    assert.is_function(vim.json.decode)
  end)

  it("can require the plugin namespace without error", function()
    assert.has_no.errors(function()
      require("harnt")
    end)
  end)
end)
