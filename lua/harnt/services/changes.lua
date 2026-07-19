--- Change-log service.
---
--- A read-only record of every file change agents make in a session, surfaced on
--- demand (`:Harnt changes`). This is deliberately NOT the approval-gated diff
--- review: it never blocks the agent and never answers anything — it just lets
--- you *see* what happened, including edits the agent auto-applied without asking.
---
--- Generic and agent-agnostic: a provider pushes a change in (`record`) from
--- whatever native signal it has (Codex's `fileChange` items, Claude's applied
--- edits, …); this service knows nothing about any agent. The viewer is an
--- injectable seam, mirroring the diff/approvals services.

local M = {}

--- One recorded change.
---@class harnt.changes.Change
---@field path string file the change touched
---@field kind string "add" | "update" | "delete" (provider's term)
---@field diff string full content (add) or a unified diff (update)
---@field provider? string which agent made it

---@type harnt.changes.Change[]
local log = {}

--- Open a recorded change for viewing. Injectable (tests, or a nicer frontend).
---@alias harnt.changes.Viewer fun(change: harnt.changes.Change)

--- Default viewer: a read-only `filetype=diff` scratch buffer in a new tabpage,
--- with `q` to close. No accept/reject — this is a look, not a gate.
---@param change harnt.changes.Change
local function default_viewer(change)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(
    buf,
    0,
    -1,
    false,
    vim.split(change.diff or "", "\n", { plain = true })
  )
  vim.bo[buf].filetype = "diff"
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.cmd("tabnew")
  vim.api.nvim_win_set_buf(0, buf)
  vim.wo.winbar = ("  harnt change   %s  %s   q close "):format(change.kind, change.path)
  vim.keymap.set("n", "q", "<cmd>tabclose<cr>", { buffer = buf, nowait = true, silent = true })
end

---@type harnt.changes.Viewer
local viewer = default_viewer

--- Swap the viewer (tests, or a provider/user frontend). nil restores the default.
---@param fn harnt.changes.Viewer?
function M.set_viewer(fn)
  viewer = fn or default_viewer
end

--- Record a change. Returns its 1-based index in the log.
---@param change harnt.changes.Change
---@return integer index
function M.record(change)
  log[#log + 1] = change
  return #log
end

--- The recorded changes, oldest first.
---@return harnt.changes.Change[]
function M.list()
  return log
end

--- How many changes are recorded.
---@return integer
function M.count()
  return #log
end

--- Forget the log (new session / tests).
function M.clear()
  log = {}
end

--- View the change at `index` (1-based), if it exists.
---@param index integer
function M.open(index)
  local change = log[index]
  if change then
    viewer(change)
  end
end

--- Pick a recorded change to view (`vim.ui.select`), newest last.
function M.pick()
  if #log == 0 then
    vim.notify("harnt: no changes recorded yet", vim.log.levels.INFO)
    return
  end
  vim.ui.select(log, {
    prompt = "harnt: changes",
    format_item = function(change)
      local who = change.provider and ("[" .. change.provider .. "] ") or ""
      return ("%s%s  %s"):format(who, change.kind, change.path)
    end,
  }, function(choice)
    if not choice then
      return
    end
    for i, change in ipairs(log) do
      if change == choice then
        M.open(i)
        return
      end
    end
  end)
end

return M
