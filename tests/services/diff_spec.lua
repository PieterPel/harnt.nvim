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
    assert(last_view, "presenter should have run")
    assert.equals("/tmp/y.lua", last_view.path)
    assert.same({ "o" }, vim.api.nvim_buf_get_lines(assert(last_view.original_buf), 0, -1, false))
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

describe("diff comments", function()
  it("stores comments and exposes them + the target path", function()
    local id = diff.open({ path = "/tmp/f.lua", proposed = { "a", "b" } }, function() end)
    diff.add_comment(id, 2, "fix this")
    diff.add_comment(id, 1, "and this")
    local comments = diff.comments(id)
    assert.equals(2, #comments)
    assert.equals("fix this", comments[1].text)
    assert.equals(2, comments[1].line)
    assert.equals("/tmp/f.lua", diff.target(id))
    diff.reject(id)
  end)

  it("tags and exposes the origin provider, and folds comments into the result", function()
    local got
    local id = diff.open_review(
      { path = "/tmp/f.lua", diff = "@@\n-a\n+b", origin = "codex" },
      function(r)
        got = r
      end
    )
    assert.equals("codex", diff.origin(id))
    diff.add_comment(id, 3, "guard nil")
    diff.reject(id)
    assert.is_false(got.accepted)
    assert.equals("guard nil", got.comments[1].text)
    assert.is_nil(diff.origin(id)) -- gone after teardown
  end)

  it("returns empty comments and nil target for an unknown diff", function()
    assert.same({}, diff.comments(9999))
    assert.is_nil(diff.target(9999))
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

  it("shows the configured accept/reject keys in the winbar", function()
    diff.set_presenter(nil)
    diff.set_keys({ accept = "<F5>", reject = "<F6>" })
    local id = diff.open({ path = "/tmp/z.lua", proposed = { "a" } }, function() end)

    local pbuf = diff.proposed_bufnr(id)
    assert(pbuf)
    local win = vim.fn.win_findbuf(pbuf)[1]
    local winbar = vim.wo[win].winbar
    assert.is_truthy(winbar:find("F5"))
    assert.is_truthy(winbar:find("accept"))

    diff.reject(id)
    diff.set_keys({ accept = "<leader>a", reject = "<leader>r" }) -- restore default
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

describe("diff.current / diff.for_buffer", function()
  it("resolves the current diff by its proposal buffer", function()
    local id = diff.open({ path = "/x", proposed = { "a" } }, function() end)
    local pbuf = diff.proposed_bufnr(id)
    assert(pbuf)
    vim.api.nvim_set_current_buf(pbuf)
    assert.equals(id, diff.for_buffer(pbuf))
    assert.equals(id, diff.current())
    diff.reject(id)
  end)

  it("current() falls back to the sole open diff", function()
    local id = diff.open({ path = "/x", proposed = {} }, function() end)
    vim.cmd("enew")
    assert.equals(id, diff.current())
    diff.reject(id)
  end)

  it("current() is nil when ambiguous and not in a diff buffer", function()
    local a = diff.open({ path = "/a", proposed = {} }, function() end)
    local b = diff.open({ path = "/b", proposed = {} }, function() end)
    vim.cmd("enew")
    assert.is_nil(diff.current())
    diff.reject(a)
    diff.reject(b)
  end)
end)

describe("diff.open_review (review-only)", function()
  ---@type harnt.diff.View?
  local review_view
  before_each(function()
    review_view = nil
    diff.set_review_presenter(function(view)
      review_view = view
      return { teardown = function() end }
    end)
  end)
  after_each(function()
    diff.set_review_presenter(nil)
  end)

  it("renders the patch in a guarded scratch buffer", function()
    local id = diff.open_review({ path = "/x.txt", diff = "@@ -1 +1 @@\n-a\n+b" }, function() end)
    assert(review_view, "review presenter should have been called")
    assert.same(
      { "@@ -1 +1 @@", "-a", "+b" },
      vim.api.nvim_buf_get_lines(review_view.proposed_buf, 0, -1, false)
    )
    assert.is_true(vim.b[review_view.proposed_buf].harnt_diff)
    assert.equals(1, diff.open_count())
    diff.reject(id)
  end)

  it("accept resolves accepted=true WITHOUT writing to disk (the agent applies)", function()
    local path = vim.fn.tempname()
    vim.fn.writefile({ "ORIGINAL" }, path)
    local result
    local id = diff.open_review({ path = path, diff = "+NEW" }, function(r)
      result = r
    end)
    diff.accept(id)
    assert.is_true(result.accepted)
    -- the file on disk is untouched: review-only never calls apply
    assert.same({ "ORIGINAL" }, vim.fn.readfile(path))
    vim.fn.delete(path)
  end)

  it("reject resolves accepted=false", function()
    local result
    local id = diff.open_review({ path = "/x", diff = "+z" }, function(r)
      result = r
    end)
    diff.reject(id)
    assert.is_false(result.accepted)
  end)

  it("supports line comments on the patch buffer", function()
    local id = diff.open_review({ path = "/x", diff = "a\nb\nc" }, function() end)
    diff.add_comment(id, 2, "look here")
    assert.same({ { line = 2, text = "look here" } }, diff.comments(id))
    diff.reject(id)
  end)
end)
