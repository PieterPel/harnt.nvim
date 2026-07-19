--- Antigravity provider — work in progress (see ANTIGRAVITY.md).
---
--- Antigravity's editor integration is the Windsurf/Codeium "exa" language
--- server. harnt plays the editor: it spawns the real `language_server` binary
--- (feeding it a protobuf `Metadata` frame on stdin), hosts the server's
--- ExtensionServer channel (connect+proto) for editor actions, and launches `agy`
--- pointed at the spawned LS. This is a big provider with a hard dependency on the
--- Antigravity IDE being installed (for the LS binary) — hence built
--- incrementally. Currently implemented: LS discovery + protobuf boot handshake.

local pb = require("harnt.transport.protobuf")

local M = {}

M.name = "antigravity"

--- `Metadata` field numbers, decoded from the LS binary's descriptors
--- (see ANTIGRAVITY.md "BREAKTHROUGH").
local META = {
  ide_name = 1,
  api_key = 3,
  locale = 4,
  disable_telemetry = 6,
  ide_version = 7,
  extension_name = 12,
  extension_path = 17,
  device_fingerprint = 24,
  user_tier_id = 29,
}

--- Candidate `language_server` binary locations. The IDE ships it in its app
--- bundle; extend per platform as needed.
local LS_CANDIDATES = {
  -- macOS (Apple Silicon / Intel)
  "/Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_arm",
  "/Applications/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/bin/language_server_macos_x64",
  -- Linux
  vim.fs.joinpath(
    vim.uv.os_homedir() or "",
    ".antigravity/extensions/antigravity/bin/language_server_linux_x64"
  ),
}

--- Locate the language-server binary, or nil if the IDE isn't installed.
---@return string?
function M.find_ls()
  for _, path in ipairs(LS_CANDIDATES) do
    if path ~= "" and vim.fn.executable(path) == 1 then
      return path
    end
  end
  return nil
end

--- The device fingerprint the IDE uses (its installation id), if present.
---@return string
local function installation_id()
  local path = vim.fs.joinpath(vim.uv.os_homedir() or "", ".gemini/antigravity-ide/installation_id")
  if vim.fn.filereadable(path) == 1 then
    -- extra parens: keep only gsub's first return value (drops the count)
    return ((vim.fn.readfile(path)[1] or ""):gsub("%s+$", ""))
  end
  return "harnt"
end

--- Build the stdin bootstrap `Metadata` protobuf frame the LS reads before
--- starting (raw protobuf, EOF-delimited). `api_key` is the cloud OAuth token
--- (a dummy still boots the LS; auth is lazy).
---@param opts? { api_key?: string, device_fingerprint?: string, ide_version?: string, extension_path?: string }
---@return string
function M.metadata_frame(opts)
  opts = opts or {}
  return pb.encode({
    { no = META.ide_name, str = "Neovim" },
    { no = META.ide_version, str = opts.ide_version or "0.1" },
    { no = META.extension_name, str = "harnt" },
    { no = META.extension_path, str = opts.extension_path or "" },
    { no = META.locale, str = "en" },
    { no = META.device_fingerprint, str = opts.device_fingerprint or installation_id() },
    { no = META.api_key, str = opts.api_key or "" },
    { no = META.disable_telemetry, bool = true },
    { no = META.user_tier_id, str = "" },
  })
end

--- A spawned language server.
---@class harnt.antigravity.LS
---@field pid integer
---@field stop fun()

--- Spawn the language server: run the binary with the IDE's arg shape and feed it
--- the `Metadata` frame on stdin, then close stdin (EOF) so it boots. Ports are
--- fixed so `agy` can be pointed at the LS. stdout/stderr are ignored (LS logs).
---@param opts { ls_path: string, ext_port: integer, https_port: integer, lsp_port: integer, csrf: string, ext_csrf: string, metadata: string, cwd?: string }
---@return harnt.antigravity.LS
function M.spawn_ls(opts)
  local uv = vim.uv
  local stdin = assert(uv.new_pipe(false))

  ---@type uv.uv_process_t?
  local handle
  handle = uv.spawn(opts.ls_path, {
    args = {
      "--enable_lsp",
      "--csrf_token",
      opts.csrf,
      "--extension_server_port",
      tostring(opts.ext_port),
      "--extension_server_csrf_token",
      opts.ext_csrf,
      "--https_server_port",
      tostring(opts.https_port),
      "--lsp_port",
      tostring(opts.lsp_port),
      "--app_data_dir",
      "antigravity-ide",
      "--subclient_type",
      "ide",
      "--cloud_code_endpoint",
      "https://cloudcode-pa.googleapis.com",
    },
    cwd = opts.cwd,
    stdio = { stdin, nil, nil },
  }, function()
    if not stdin:is_closing() then
      stdin:close()
    end
    if handle and not handle:is_closing() then
      handle:close()
    end
  end)
  assert(handle, "antigravity: could not spawn language_server at " .. opts.ls_path)

  -- Write the bootstrap metadata, then close the write side so the LS sees EOF
  -- and finishes reading its initial metadata.
  stdin:write(opts.metadata)
  stdin:shutdown()

  return {
    pid = handle:get_pid(),
    stop = function()
      if handle and not handle:is_closing() then
        pcall(function()
          handle:kill("sigterm")
        end)
      end
    end,
  }
end

--- Whether the Antigravity LS (i.e. the IDE) is available.
---@return boolean
function M.detect()
  return M.find_ls() ~= nil
end

return M
