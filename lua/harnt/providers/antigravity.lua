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

-- === ExtensionServer: UnifiedStateSync / OAuth ===================================
-- The LS authenticates by subscribing to the `uss-oauth` state topic and reading
-- two keys; harnt serves them (token from the keychain). Verified via serve-verify
-- against the real LS — see ANTIGRAVITY.md "AUTH CRACKED".

--- uss-oauth state keys the LS reads (verified).
local OAUTH_KEY = {
  auth_state = "authStateWithContextSentinelKey", -- value: plain JSON {state, context}
  token_info = "oauthTokenInfoSentinelKey", -- value: base64(protobuf OAuthTokenInfo)
}

--- `OAuthTokenInfo` protobuf field numbers (decoded from the LS descriptors).
local OAUTH_TOKEN_INFO = { access_token = 1, token_type = 2, refresh_token = 3 }

--- Read agy's OAuth token from the OS keychain (same source agy uses — its logs
--- say "authenticated via keyring"). Returns nil if unavailable.
---@return { access_token: string, token_type: string, refresh_token: string }?
function M.oauth_token()
  -- macOS keychain via go-keyring (service=gemini account=antigravity); the value
  -- is `go-keyring-base64:<base64 JSON>`.
  local out = vim.fn.system({
    "security",
    "find-generic-password",
    "-s",
    "gemini",
    "-a",
    "antigravity",
    "-w",
  })
  if vim.v.shell_error ~= 0 then
    return nil
  end
  local b64 = (out:gsub("%s+$", "")):gsub("^go%-keyring%-base64:", "")
  local ok, obj = pcall(function()
    return vim.json.decode(vim.base64.decode(b64))
  end)
  if not ok or type(obj) ~= "table" or type(obj.token) ~= "table" then
    return nil
  end
  return {
    access_token = obj.token.access_token or "",
    token_type = obj.token.token_type or "Bearer",
    refresh_token = obj.token.refresh_token or "",
  }
end

--- Build one UnifiedStateSync KV row: `{ #1 key, #2 value{ #1 payload } }`.
---@param key string
---@param payload string the value string (plain JSON or base64(proto), per key)
---@return string encoded row message
local function kv_row(key, payload)
  local value_msg = pb.encode({ { no = 1, str = payload } })
  return pb.encode({ { no = 1, str = key }, { no = 2, msg = value_msg } })
end

--- Build the `uss-oauth` subscribe response (one `initial_state` frame body) that
--- authenticates the LS: signed-in auth-state + the base64(protobuf) token info.
---@param token { access_token: string, token_type: string, refresh_token: string }
---@return string subscribe_response encoded SubscribeResponse{ initial_state }
function M.oauth_state_response(token)
  local auth_json = vim.json.encode({
    state = "signedIn",
    context = { project = "", showProjectError = false, errorMessage = "" },
  })
  local token_proto = pb.encode({
    { no = OAUTH_TOKEN_INFO.access_token, str = token.access_token },
    { no = OAUTH_TOKEN_INFO.token_type, str = token.token_type },
    { no = OAUTH_TOKEN_INFO.refresh_token, str = token.refresh_token },
  })
  local initial_state = pb.encode({
    { no = 1, msg = kv_row(OAUTH_KEY.auth_state, auth_json) },
    { no = 1, msg = kv_row(OAUTH_KEY.token_info, vim.base64.encode(token_proto)) },
  })
  return pb.encode({ { no = 1, msg = initial_state } }) -- SubscribeResponse{ initial_state=1 }
end

--- Whether the Antigravity LS (i.e. the IDE) is available.
---@return boolean
function M.detect()
  return M.find_ls() ~= nil
end

return M
