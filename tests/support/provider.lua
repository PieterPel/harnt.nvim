-- Test-only fixture: a complete, valid, no-op Provider.
--
-- The real contract is TOTAL — every capability method is required and
-- `register()` rejects a partial table (see lua/harnt/providers/init.lua). Most
-- tests only care about the registry / manager / health plumbing, not real agent
-- behavior, so they build one of these and override just the field under test.
--
-- This lives in tests/ on purpose. A no-op base shipped in the library would
-- reintroduce exactly the silent-no-op defaults the contract exists to forbid —
-- a real provider could inherit a do-nothing `review`/`on_mention` and nobody
-- would notice. Only tests get the shortcut.

--- Build a complete, valid provider, shallow-merged with `overrides`. Pass a
--- `start` override to shape the session; otherwise a minimal no-op session with a
--- reverse-MCP-style `info` is provided (enough for the manager to spawn a TUI).
---@param name string
---@param overrides? table
---@return harnt.Provider
return function(name, overrides)
  local base = {
    name = name,
    detect = function()
      return true
    end,
    start = function()
      return {
        info = { host = "127.0.0.1", port = 4321, auth_token = "t", pid = 1 },
        on = function() end,
        respond = function() end,
        interrupt = function() end,
        stop = function() end,
      }
    end,
    cmd = {}, -- empty = no external process spawned
    env = function()
      return {}
    end,
    review = function() end,
    health = function() end,
    on_mention = function() end,
    pull_selection = function()
      return nil
    end,
  }
  return vim.tbl_extend("force", base, overrides or {}) --[[@as harnt.Provider]]
end
