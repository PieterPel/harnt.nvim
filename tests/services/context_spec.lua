---@diagnostic disable: undefined-field, need-check-nil
-- (luassert extends `assert` with is_*/same/...; and luassert's is_table narrowing
-- is invisible to emmylua, so accessing fields after it looks like a nil deref)

local context = require("harnt.services.context")

--- Create a fresh listed buffer with the given name + lines, make it current.
---@param name string
---@param lines string[]
---@return integer bufnr
local function make_buffer(name, lines)
  local bufnr = vim.api.nvim_create_buf(true, false)
  if name ~= "" then
    vim.api.nvim_buf_set_name(bufnr, name)
  end
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
end

describe("context.cursor", function()
  it("reports 1-based row and 0-based col", function()
    make_buffer("", { "hello world", "second line" })
    vim.api.nvim_win_set_cursor(0, { 2, 3 })
    assert.same({ row = 2, col = 3 }, context.cursor())
  end)
end)

describe("context.buffers", function()
  it("lists loaded, listed buffers with absolute paths and the active flag", function()
    local bufnr = make_buffer(vim.fn.tempname() .. ".lua", { "x" })
    local buffers = context.buffers()

    local found
    for _, b in ipairs(buffers) do
      if b.bufnr == bufnr then
        found = b
      end
    end

    assert.is_table(found)
    assert.is_true(found.active)
    assert.equals("/", found.path:sub(1, 1)) -- absolute
  end)

  it("excludes unlisted buffers", function()
    local bufnr = vim.api.nvim_create_buf(false, true) -- nolisted, scratch
    for _, b in ipairs(context.buffers()) do
      assert.is_not.equal(bufnr, b.bufnr)
    end
  end)
end)

describe("context.diagnostics", function()
  it("normalizes severity, row (1-based) and col", function()
    local bufnr = make_buffer("", { "local x = 1", "bad line" })
    local ns = vim.api.nvim_create_namespace("harnt_test_diag")
    vim.diagnostic.set(ns, bufnr, {
      {
        lnum = 1,
        col = 4,
        severity = vim.diagnostic.severity.ERROR,
        message = "boom",
        source = "test",
      },
    })

    local diags = context.diagnostics(bufnr)
    assert.equals(1, #diags)
    assert.equals("error", diags[1].severity)
    assert.equals(2, diags[1].row)
    assert.equals(4, diags[1].col)
    assert.equals("boom", diags[1].message)
    assert.equals("test", diags[1].source)

    vim.diagnostic.reset(ns, bufnr)
  end)
end)

describe("context.workspace_roots", function()
  it("includes the current working directory", function()
    local roots = context.workspace_roots()
    assert.is_true(#roots >= 1)
    assert.equals(vim.uv.cwd(), roots[1])
  end)
end)

describe("context.selection", function()
  it("returns nil when there is no selection", function()
    local bufnr = make_buffer("", { "no selection here" })
    -- clear any leftover marks from a previous test
    pcall(vim.api.nvim_buf_del_mark, bufnr, "<")
    pcall(vim.api.nvim_buf_del_mark, bufnr, ">")
    assert.is_nil(context.selection())
  end)

  it("extracts the marked range text", function()
    local bufnr = make_buffer("", { "hello world", "second line" })
    -- select "world" on line 1 (cols 6..10, 0-based start col 6, inclusive end 10)
    vim.api.nvim_buf_set_mark(bufnr, "<", 1, 6, {})
    vim.api.nvim_buf_set_mark(bufnr, ">", 1, 10, {})

    local sel = context.selection()
    assert.is_table(sel)
    assert.equals("world", sel.text)
    assert.same({ row = 1, col = 6 }, sel.start)
  end)
end)

describe("context.snapshot", function()
  it("aggregates the individual pieces", function()
    make_buffer("", { "abc" })
    local snap = context.snapshot()
    assert.is_table(snap.cursor)
    assert.is_table(snap.buffers)
    assert.is_table(snap.diagnostics)
    assert.is_table(snap.roots)
  end)
end)
