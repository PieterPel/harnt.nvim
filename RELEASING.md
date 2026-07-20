# RELEASING.md — cutting a release

harnt publishes to [luarocks.org](https://luarocks.org). The Codeberg release
workflow (`.forgejo/workflows/release.yml`) runs the full gate and publishes on
any `v*` tag; you can also publish by hand.

## One-time setup

1. Get a luarocks API key: luarocks.org → your account → **API keys**.
2. Add it as a Codeberg **repository secret** named `LUAROCKS_API_KEY`
   (Settings → Actions → Secrets).

## Before tagging

- [ ] `just ci` is green (fmt · lint · typecheck · test · smoke).
- [ ] `luarocks lint harnt.nvim-scm-1.rockspec` passes.
- [ ] README/`doc/harnt.txt` reflect the current commands, keymaps, providers.
- [ ] (If you recorded it) the demo GIF is committed and linked in the README.
- [ ] `CHANGELOG`/release notes drafted (optional but nice).

## Cut the release

The current workflow publishes the **`scm`** (dev) rock — it tracks the git
source, so `rocks.nvim` / luarocks users always get the latest. That's the
simplest path and works today:

```sh
git tag v0.1.0
git push origin v0.1.0        # CI runs `just ci` then `just publish`
```

Manual equivalent (no CI):

```sh
LUAROCKS_API_KEY=… just publish
```

## Optional: a pinned, versioned rock

`scm` always points at HEAD. For an immutable `0.1.0` on luarocks (so an install
resolves to that exact commit), add a versioned rockspec alongside the scm one:

1. Copy `harnt.nvim-scm-1.rockspec` → `harnt.nvim-0.1.0-1.rockspec`.
2. Set `version = "0.1.0-1"` and pin the source:
   ```lua
   source = {
     url = "git+https://codeberg.org/PieterPel/harnt.nvim.git",
     tag = "v0.1.0",
   }
   ```
3. `luarocks upload harnt.nvim-0.1.0-1.rockspec --api-key "$LUAROCKS_API_KEY"`.

(Or adopt the `luarocks-tag-release` action, which generates the versioned
rockspec from the tag automatically.)

## After release

- [ ] `luarocks search harnt.nvim` shows the new rock.
- [ ] A clean `rocks.nvim` / lazy install pulls it and `:checkhealth harnt` is green.
- [ ] Announce (see DEMO.md for the asset).
