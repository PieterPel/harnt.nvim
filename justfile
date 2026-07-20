# harnt.nvim task runner — the SAME pipeline locally and in CI.
# Enter the dev shell first (`nix develop`) so the tools are on PATH, or prefix
# any recipe with nix, e.g. `nix develop -c just ci`.

# Show available recipes
default:
    @just --list

# Format everything (nix, lua, toml, justfile) via treefmt
fmt:
    treefmt

# Fail if anything is unformatted (CI)
fmt-check:
    treefmt --ci

# Lint Lua
lint:
    selene .

# Type-check LuaCATS annotations (emmylua). Types vim.* via $VIMRUNTIME.
typecheck:
    emmylua_check .

# Run the test suite: busted with Neovim as the interpreter (nlua)
test:
    busted

# Clean-room load smoke: harnt loads + registers + :Harnt + :checkhealth with
# NOTHING else on the runtimepath (no flake, no user plugins). Deterministic.
smoke:
    env -u LUA_PATH -u LUA_CPATH nvim --clean -l {{ justfile_directory() }}/scripts/smoke-clean-load.lua

# The full gate — exactly what CI runs.
ci: fmt-check lint typecheck test smoke

# Launch a clean Neovim with ONLY harnt loaded for a quick manual try, with
# convenience keymaps + an on-launch help popup (see scripts/try-init.lua). Works
# with any nvim — including the dev shell's bare one, which lacks your plugins.
try:
    env -u LUA_PATH -u LUA_CPATH nvim -u {{ justfile_directory() }}/scripts/try-init.lua

# Clean Neovim in a seeded temp project, staged for recording the README demo
# (see DEMO.md for the storyboard). Needs an agent CLI authed to actually drive.
demo:
    env -u LUA_PATH -u LUA_CPATH nvim -u {{ justfile_directory() }}/scripts/demo-init.lua

# Real-CLI e2e smoke vs Claude (needs `claude` on PATH + a trusted cwd).
# Nondeterministic + real API calls; deliberately NOT part of `ci`.
e2e-claude:
    env -u LUA_PATH -u LUA_CPATH nvim -l scripts/e2e-claude.lua

# Real-CLI e2e smoke: Claude auto-accept edits reach the change-log via the
# injected PostToolUse hook. Needs `claude` on PATH + a trusted cwd.
e2e-claude-hooks:
    env -u LUA_PATH -u LUA_CPATH nvim -l scripts/e2e-claude-hooks.lua

# Real-CLI e2e smoke vs Codex app-server proxy (needs `codex` on PATH + authed).
# Drives one file-editing turn through the real transport + tap; asserts accept
# writes the file. Nondeterministic + real API calls; NOT part of `ci`.
e2e-codex:
    env -u LUA_PATH -u LUA_CPATH nvim -l scripts/e2e-codex.lua

# Real-CLI e2e smoke: real `codex` TUI pulls editor context over harnt's hosted
# /ide unix socket. Asserts codex issues an ide-context request we answer. Needs
# `codex` authed. Nondeterministic; NOT part of `ci`.
e2e-codex-ide:
    env -u LUA_PATH -u LUA_CPATH nvim -l scripts/e2e-codex-ide.lua

# Real-CLI e2e smoke: real `agy -p` routes its edit through harnt's PreToolUse
# hook gate (diff/deny) and fires PreInvocation (context). Asserts the deny
# blocks the write + the captured args map through the normalizer. Needs `agy`
# authed + `nc`. Nondeterministic + real API calls; NOT part of `ci`.
e2e-agy-hooks:
    env -u LUA_PATH -u LUA_CPATH nvim -l scripts/e2e-agy-hooks.lua

# Publish the rock to luarocks.org. Needs LUAROCKS_API_KEY. Runs on tag in CI,
# but works locally too: `LUAROCKS_API_KEY=... just publish`.
publish:
    luarocks upload harnt.nvim-scm-1.rockspec --api-key "${LUAROCKS_API_KEY}"
