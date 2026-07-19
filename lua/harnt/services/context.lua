--- Editor-context service.
---
--- Normalizes the editor state that agents care about — selection, open buffers,
--- cursor, workspace roots, diagnostics — into plain tables with 1-based rows and
--- 0-based byte columns. Knows nothing about any agent; it only reads Neovim.
--- Every provider consumes this identically.

local M = {}

---@class harnt.context.Position
---@field row integer 1-based line number
---@field col integer 0-based byte column

---@class harnt.context.Buffer
---@field bufnr integer
---@field path string absolute file path, or "" if the buffer is unnamed
---@field active boolean whether this is the current buffer

---@class harnt.context.Diagnostic
---@field bufnr integer
---@field path string
---@field row integer 1-based line number
---@field col integer 0-based byte column
---@field severity "error"|"warn"|"info"|"hint"
---@field message string
---@field source? string

---@class harnt.context.Selection
---@field path string
---@field start harnt.context.Position
---@field finish harnt.context.Position
---@field text string

---@class harnt.context.Snapshot
---@field cursor harnt.context.Position?
---@field buffers harnt.context.Buffer[]
---@field diagnostics harnt.context.Diagnostic[]
---@field roots string[]
---@field selection harnt.context.Selection?

---@type table<integer, "error"|"warn"|"info"|"hint">
local SEVERITY = {
  [vim.diagnostic.severity.ERROR] = "error",
  [vim.diagnostic.severity.WARN] = "warn",
  [vim.diagnostic.severity.INFO] = "info",
  [vim.diagnostic.severity.HINT] = "hint",
}

--- Cursor position in the given window (default: current).
---@param win? integer window handle (0 or nil = current)
---@return harnt.context.Position
function M.cursor(win)
  local pos = vim.api.nvim_win_get_cursor(win or 0)
  return { row = pos[1], col = pos[2] }
end

--- Listed, loaded, on-disk buffers.
---@return harnt.context.Buffer[]
function M.buffers()
  local current = vim.api.nvim_get_current_buf()
  local out = {} ---@type harnt.context.Buffer[]
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].buflisted then
      table.insert(out, {
        bufnr = bufnr,
        path = vim.api.nvim_buf_get_name(bufnr),
        active = bufnr == current,
      })
    end
  end
  return out
end

--- Normalized diagnostics for one buffer, or all buffers when `bufnr` is nil.
---@param bufnr? integer
---@return harnt.context.Diagnostic[]
function M.diagnostics(bufnr)
  local out = {} ---@type harnt.context.Diagnostic[]
  for _, d in ipairs(vim.diagnostic.get(bufnr)) do
    table.insert(out, {
      bufnr = d.bufnr,
      path = vim.api.nvim_buf_get_name(d.bufnr),
      row = d.lnum + 1,
      col = d.col,
      severity = SEVERITY[d.severity] or "info",
      message = d.message,
      source = d.source,
    })
  end
  return out
end

--- Workspace roots: the current working directory, plus the enclosing git root
--- if it differs.
---@return string[]
function M.workspace_roots()
  local roots = {} ---@type string[]
  local cwd = vim.uv.cwd()
  if cwd then
    table.insert(roots, cwd)
  end
  local git = vim.fs.find(".git", { upward = true, path = cwd, type = "directory" })[1]
  if git then
    local root = vim.fs.dirname(git)
    if root and root ~= cwd then
      table.insert(roots, root)
    end
  end
  return roots
end

--- The current visual selection, derived from the `'<` / `'>` marks, or nil when
--- there is no non-empty selection in the current buffer.
---@return harnt.context.Selection?
function M.selection()
  local bufnr = vim.api.nvim_get_current_buf()
  local sr, sc = unpack(vim.api.nvim_buf_get_mark(bufnr, "<"))
  local er, ec = unpack(vim.api.nvim_buf_get_mark(bufnr, ">"))
  if sr == 0 and er == 0 then
    return nil
  end

  -- `'>` col is inclusive and may be huge (v_$); clamp to the line length.
  local last_line = vim.api.nvim_buf_get_lines(bufnr, er - 1, er, false)[1] or ""
  ec = math.min(ec + 1, #last_line)

  local lines = vim.api.nvim_buf_get_text(bufnr, sr - 1, sc, er - 1, ec, {})
  return {
    path = vim.api.nvim_buf_get_name(bufnr),
    start = { row = sr, col = sc },
    finish = { row = er, col = ec },
    text = table.concat(lines, "\n"),
  }
end

--- Payload for a `selection_changed` push: the active file + cursor as an empty
--- selection (0-indexed LSP positions), matching the Claude IDE protocol.
---@return table
function M.selection_payload()
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  local cursor = M.cursor()
  local pos = { line = cursor.row - 1, character = cursor.col }
  return {
    text = "",
    filePath = path,
    fileUrl = path ~= "" and ("file://" .. path) or "",
    selection = { start = pos, ["end"] = pos, isEmpty = true },
  }
end

--- Payload for an `at_mentioned` push: the current file and (1-indexed) line
--- range — the last visual selection if there is one, else the whole file.
---@return table
function M.at_mention_payload()
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  local first = vim.fn.getpos("'<")
  local last = vim.fn.getpos("'>")
  local line_start, line_end
  if first[2] > 0 and last[2] > 0 then
    line_start, line_end = first[2], last[2]
  else
    line_start, line_end = 1, vim.api.nvim_buf_line_count(bufnr)
  end
  return { filePath = path, lineStart = line_start, lineEnd = line_end }
end

--- Aggregate snapshot of everything above.
---@return harnt.context.Snapshot
function M.snapshot()
  return {
    cursor = M.cursor(),
    buffers = M.buffers(),
    diagnostics = M.diagnostics(),
    roots = M.workspace_roots(),
    selection = M.selection(),
  }
end

return M
