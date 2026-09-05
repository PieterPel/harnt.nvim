---@diagnostic disable: undefined-field, need-check-nil
-- (luassert extends `assert`; its narrowing is invisible to emmylua)

local diff = require("harnt.services.diff")

-- Namespaces are looked up by name, so this resolves to the same id the
-- inline presenter uses internally (services/diff/presenters.lua) without
-- either module exposing it.
local inline_ns = vim.api.nvim_create_namespace("harnt_diff_inline")

after_each(function()
  diff.set_presenter(nil)
end)

describe("diff.presenters", function()
  it("exposes the built-in split/review/inline/docked presenters", function()
    assert.is_function(diff.presenters.split)
    assert.is_function(diff.presenters.review)
    assert.is_function(diff.presenters.inline)
    assert.is_function(diff.presenters.docked)
  end)
end)

describe("diff.presenters.inline", function()
  it("lays the proposal out in a single editable window", function()
    diff.set_presenter(diff.presenters.inline)
    local baseline = vim.fn.tabpagenr("$")
    local id = diff.open(
      { path = "/tmp/z.lua", proposed = { "a" }, original = { "a" } },
      function() end
    )
    assert.is_true(vim.fn.tabpagenr("$") > baseline)
    local pbuf = diff.proposed_bufnr(id)
    assert(pbuf)
    assert.equals(1, #vim.fn.win_findbuf(pbuf))
    diff.reject(id)
    assert.equals(baseline, vim.fn.tabpagenr("$"))
  end)

  it("highlights a changed line and overlays the removed line above it", function()
    diff.set_presenter(diff.presenters.inline)
    local id = diff.open({
      path = "/tmp/z.lua",
      proposed = { "one", "TWO", "three" },
      original = { "one", "two", "three" },
    }, function() end)
    local pbuf = diff.proposed_bufnr(id)
    assert(pbuf)
    local marks = vim.api.nvim_buf_get_extmarks(pbuf, inline_ns, 0, -1, { details = true })
    assert.equals(2, #marks)

    local has_virt_lines, has_line_hl = false, false
    for _, m in ipairs(marks) do
      local details = m[4]
      if details.virt_lines then
        has_virt_lines = true
        assert.is_truthy(details.virt_lines[1][1][1]:find("two"))
        assert.is_true(details.virt_lines_above)
      elseif details.line_hl_group then
        has_line_hl = true
        assert.equals("HarntInlineAdd", details.line_hl_group)
        assert.equals(1, m[2]) -- 0-indexed row of "TWO"
      end
    end
    assert.is_true(has_virt_lines)
    assert.is_true(has_line_hl)

    diff.reject(id)
  end)

  it("overlays a pure deletion below the last surviving line", function()
    diff.set_presenter(diff.presenters.inline)
    local id = diff.open({
      path = "/tmp/z.lua",
      proposed = { "one", "two" },
      original = { "one", "two", "three" },
    }, function() end)
    local pbuf = diff.proposed_bufnr(id)
    assert(pbuf)
    local marks = vim.api.nvim_buf_get_extmarks(pbuf, inline_ns, 0, -1, { details = true })
    assert.equals(1, #marks)
    local details = marks[1][4]
    assert.is_truthy(details.virt_lines[1][1][1]:find("three"))
    assert.is_falsy(details.virt_lines_above)

    diff.reject(id)
  end)
end)

describe("HarntInline highlight defaults", function()
  it("links to the standard Diff* groups by default", function()
    assert.equals("DiffAdd", vim.api.nvim_get_hl(0, { name = "HarntInlineAdd" }).link)
    assert.equals("DiffDelete", vim.api.nvim_get_hl(0, { name = "HarntInlineDelete" }).link)
  end)
end)

describe("diff.presenters.docked", function()
  it("opens a split in the CURRENT tab instead of a new one", function()
    diff.set_presenter(diff.presenters.docked)
    local baseline_tab = vim.fn.tabpagenr("$")
    local baseline_win = vim.api.nvim_get_current_win()
    local id = diff.open(
      { path = "/tmp/z.lua", proposed = { "a" }, original = { "a" } },
      function() end
    )
    assert.equals(baseline_tab, vim.fn.tabpagenr("$")) -- no new tab

    local pbuf = diff.proposed_bufnr(id)
    assert(pbuf)
    local wins = vim.fn.win_findbuf(pbuf)
    assert.equals(1, #wins)
    assert.are_not.equals(baseline_win, wins[1]) -- a real split, not reused

    diff.reject(id)
    assert.equals(baseline_tab, vim.fn.tabpagenr("$"))
  end)

  it(
    "does not evict an existing right-docked window (e.g. the terminal) from the tab's edge",
    function()
      -- Regression test: the docked presenter used to open via
      -- `vertical botright split`, which — like terminal.lua's own
      -- `botright vsplit` — always claims the tabpage's absolute right edge.
      -- Whichever opened last would evict the other from that slot, so an
      -- already-open terminal would visibly get shoved left when a docked
      -- diff opened. Reproduce that layout (terminal at the true right edge,
      -- focus back on the "main" window, as it would be while reviewing a
      -- file) and assert the terminal stays the rightmost window.
      vim.cmd("botright vsplit")
      local term_win = vim.api.nvim_get_current_win()
      vim.cmd("wincmd h")

      diff.set_presenter(diff.presenters.docked)
      local id = diff.open(
        { path = "/tmp/z.lua", proposed = { "a" }, original = { "a" } },
        function() end
      )

      local rightmost, max_col = nil, -1
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local col = vim.fn.win_screenpos(w)[2]
        if col > max_col then
          max_col, rightmost = col, w
        end
      end
      assert.equals(term_win, rightmost)

      diff.reject(id)
      pcall(vim.api.nvim_win_close, term_win, true)
    end
  )

  it("renders the same inline overlay as the inline presenter", function()
    diff.set_presenter(diff.presenters.docked)
    local id = diff.open({
      path = "/tmp/z.lua",
      proposed = { "one", "TWO" },
      original = { "one", "two" },
    }, function() end)
    local pbuf = diff.proposed_bufnr(id)
    assert(pbuf)
    local marks = vim.api.nvim_buf_get_extmarks(pbuf, inline_ns, 0, -1, { details = true })
    assert.equals(2, #marks) -- same overlay logic as `inline` (removed + changed)
    diff.reject(id)
  end)

  it("swaps the buffer's filetype to harnt_diff (edgy match key) after rendering", function()
    diff.set_presenter(diff.presenters.docked)
    local id = diff.open(
      { path = "/tmp/z.lua", proposed = { "a" }, original = { "a" } },
      function() end
    )
    local pbuf = diff.proposed_bufnr(id)
    assert(pbuf)
    assert.equals("harnt_diff", vim.bo[pbuf].filetype)
    diff.reject(id)
  end)

  it("closes only its own window, not the whole tab, on teardown", function()
    vim.cmd("tabnew") -- an unrelated extra window in the same tab
    local sibling_win = vim.api.nvim_get_current_win()
    local tab = vim.fn.tabpagenr("$")

    diff.set_presenter(diff.presenters.docked)
    local id = diff.open(
      { path = "/tmp/z.lua", proposed = { "a" }, original = { "a" } },
      function() end
    )
    diff.reject(id)

    assert.equals(tab, vim.fn.tabpagenr("$")) -- tab still open
    assert.is_true(vim.api.nvim_win_is_valid(sibling_win)) -- sibling untouched
    vim.cmd("tabclose")
  end)
end)
