---@diagnostic disable: undefined-field, need-check-nil
-- (luassert extends `assert`; its narrowing is invisible to emmylua)

local diff = require("harnt.services.diff")

---@type harnt.diff.View?
local last_view
local teardowns

before_each(function()
  -- Inject a headless presenter: record what it was handed, count teardowns.
  last_view = nil
  teardowns = 0
  diff.set_presenter(function(view)
    last_view = view
    return {
      teardown = function()
        teardowns = teardowns + 1
      end,
    }
  end)
end)

after_each(function()
  diff.set_presenter(nil)
end)

describe("diff.open", function()
  it("creates a proposal buffer with the proposed content and the guard flag", function()
    local id = diff.open({ path = "/tmp/x.lua", proposed = { "a", "b" } }, function() end)
    local pbuf = diff.proposed_bufnr(id)
    assert(pbuf, "expected a proposal buffer")
    assert.same({ "a", "b" }, vim.api.nvim_buf_get_lines(pbuf, 0, -1, false))
    assert.is_true(vim.b[pbuf].harnt_diff)
    assert.equals(1, diff.open_count())
    diff.reject(id)
  end)

  it("hands the presenter both buffers and the path (presentation is injectable)", function()
    local id = diff.open(
      { path = "/tmp/y.lua", proposed = { "p" }, original = { "o" } },
      function() end
    )
    assert.is_table(last_view)
    assert.equals("/tmp/y.lua", last_view.path)
    assert.same({ "o" }, vim.api.nvim_buf_get_lines(last_view.original_buf, 0, -1, false))
    assert.same({ "p" }, vim.api.nvim_buf_get_lines(last_view.proposed_buf, 0, -1, false))
    diff.reject(id)
  end)
end)

describe("diff.accept", function()
  it("writes the proposed content, resolves accepted=true, tears down the UI", function()
    local path = vim.fn.tempname() .. ".txt"
    local result
    local id = diff.open({ path = path, proposed = { "hello", "world" } }, function(r)
      result = r
    end)

    local ok = diff.accept(id)
    assert.is_true(ok)
    assert.is_true(result.accepted)
    assert.same({ "hello", "world" }, result.content)
    assert.same({ "hello", "world" }, vim.fn.readfile(path))
    assert.equals(0, diff.open_count())
    assert.equals(1, teardowns)
  end)

  it("honors edits made to the proposal buffer (accept with edits)", function()
    local path = vim.fn.tempname() .. ".txt"
    local result
    local id = diff.open({ path = path, proposed = { "original proposal" } }, function(r)
      result = r
    end)

    local pbuf = diff.proposed_bufnr(id)
    assert(pbuf)
    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, { "edited", "proposal" })
    diff.accept(id)

    assert.same({ "edited", "proposal" }, result.content)
    assert.same({ "edited", "proposal" }, vim.fn.readfile(path))
  end)
end)

describe("diff.reject", function()
  it("resolves accepted=false, leaves the file untouched, tears down the UI", function()
    local path = vim.fn.tempname() .. ".txt"
    vim.fn.writefile({ "keep me" }, path)

    local result
    local id = diff.open({ path = path, proposed = { "unwanted" } }, function(r)
      result = r
    end)
    diff.reject(id)

    assert.is_false(result.accepted)
    assert.is_nil(result.content)
    assert.same({ "keep me" }, vim.fn.readfile(path))
    assert.equals(0, diff.open_count())
    assert.equals(1, teardowns)
  end)
end)

describe("diff on an unknown id", function()
  it("accept returns an error, reject is a no-op", function()
    local ok, err = diff.accept(4242)
    assert.is_false(ok)
    assert.is_string(err)
    assert.has_no.errors(function()
      diff.reject(4242)
    end)
  end)
end)

describe("diff default presenter", function()
  it("opens and tears down a real diff tab without error (headless smoke)", function()
    diff.set_presenter(nil) -- use the real side-by-side vimdiff
    local baseline = vim.fn.tabpagenr("$")
    local id = diff.open({ path = "/tmp/z.lua", proposed = { "a" } }, function() end)
    assert.is_true(vim.fn.tabpagenr("$") > baseline)
    diff.reject(id)
    assert.equals(baseline, vim.fn.tabpagenr("$"))
  end)
end)

describe("diff.reject_all", function()
  it("rejects every open diff and returns the count", function()
    local r1, r2
    diff.open({ path = "/tmp/a", proposed = {} }, function(r)
      r1 = r
    end)
    diff.open({ path = "/tmp/b", proposed = {} }, function(r)
      r2 = r
    end)
    assert.equals(2, diff.open_count())

    assert.equals(2, diff.reject_all())
    assert.equals(0, diff.open_count())
    assert.is_false(r1.accepted)
    assert.is_false(r2.accepted)
  end)
end)
