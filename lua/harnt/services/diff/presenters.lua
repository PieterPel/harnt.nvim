--- Built-in diff presenters: how a diff's buffer(s) become windows/tabs.
---
--- Colocated as alternative implementations of one injectable interface —
--- mirrors `terminal.lua`'s opener seam (`builtin`/`snacks_opener` living
--- together, `M.builtin` exposed as a named escape hatch). Each presenter
--- needs a few hooks back into the diff service's shared plumbing (winbar
--- text, keymap binding, tab teardown); those are passed in via `M.new(hooks)`
--- rather than `require`d, so this module never has to require
--- `services.diff` back (that would be a require cycle) and stays
--- independently testable.

local M = {}

---@class harnt.diff.PresenterHooks
---@field winbar_hint fun(): string
---@field bind_actions fun(buf: integer)
---@field bind_comment fun(buf: integer)
---@field close_tab fun(tabpage: integer)

--- Default highlight groups for the inline presenter's overlay, linked (not
--- copied) to the standard Diff* groups so they follow the active
--- colorscheme until a user or colorscheme defines `HarntInline*` directly.
--- `:colorscheme` clears user-defined groups, hence the ColorScheme autocmd.
local function set_inline_highlight_defaults()
  vim.api.nvim_set_hl(0, "HarntInlineAdd", { link = "DiffAdd", default = true })
  vim.api.nvim_set_hl(0, "HarntInlineDelete", { link = "DiffDelete", default = true })
end
set_inline_highlight_defaults()
vim.api.nvim_create_autocmd("ColorScheme", { callback = set_inline_highlight_defaults })

--- Extmark namespace for the inline presenter's removed-line overlay.
local inline_ns = vim.api.nvim_create_namespace("harnt_diff_inline")

--- Render `original` as an inline overlay on `buf` (which already holds the
--- proposed content): removed lines become struck-through virtual lines just
--- above where they used to sit, changed/added lines get a full-line
--- highlight. VSCode-inline-diff style, on a single still-editable buffer.
---@param buf integer
---@param original string[]
local function render_inline_overlay(buf, original)
  local proposed = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local a = table.concat(original, "\n")
  local b = table.concat(proposed, "\n")
  if a ~= "" then
    a = a .. "\n"
  end
  if b ~= "" then
    b = b .. "\n"
  end
  ---@diagnostic disable-next-line: deprecated
  local hunks = vim.diff(a, b, { result_type = "indices" }) --[[@as integer[][]? ]]
  if not hunks then
    return
  end
  local nlines = math.max(#proposed, 1)
  for _, hunk in ipairs(hunks) do
    local start_a = hunk[1] --[[@as integer]]
    local count_a = hunk[2] --[[@as integer]]
    local start_b = hunk[3] --[[@as integer]]
    local count_b = hunk[4] --[[@as integer]]
    if count_a > 0 then
      local removed = {}
      for i = start_a, start_a + count_a - 1 do
        table.insert(removed, { { "  " .. (original[i] or ""), "HarntInlineDelete" } })
      end
      -- Anchor the removed-lines overlay where the gap actually is: above the
      -- new hunk's first line when something replaced it, else below the
      -- last surviving line (or above line 1, for a deletion at file start).
      local anchor, above
      if count_b > 0 then
        anchor, above = start_b - 1, true
      elseif start_b > 0 then
        anchor, above = math.min(start_b - 1, nlines - 1), false
      else
        anchor, above = 0, true
      end
      pcall(vim.api.nvim_buf_set_extmark, buf, inline_ns, anchor, 0, {
        virt_lines = removed,
        virt_lines_above = above,
      })
    end
    for i = start_b, start_b + count_b - 1 do
      pcall(vim.api.nvim_buf_set_extmark, buf, inline_ns, i - 1, 0, {
        line_hl_group = "HarntInlineAdd",
        hl_eol = true,
      })
    end
  end
end

--- Build the built-in presenters, wired to the diff service's shared hooks.
---@param hooks harnt.diff.PresenterHooks
---@return table<string, harnt.diff.Presenter>
function M.new(hooks)
  --- Default presenter: side-by-side vimdiff in a new tabpage, with a winbar
  --- affordance so it isn't a silent modal.
  ---@param view harnt.diff.View
  ---@return harnt.diff.Presentation
  local function split_presenter(view)
    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()

    local left = vim.api.nvim_get_current_win()
    local original_buf = assert(view.original_buf, "split presenter needs an original_buf")
    vim.api.nvim_win_set_buf(left, original_buf)
    vim.api.nvim_win_call(left, function()
      vim.cmd("diffthis")
    end)

    vim.cmd("vertical rightbelow split")
    local right = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(right, view.proposed_buf)
    vim.api.nvim_win_call(right, function()
      vim.cmd("diffthis")
    end)

    local hint = hooks.winbar_hint()
    vim.wo[left].winbar = hint
    vim.wo[right].winbar = hint

    hooks.bind_actions(original_buf)
    hooks.bind_actions(view.proposed_buf)
    hooks.bind_comment(view.proposed_buf)

    return {
      teardown = function()
        hooks.close_tab(tabpage)
      end,
    }
  end

  --- Review presenter: a single `filetype=diff` window in a new tabpage. Used
  --- for pre-rendered patches (an agent that applies its own edits and only
  --- wants a verdict), where there is no editable proposal buffer to lay out
  --- side by side.
  ---@param view harnt.diff.View
  ---@return harnt.diff.Presentation
  local function review_presenter(view)
    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, view.proposed_buf)
    vim.bo[view.proposed_buf].filetype = "diff"
    vim.wo[win].winbar = hooks.winbar_hint()

    -- Providers render full-file context, so the whole file is visible; start
    -- the view focused on the first actual change (a `+`/`-` line, not a
    -- `@@`/`+++`/`---` header) and center it.
    local lines = vim.api.nvim_buf_get_lines(view.proposed_buf, 0, -1, false)
    for i, l in ipairs(lines) do
      local c = l:sub(1, 1)
      if (c == "+" or c == "-") and l:sub(1, 3) ~= "+++" and l:sub(1, 3) ~= "---" then
        pcall(vim.api.nvim_win_set_cursor, win, { i, 0 })
        vim.api.nvim_win_call(win, function()
          vim.cmd("normal! zz")
        end)
        break
      end
    end

    hooks.bind_actions(view.proposed_buf)
    hooks.bind_comment(view.proposed_buf)

    return {
      teardown = function()
        hooks.close_tab(tabpage)
      end,
    }
  end

  --- Inline presenter: a single editable window (VSCode "inline diff" style)
  --- instead of the default side-by-side split. Opt in via
  --- `diff = { presenter = require("harnt.services.diff").presenters.inline }`
  --- (or `diff = { style = "inline" }` in `require("harnt").setup{}`). The
  --- overlay is computed once at open time — it does not live-update as the
  --- proposal is edited.
  ---@param view harnt.diff.View
  ---@return harnt.diff.Presentation
  local function inline_presenter(view)
    vim.cmd("tabnew")
    local tabpage = vim.api.nvim_get_current_tabpage()
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, view.proposed_buf)
    vim.wo[win].winbar = hooks.winbar_hint()

    local original_buf = assert(view.original_buf, "inline presenter needs an original_buf")
    render_inline_overlay(view.proposed_buf, vim.api.nvim_buf_get_lines(original_buf, 0, -1, false))

    hooks.bind_actions(view.proposed_buf)
    hooks.bind_comment(view.proposed_buf)

    return {
      teardown = function()
        hooks.close_tab(tabpage)
      end,
    }
  end

  return {
    split = split_presenter,
    review = review_presenter,
    inline = inline_presenter,
  }
end

return M
