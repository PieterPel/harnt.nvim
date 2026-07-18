---@diagnostic disable: undefined-field, need-check-nil
-- (luassert extends `assert`; its narrowing is invisible to emmylua)

local diff = require("harnt.services.diff")

after_each(function()
  -- close any stray diff tabs so tests don't leak window state
  while vim.fn.tabpagenr("$") > 1 do
    vim.cmd("tabclose")
  end
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
end)

describe("diff.accept", function()
  it("writes the proposed content and resolves accepted=true", function()
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
  end)

  it("honors edits made to the proposal buffer (accept with edits)", function()
    local path = vim.fn.tempname() .. ".txt"
    local result
    local id = diff.open({ path = path, proposed = { "original proposal" } }, function(r)
      result = r
    end)

    -- user edits the right-hand diff buffer before accepting
    local pbuf = diff.proposed_bufnr(id)
    assert(pbuf)
    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, { "edited", "proposal" })
    diff.accept(id)

    assert.same({ "edited", "proposal" }, result.content)
    assert.same({ "edited", "proposal" }, vim.fn.readfile(path))
  end)
end)

describe("diff.reject", function()
  it("resolves accepted=false and leaves the file untouched", function()
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
  end)
end)

describe("diff.accept/reject on an unknown id", function()
  it("accept returns an error, reject is a no-op", function()
    local ok, err = diff.accept(4242)
    assert.is_false(ok)
    assert.is_string(err)
    assert.has_no.errors(function()
      diff.reject(4242)
    end)
  end)
end)
