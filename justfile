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

# The full gate — exactly what CI runs.
ci: fmt-check lint typecheck test

# Launch a clean Neovim with ONLY harnt loaded for a quick manual try, with
# convenience keymaps + an on-launch help popup (see scripts/try-init.lua). Works
# with any nvim — including the dev shell's bare one, which lacks your plugins.
try:
    env -u LUA_PATH -u LUA_CPATH nvim -u {{ justfile_directory() }}/scripts/try-init.lua

# Real-CLI e2e smoke vs Claude (needs `claude` on PATH + a trusted cwd).
# Nondeterministic + real API calls; deliberately NOT part of `ci`.
e2e-claude:
    env -u LUA_PATH -u LUA_CPATH nvim -l scripts/e2e-claude.lua

# Publish the rock to luarocks.org. Needs LUAROCKS_API_KEY. Runs on tag in CI,
# but works locally too: `LUAROCKS_API_KEY=... just publish`.
publish:
    luarocks upload harnt-scm-1.rockspec --api-key "${LUAROCKS_API_KEY}"
