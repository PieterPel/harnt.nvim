# RELEASING.md — cutting a release

harnt publishes to [luarocks.org](https://luarocks.org). Releases are cut by
**release-please** (`.github/workflows/release-please.yml`): it keeps a standing
"chore(release): vX.Y.Z" PR up to date from Conventional Commits on `trunk`.
Merging that PR tags the release and creates a GitHub Release, which triggers
`.github/workflows/release.yml` to run the full gate and publish to
luarocks.org. You never run `git tag` by hand — `v0.1.0` was the one manual
exception, cut before release-please existed (see `CHANGELOG.md`).

## One-time setup

1. Get a luarocks API key: luarocks.org → your account → **API keys**.
2. Add it as a GitHub **repository secret** named `LUAROCKS_API_KEY`
   (Settings → Secrets and variables → Actions).
3. Apply the repo's default policies (branch protection, security features,
   merge/housekeeping, metadata): `just github-setup`. Idempotent — safe to
   re-run any time settings drift. See `scripts/github-repo-setup.sh`.

## Before merging the release PR

- [ ] `just ci` is green (fmt · lint · typecheck · test · smoke).
- [ ] `luarocks lint harnt.nvim-scm-1.rockspec` passes.
- [ ] README/`doc/harnt.txt` reflect the current commands, keymaps, providers.
- [ ] (If you recorded it) the demo GIF is committed and linked in the README.

## Cut the release

Merge the open `chore(release): vX.Y.Z` PR that release-please maintains — it
already contains the auto-generated changelog entry. Merging tags the release,
which triggers `.github/workflows/release.yml` to run `just ci` then
`just publish`, publishing the **`scm`** (dev) rock — it tracks the git source,
so `rocks.nvim` / luarocks users always get the latest.

Manual equivalent (no CI, e.g. to re-publish without a new tag):

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
     url = "git+https://github.com/PieterPel/harnt.nvim.git",
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
