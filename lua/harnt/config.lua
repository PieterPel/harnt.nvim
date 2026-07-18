--- User configuration: defaults, validation, and wiring into the services.
---
--- The single place a user tunes harnt. Notably, this is where the injectable
--- UI seams (diff presenter, approvals chooser) get wired from user options into
--- the services — the services themselves stay presentation-agnostic.

local M = {}

---@class harnt.DiffConfig
---@field presenter? harnt.diff.Presenter how proposed changes are shown

---@class harnt.ApprovalsConfig
---@field chooser? harnt.approvals.Chooser how approval prompts are shown

---@class harnt.KeymapConfig
---@field diff? { accept?: string, reject?: string } diff accept/reject keys

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

  M.options = merged
  return merged
end

return M
