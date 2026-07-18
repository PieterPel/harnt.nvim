--- `:checkhealth harnt` — environment + provider diagnostics.

local M = {}

--- Run the health check (invoked by `:checkhealth harnt`).
function M.check()
  local health = vim.health
  health.start("harnt")

  if vim.fn.has("nvim-0.10") == 1 then
    -- vim.version() is callable at runtime; the type stubs it as a namespace.
    ---@diagnostic disable-next-line: call-non-callable
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("Neovim 0.10+ is required")
  end

  local registry = require("harnt.providers")
  local names = registry.list()
  if #names == 0 then
    health.info("No providers registered yet")
    return
  end

  health.start("harnt: providers")
  for _, name in ipairs(names) do
    if registry.is_available(name) then
      health.ok(("%s: available"):format(name))
    else
      health.warn(("%s: registered but not available (detect() returned false)"):format(name))
    end
  end
end

return M
