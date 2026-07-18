--- Apply service.
---
--- Turns proposed file content into reality: writes it to disk (creating parent
--- directories) and reloads any open buffer so Neovim reflects the change. This
--- is what the diff service calls when the user accepts. Agent-agnostic.

local M = {}

--- Replace a loaded buffer's entire contents in memory (no disk write).
---@param bufnr integer
---@param lines string[]
function M.set_buffer(bufnr, lines)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
end

--- Write `lines` to `path` on disk, creating parent directories as needed.
---@param path string
---@param lines string[]
---@return boolean ok, string? err
function M.write_file(path, lines)
  local dir = vim.fs.dirname(path)
  if dir and dir ~= "" and vim.fn.isdirectory(dir) == 0 then
    -- mkdir raises (E739) rather than returning 0 on failure, so guard it.
    local ok, made = pcall(vim.fn.mkdir, dir, "p")
    if not ok or made == 0 then
      return false, "could not create directory: " .. dir
    end
  end
  local ok, wrote = pcall(vim.fn.writefile, lines, path)
  if not ok or wrote ~= 0 then
    return false, "could not write file: " .. path
  end
  return true
end

--- Reload a buffer from disk if it changed and has no unsaved edits (via
--- `:checktime`, so a modified buffer is left untouched rather than clobbered).
---@param bufnr integer
function M.reload(bufnr)
  if not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd("silent! checktime")
  end)
end

--- Write `lines` to `path` and reload the buffer showing it, if any is loaded.
--- The one-call path the diff/approval flow uses on accept.
---@param path string
---@param lines string[]
---@return boolean ok, string? err
function M.apply_file(path, lines)
  local ok, err = M.write_file(path, lines)
  if not ok then
    return false, err
  end
  local bufnr = vim.fn.bufnr(path)
  if bufnr ~= -1 then
    M.reload(bufnr)
  end
  return true
end

return M
