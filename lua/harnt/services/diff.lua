--- Diff service.
---
--- Owns the *lifecycle* of a proposed file change — create baseline + editable
--- proposal buffers, track them, resolve to accept/reject, and on accept write
--- the (possibly user-edited) proposal via the apply service. File-level,
--- deliberately simple (à la claudecode.nvim, not per-hunk).
---
--- It does NOT hardcode *how* the change is shown. Presentation is a frontend
--- concern — a Shape A minimal popup, a floating window, a new tab, or a user
--- preference — so the presenter is injectable (mirroring approvals' chooser).
--- The default lays the two buffers out as a side-by-side vimdiff. The proposal
--- buffer carries a buffer-local `harnt_diff` flag so auto-save plugins leave it
--- alone. Agent-agnostic.

local apply = require("harnt.services.apply")

local M = {}

--- Extmark namespace for inline diff comments.
local ns = vim.api.nvim_create_namespace("harnt_diff_comments")

--- Frontend hook invoked when the user submits a review (see M.set_review_handler).
---@type fun(id: integer)?
local review_handler = nil

---@class harnt.diff.Spec
---@field path string absolute path the proposal targets
---@field proposed string[] proposed new content
---@field original? string[] baseline; defaults to the file's current on-disk content
---@field origin? string opaque tag naming who opened it (provider name); routes review feedback back to the right agent when several run at once
---@field apply? boolean write the accepted content to disk (default true). Set false for agents that apply the edit THEMSELVES from the returned content (e.g. Claude's openDiff): harnt does a virtual save — resolves with the content but doesn't touch the file — so the agent's own writer doesn't hit a "file changed since read" conflict.

---@class harnt.diff.Result
---@field accepted boolean
---@field content? string[] final content (possibly user-edited) when accepted
---@field comments { line: integer, text: string }[] inline comments attached before resolving

--- The buffers a presenter is asked to display. The service creates and owns
--- them; the presenter only decides layout.
---@class harnt.diff.View
---@field path string
---@field original_buf integer? baseline (left); absent for review-only diffs
---@field proposed_buf integer editable proposal (right), or the patch buffer for review-only

--- What a presenter returns so the service can dismiss the UI it opened.
---@class harnt.diff.Presentation
---@field teardown fun() close whatever windows/tabs the presenter created

---@alias harnt.diff.Presenter fun(view: harnt.diff.View): harnt.diff.Presentation

---@class harnt.diff.Entry
---@field spec harnt.diff.Spec
---@field proposed_buf integer
---@field original_buf integer?
---@field presentation harnt.diff.Presentation
---@field callback fun(result: harnt.diff.Result)
---@field comments { line: integer, text: string }[]
---@field review? boolean review-only: accept resolves without writing (the agent applies)
---@field origin? string who opened this diff (provider name), for feedback routing

---@type table<integer, harnt.diff.Entry>
local entries = {}
local next_id = 0

--- Keys shown in the winbar + bound in the diff (config-settable).
local keys =
  { accept = "<leader>a", reject = "<leader>r", comment = "<leader>c", review = "<leader>R" }

--- Override the diff keys (wired from user config).
---@param opts { accept?: string, reject?: string, comment?: string, review?: string }
function M.set_keys(opts)
  keys.accept = opts.accept or keys.accept
  keys.reject = opts.reject or keys.reject
  keys.comment = opts.comment or keys.comment
  keys.review = opts.review or keys.review
end

--- The winbar affordance so a diff/review isn't a silent modal.
---@return string
local function winbar_hint()
  return ("  harnt diff   %s accept   %s reject   %s comment   %s review "):format(
    keys.accept,
    keys.reject,
    keys.comment,
    keys.review
  )
end

--- Run `fn(id)` for the current diff. Resolved at press time, so keymaps bind
--- late — no ordering dependency on M.accept/reject/etc.
---@param fn fun(id: integer)
local function for_current(fn)
  return function()
    local id = M.current()
    if id then
      fn(id)
    end
  end
end

--- Bind accept/reject/review on `buf` (both diff panes / the review buffer).
---@param buf integer
local function bind_actions(buf)
  local o = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set(
    "n",
    keys.accept,
    for_current(M.accept),
    vim.tbl_extend("force", o, { desc = "harnt: accept diff" })
  )
  vim.keymap.set(
    "n",
    keys.reject,
    for_current(M.reject),
    vim.tbl_extend("force", o, { desc = "harnt: reject diff" })
  )
  vim.keymap.set(
    "n",
    keys.review,
    for_current(function(id)
      (review_handler or M.reject)(id)
    end),
    vim.tbl_extend("force", o, { desc = "harnt: submit review" })
  )
end

--- Bind the comment key on `buf` (the buffer whose lines carry the comments).
---@param buf integer
local function bind_comment(buf)
  vim.keymap.set("n", keys.comment, function()
    local id = M.current()
    if not id then
      return
    end
    local line = vim.api.nvim_win_get_cursor(0)[1]
    vim.ui.input({ prompt = ("Comment L%d: "):format(line) }, function(text)
      if text and text ~= "" then
        M.add_comment(id, line, text)
      end
    end)
  end, { buffer = buf, nowait = true, silent = true, desc = "harnt: comment on line" })
end

--- Close every window showing a tabpage we opened.
---@param tabpage integer
local function close_tab(tabpage)
  if vim.api.nvim_tabpage_is_valid(tabpage) then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
end

--- Default presenter: side-by-side vimdiff in a new tabpage, with a winbar
--- affordance so it isn't a silent modal.
---@param view harnt.diff.View
---@return harnt.diff.Presentation
local function default_presenter(view)
  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()

  local left = vim.api.nvim_get_current_win()
  local original_buf = assert(view.original_buf, "default_presenter needs an original_buf")
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

  local hint = winbar_hint()
  vim.wo[left].winbar = hint
  vim.wo[right].winbar = hint

  bind_actions(original_buf)
  bind_actions(view.proposed_buf)
  bind_comment(view.proposed_buf)

  return {
    teardown = function()
      close_tab(tabpage)
    end,
  }
end

--- Review presenter: a single `filetype=diff` window in a new tabpage. Used for
--- pre-rendered patches (an agent that applies its own edits and only wants a
--- verdict), where there is no editable proposal buffer to lay out side by side.
---@param view harnt.diff.View
---@return harnt.diff.Presentation
local function review_presenter(view)
  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, view.proposed_buf)
  vim.bo[view.proposed_buf].filetype = "diff"
  vim.wo[win].winbar = winbar_hint()

  -- Providers render full-file context, so the whole file is visible; start the
  -- view focused on the first actual change (a `+`/`-` line, not a `@@`/`+++`/
  -- `---` header) and center it.
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

  bind_actions(view.proposed_buf)
  bind_comment(view.proposed_buf)

  return {
    teardown = function()
      close_tab(tabpage)
    end,
  }
end

---@type harnt.diff.Presenter
local presenter = default_presenter

---@type harnt.diff.Presenter
local review_presenter_fn = review_presenter

--- Swap the presentation (a provider frontend, a config choice, or a test's
--- no-op). Pass nil to restore the default side-by-side vimdiff.
---@param fn harnt.diff.Presenter?
function M.set_presenter(fn)
  presenter = fn or default_presenter
end

--- Swap the review-only presentation (single filetype=diff window). Pass nil to
--- restore the default.
---@param fn harnt.diff.Presenter?
function M.set_review_presenter(fn)
  review_presenter_fn = fn or review_presenter
end

--- Read a file's lines, or {} if it does not exist / is unreadable.
---@param path string
---@return string[]
local function read_lines(path)
  if vim.fn.filereadable(path) == 1 then
    return vim.fn.readfile(path)
  end
  return {}
end

--- Create a scratch buffer holding `lines`, flagged as a harnt diff buffer.
---@param lines string[]
---@return integer bufnr
local function scratch(lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.b[bufnr].harnt_diff = true
  return bufnr
end

--- Dismiss a diff's presentation + scratch buffers and forget it.
---@param id integer
local function teardown(id)
  local e = entries[id]
  if not e then
    return
  end
  entries[id] = nil

  pcall(e.presentation.teardown)
  for _, bufnr in ipairs({ e.proposed_buf, e.original_buf }) do
    -- original_buf is absent for review-only diffs; guard on validity.
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
    end
  end
end

--- Open a diff. `callback` fires once with the accept/reject result.
---@param spec harnt.diff.Spec
---@param callback fun(result: harnt.diff.Result)
---@return integer id
function M.open(spec, callback)
  next_id = next_id + 1
  local id = next_id

  local original_buf = scratch(spec.original or read_lines(spec.path))
  local proposed_buf = scratch(spec.proposed)

  -- Scratch buffers created via the API skip filetype detection (no name, no
  -- BufRead), so both panes render uncolored. Resolve the filetype from the
  -- target path and set it on both so syntax/Tree-sitter highlights the diff.
  local ft = vim.filetype.match({ filename = spec.path }) or ""
  vim.bo[original_buf].filetype = ft
  vim.bo[proposed_buf].filetype = ft

  local presentation = presenter({
    path = spec.path,
    original_buf = original_buf,
    proposed_buf = proposed_buf,
  })

  entries[id] = {
    spec = spec,
    proposed_buf = proposed_buf,
    original_buf = original_buf,
    presentation = presentation,
    callback = callback,
    comments = {},
    origin = spec.origin,
  }
  return id
end

--- Render a review diff the SERVICE owns: a full-file unified diff (all context,
--- so the whole file is visible) of `old` vs `new`. Providers pass the change as
--- content; how it's displayed (full context, focus, filetype) lives here, once,
--- not in each provider. The `review_presenter` then scrolls to the first change.
---@param old string[]
---@param new string[]
---@return string[]
local function render_review_diff(old, new)
  local a = table.concat(old, "\n")
  local b = table.concat(new, "\n")
  if a ~= "" then
    a = a .. "\n"
  end
  if b ~= "" then
    b = b .. "\n"
  end
  ---@diagnostic disable-next-line: deprecated
  local unified = vim.diff(a, b, { ctxlen = 1000000 }) --[[@as string]]
  if unified == nil or unified == "" then
    return { "(no textual change)" }
  end
  return vim.split(unified, "\n", { plain = true })
end

--- The change to review. A provider supplies the DATA it has; the service owns
--- how it's displayed (full context, focus, filetype). Two forms:
---  * `new` (+ optional `old`): full proposed content — the service computes the
---    full-file diff. Preferred when the agent gives us the resulting content.
---  * `diff`: a unified diff the agent already produced (Codex updates, OpenCode
---    `apply_patch`), when full content isn't available to reconstruct cheaply.
--- Exactly one is required.
---@class harnt.diff.ReviewSpec
---@field path string file the change targets (for labeling)
---@field new? string[] full proposed content; the service computes the diff
---@field old? string[] baseline; defaults to the file's current on-disk content
---@field diff? string|string[] a ready-made unified diff, when there's no full content
---@field origin? string who opened it (provider name), for feedback routing

--- Open a *review-only* diff and resolve accept/reject WITHOUT writing to disk
--- (the agent applies its own edit; we only report the verdict). Shares the
--- comment/accept/reject machinery with `M.open`. `callback` fires once.
---@param spec harnt.diff.ReviewSpec
---@param callback fun(result: harnt.diff.Result)
---@return integer id
function M.open_review(spec, callback)
  next_id = next_id + 1
  local id = next_id

  local lines ---@type string[]
  if spec.new then
    lines = render_review_diff(spec.old or read_lines(spec.path), spec.new)
  elseif type(spec.diff) == "table" then
    lines = spec.diff --[[@as string[] ]]
  else
    lines = vim.split(spec.diff --[[@as string]] or "", "\n", { plain = true })
  end
  local patch_buf = scratch(lines)
  local presentation = review_presenter_fn({ path = spec.path, proposed_buf = patch_buf })

  entries[id] = {
    spec = { path = spec.path, proposed = lines },
    proposed_buf = patch_buf,
    original_buf = nil,
    presentation = presentation,
    callback = callback,
    comments = {},
    review = true,
    origin = spec.origin,
  }
  return id
end

--- The proposal buffer for a diff (the one the user edits before accepting).
---@param id integer
---@return integer? bufnr
function M.proposed_bufnr(id)
  local e = entries[id]
  return e and e.proposed_buf or nil
end

--- Accept a diff: write the (possibly edited) proposal to disk and resolve.
---@param id integer
---@return boolean ok, string? err
function M.accept(id)
  local e = entries[id]
  if not e then
    return false, "no such diff: " .. tostring(id)
  end
  local comments = e.comments
  -- Review-only: the agent applies its own edit; we only report the verdict.
  if e.review then
    teardown(id)
    e.callback({ accepted = true, comments = comments })
    return true
  end
  local content = vim.api.nvim_buf_get_lines(e.proposed_buf, 0, -1, false)
  local virtual = e.spec.apply == false -- agent applies the returned content itself
  teardown(id)
  local ok, err = true, nil
  if not virtual then
    ok, err = apply.apply_file(e.spec.path, content)
  end
  e.callback({ accepted = true, content = content, comments = comments })
  return ok, err
end

--- Reject a diff: discard it and resolve, leaving the file untouched.
---@param id integer
function M.reject(id)
  local e = entries[id]
  if not e then
    return
  end
  local comments = e.comments
  teardown(id)
  e.callback({ accepted = false, comments = comments })
end

--- The diff id whose original/proposal buffer is `bufnr`, if any.
---@param bufnr integer
---@return integer?
function M.for_buffer(bufnr)
  for id, entry in pairs(entries) do
    if entry.proposed_buf == bufnr or entry.original_buf == bufnr then
      return id
    end
  end
  return nil
end

--- Resolve the "current" diff for accept/reject keymaps: the one for the current
--- buffer, or — failing that — the sole open diff.
---@return integer?
function M.current()
  local id = M.for_buffer(vim.api.nvim_get_current_buf())
  if id then
    return id
  end
  local ids = vim.tbl_keys(entries)
  if #ids == 1 then
    return ids[1]
  end
  return nil
end

--- Attach an inline comment to a 1-indexed line of the proposal, shown above it.
---@param id integer
---@param line integer
---@param text string
function M.add_comment(id, line, text)
  local entry = entries[id]
  if not entry then
    return
  end
  table.insert(entry.comments, { line = line, text = text })
  pcall(vim.api.nvim_buf_set_extmark, entry.proposed_buf, ns, line - 1, 0, {
    virt_lines = { { { "  💬 " .. text, "Comment" } } },
    virt_lines_above = true,
  })
end

--- The comments attached to a diff.
---@param id integer
---@return { line: integer, text: string }[]
function M.comments(id)
  local entry = entries[id]
  return entry and entry.comments or {}
end

--- The file path a diff targets.
---@param id integer
---@return string?
function M.target(id)
  local entry = entries[id]
  return entry and entry.spec.path or nil
end

--- The origin (provider name) that opened a diff, if it was tagged — lets the
--- manager route review feedback to the right agent when several run at once.
---@param id integer
---@return string?
function M.origin(id)
  local entry = entries[id]
  return entry and entry.origin or nil
end

--- Register the frontend handler for the review key (receives the diff id and
--- decides how to deliver feedback). Falls back to a plain reject if unset.
---@param fn fun(id: integer)?
function M.set_review_handler(fn)
  review_handler = fn
end

--- Reject every open diff. Returns how many were closed.
---@return integer
function M.reject_all()
  local ids = vim.tbl_keys(entries)
  for _, id in ipairs(ids) do
    M.reject(id)
  end
  return #ids
end

--- Number of diffs currently open (for checkhealth / tests).
---@return integer
function M.open_count()
  return vim.tbl_count(entries)
end

return M
