--- User configuration: defaults, validation, and wiring into the services.
---
--- The single place a user tunes harnt. Notably, this is where the injectable
--- UI seams (diff presenter, approvals chooser) get wired from user options into
--- the services — the services themselves stay presentation-agnostic.

local M = {}

---@class harnt.DiffConfig
---@field presenter? harnt.diff.Presenter how proposed changes are shown
---@field style? "split"|"inline"|"docked" pick a built-in presenter by name (default "split"); ignored if `presenter` is also set. "docked" opens in the current tab instead of a new one — pair with a layout plugin (e.g. edgy.nvim, matching filetype "harnt_diff") or the automatic jump_agent fallback below

---@class harnt.ApprovalsConfig
---@field chooser? harnt.approvals.Chooser how approval prompts are shown

---@class harnt.KeymapConfig
---@field diff? { accept?: string, reject?: string, comment?: string, review?: string } diff review keys (buffer-local to the diff/review windows)
---@field jump_agent? string key to jump between a diff and the agent that opened it, bound on both sides (default "<leader>t"). Only bound when edgy.nvim isn't detected — with edgy, dock both (filetypes "harnt_diff"/"harnt_terminal") and use its own window navigation instead

---@class harnt.Config
---@field diff harnt.DiffConfig
---@field approvals harnt.ApprovalsConfig
---@field keymaps harnt.KeymapConfig

---@type harnt.Config
local defaults = {
  diff = {},
  approvals = {},
  keymaps = {},
}

--- The active, merged configuration.
---@type harnt.Config
M.options = vim.deepcopy(defaults)

--- Merge and validate user options, then wire the UI seams into the services.
---@param opts? table
---@return harnt.Config
function M.setup(opts)
  opts = opts or {}
  assert(type(opts) == "table", "harnt.setup: opts must be a table")

  ---@type harnt.Config
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts)

  if merged.diff.presenter ~= nil then
    assert(
      type(merged.diff.presenter) == "function",
      "harnt.setup: diff.presenter must be a function"
    )
    require("harnt.services.diff").set_presenter(merged.diff.presenter)
  elseif merged.diff.style ~= nil then
    local diff = require("harnt.services.diff")
    local chosen = diff.presenters[merged.diff.style]
    -- emmylua sees `table<string, Presenter>` indexing as always non-nil; an
    -- unknown style name is exactly the runtime case this guards against.
    ---@diagnostic disable-next-line: unnecessary-assert
    assert(chosen, "harnt.setup: unknown diff.style " .. tostring(merged.diff.style))
    diff.set_presenter(chosen)
  end

  if merged.approvals.chooser ~= nil then
    assert(
      type(merged.approvals.chooser) == "function",
      "harnt.setup: approvals.chooser must be a function"
    )
    require("harnt.services.approvals").set_chooser(merged.approvals.chooser)
  end

  if merged.keymaps.diff ~= nil then
    require("harnt.services.diff").set_keys(merged.keymaps.diff)
  end

  if merged.keymaps.jump_agent ~= nil then
    require("harnt.manager").set_jump_key(merged.keymaps.jump_agent)
  end

  M.options = merged
  return merged
end

return M
