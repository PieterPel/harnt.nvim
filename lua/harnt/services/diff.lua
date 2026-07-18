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

---@class harnt.diff.Spec
---@field path string absolute path the proposal targets
---@field proposed string[] proposed new content
---@field original? string[] baseline; defaults to the file's current on-disk content

---@class harnt.diff.Result
---@field accepted boolean
---@field content? string[] final content (possibly user-edited) when accepted

--- The buffers a presenter is asked to display. The service creates and owns
--- them; the presenter only decides layout.
---@class harnt.diff.View
---@field path string
---@field original_buf integer baseline (left)
---@field proposed_buf integer editable proposal (right)

--- What a presenter returns so the service can dismiss the UI it opened.
---@class harnt.diff.Presentation
---@field teardown fun() close whatever windows/tabs the presenter created

---@alias harnt.diff.Presenter fun(view: harnt.diff.View): harnt.diff.Presentation

---@class harnt.diff.Entry
---@field spec harnt.diff.Spec
---@field proposed_buf integer
---@field original_buf integer
---@field presentation harnt.diff.Presentation
---@field callback fun(result: harnt.diff.Result)

---@type table<integer, harnt.diff.Entry>
local entries = {}
local next_id = 0

--- Accept/reject keys shown in the winbar + bound in the diff (config-settable).
local keys = { accept = "<F9>", reject = "<F10>" }

--- Override the diff accept/reject keys (wired from user config).
---@param opts { accept?: string, reject?: string }
function M.set_keys(opts)
  keys.accept = opts.accept or keys.accept
  keys.reject = opts.reject or keys.reject
end

--- Default presenter: side-by-side vimdiff in a new tabpage, with a winbar
--- affordance so it isn't a silent modal.
---@param view harnt.diff.View
---@return harnt.diff.Presentation
local function default_presenter(view)
  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()

  local left = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(left, view.original_buf)
  vim.api.nvim_win_call(left, function()
    vim.cmd("diffthis")
  end)

  vim.cmd("vertical rightbelow split")
  local right = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(right, view.proposed_buf)
  vim.api.nvim_win_call(right, function()
    vim.cmd("diffthis")
  end)

  -- Affordance: show the keys in the winbar so the diff isn't a silent modal.
  local hint = ("  harnt diff    %s accept    %s reject "):format(keys.accept, keys.reject)
  vim.wo[left].winbar = hint
  vim.wo[right].winbar = hint

  -- Buffer-local accept/reject keymaps (configurable). Resolved via M.current()
  -- at press time, so they bind late — no ordering dependency on M.accept/reject.
  local function bind(buf)
    vim.keymap.set("n", keys.accept, function()
      local id = M.current()
      if id then
        M.accept(id)
      end
    end, { buffer = buf, nowait = true, silent = true, desc = "harnt: accept diff" })
    vim.keymap.set("n", keys.reject, function()
      local id = M.current()
      if id then
        M.reject(id)
      end
    end, { buffer = buf, nowait = true, silent = true, desc = "harnt: reject diff" })
  end
  bind(view.original_buf)
  bind(view.proposed_buf)

  return {
    teardown = function()
      if vim.api.nvim_tabpage_is_valid(tabpage) then
        for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tabpage)) do
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
    end,
  }
end

---@type harnt.diff.Presenter
local presenter = default_presenter

--- Swap the presentation (a provider frontend, a config choice, or a test's
--- no-op). Pass nil to restore the default side-by-side vimdiff.
---@param fn harnt.diff.Presenter?
function M.set_presenter(fn)
  presenter = fn or default_presenter
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
    if vim.api.nvim_buf_is_valid(bufnr) then
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
  local content = vim.api.nvim_buf_get_lines(e.proposed_buf, 0, -1, false)
  teardown(id)
  local ok, err = apply.apply_file(e.spec.path, content)
  e.callback({ accepted = true, content = content })
  return ok, err
end

--- Reject a diff: discard it and resolve, leaving the file untouched.
---@param id integer
function M.reject(id)
  local e = entries[id]
  if not e then
    return
  end
  teardown(id)
  e.callback({ accepted = false })
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
