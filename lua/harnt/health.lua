--- `:checkhealth harnt` — environment + per-provider diagnostics.
---
--- The generic check covers Neovim + the registry. Each provider may supply an
--- optional `health(report)` capability for its own probes (binary, auth,
--- discovery paths) — provider knowledge stays in the provider, this module only
--- orchestrates. `report` is a thin adapter over `vim.health` so providers don't
--- depend on its exact shape (and stay unit-testable).

local M = {}

--- A minimal health reporter handed to providers.
---@class harnt.health.Report
---@field ok fun(msg: string)
---@field warn fun(msg: string, advice?: string)
---@field error fun(msg: string, advice?: string)
---@field info fun(msg: string)

--- Build a report adapter bound to `vim.health`.
---@return harnt.health.Report
local function make_report()
  local health = vim.health
  return {
    ok = function(msg)
      health.ok(msg)
    end,
    warn = function(msg, advice)
      health.warn(msg, advice)
    end,
    error = function(msg, advice)
      health.error(msg, advice)
    end,
    info = function(msg)
      health.info(msg)
    end,
  }
end

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
    health.info("No providers registered yet — call require('harnt').setup{}")
    return
  end

  local report = make_report()
  for _, name in ipairs(names) do
    health.start("harnt: " .. name)
    local provider = registry.get(name)
    if provider then
      -- Provider-specific probes (binary, version, auth, discovery paths). `health`
      -- is a required part of the contract, so every provider has one.
      provider.health(report)
    end
  end
end

return M
