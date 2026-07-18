--- Diff service.
---
--- Presents a proposed file change as a native side-by-side vimdiff (baseline on
--- the left, editable proposal on the right) and resolves to accept / reject.
--- File-level, deliberately simple (à la claudecode.nvim, not per-hunk). Accept
--- reads the *current* proposal buffer, so user edits in the diff are honored
--- ("accept with edits"), then writes via the apply service.
---
--- The proposal buffer carries a buffer-local `harnt_diff` flag so auto-save
--- plugins can tell it apart and not silently write/accept it. Agent-agnostic.

local apply = require("harnt.services.apply")

local M = {}

---@class harnt.diff.Spec
---@field path string absolute path the proposal targets
---@field proposed string[] proposed new content
---@field original? string[] baseline; defaults to the file's current on-disk content

---@class harnt.diff.Result
---@field accepted boolean
---@field content? string[] final content (possibly user-edited) when accepted

---@class harnt.diff.Entry
---@field spec harnt.diff.Spec
---@field proposed_buf integer
---@field original_buf integer
---@field tabpage integer?
---@field callback fun(result: harnt.diff.Result)

---@type table<integer, harnt.diff.Entry>
local entries = {}
local next_id = 0

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

--- Lay out the two buffers as a side-by-side diff in a new tabpage.
---@param original_buf integer
---@param proposed_buf integer
---@return integer tabpage
local function present(original_buf, proposed_buf)
  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()

  local left = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(left, original_buf)
  vim.api.nvim_win_call(left, function()
    vim.cmd("diffthis")
  end)

  vim.cmd("vertical rightbelow split")
  local right = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(right, proposed_buf)
  vim.api.nvim_win_call(right, function()
    vim.cmd("diffthis")
  end)

  return tabpage
end

--- Tear down a diff's tab + scratch buffers and forget it.
---@param id integer
local function teardown(id)
  local e = entries[id]
  if not e then
    return
  end
  entries[id] = nil

  if e.tabpage and vim.api.nvim_tabpage_is_valid(e.tabpage) then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(e.tabpage)) do
      pcall(vim.api.nvim_win_close, win, true)
    end
  end
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

  local original = spec.original or read_lines(spec.path)
  local original_buf = scratch(original)
  local proposed_buf = scratch(spec.proposed)
  local tabpage = present(original_buf, proposed_buf)

  entries[id] = {
    spec = spec,
    proposed_buf = proposed_buf,
    original_buf = original_buf,
    tabpage = tabpage,
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

--- Number of diffs currently open (for checkhealth / tests).
---@return integer
function M.open_count()
  return vim.tbl_count(entries)
end

return M
