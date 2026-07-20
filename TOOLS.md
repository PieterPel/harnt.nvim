# TOOLS.md — tooling decisions for harnt.nvim

**Guiding principle:** every tool here is a **headless CLI with a parseable exit code**, and every public surface is **typed with LuaCATS**. That combination is what serves humans (LSP completion, fast local feedback) and agents (a deterministic format → lint → typecheck → test loop) *with the same setup*. We optimize for that overlap on purpose.

Target: Neovim **0.10+**, LuaJIT / Lua 5.1 runtime.

---

## Decisions at a glance

| Concern | Decision | One-line reason |
|---|---|---|
| Formatter | **StyLua** (v2.x) | De-facto standard; deterministic; editor + CI + pre-commit |
| Linter | **Selene** | Fast Rust linter; the modern replacement for luacheck |
| Type checking (CI) | **`emmylua_check`** | A real standalone CLI type-checker — the agent's safety net |
| Editor LSP | **`emmylua_ls`** (primary) / **lua-language-server** (fallback) | One Rust toolchain for LSP+check+docs; LuaLS if we hit rough edges |
| Annotations | **LuaCATS** everywhere | Machine-checkable spec + human hints in one |
| nvim API types (dev) | **lazydev.nvim** | Standard; replaced neodev; works with both LSPs |
| Test framework | **busted, Neovim as the interpreter** | Only way to exercise real `vim.uv`/`vim.json` |
| Test entry point | **`luarocks test`** (+ `.busted`) | Runs busted-in-nvim; what the release action expects |
| In-editor tests | **neotest-busted** | Native test UI over the same busted suite |
| Packaging / release | **luarocks** (rockspec) | Mature; the release automation targets it today |
| Dev ergonomics | **Lux** (optional, luarocks-compatible) | Faster, generates `.luarc.json`, built-in check+test |
| Release CI | **luarocks-tag-release** action | Publishes + runs tests on nvim stable & nightly |
| Conventions bible | **lumen-oss/nvim-best-practices** | Closest thing to an official rulebook |

---

## The decisions, with reasons

### Formatter — StyLua
Deterministic, near-zero-config, universally used across the ecosystem, and it runs identically in the editor, in pre-commit, and in CI. Note v2 renamed the config file to `.stylua.toml` (dot-prefixed).
- **Config:** `.stylua.toml`
- **Check (CI/agent):** `stylua --check .`
- **Fix:** `stylua .`

### Linter — Selene
Fast Rust-based linter that superseded luacheck for new projects. Ships a Vim/Neovim standard-library definition so it understands `vim.*` globals. We drop luacheck to avoid two overlapping linters; `emmylua_check` covers the type-level diagnostics luacheck can't.
- **Config:** `selene.toml` (+ a `vim` std lib entry)
- **Run:** `selene .`

### Type checking — LuaCATS + `emmylua_check`
This is the highest-leverage decision in the file. We annotate every public function/class with **LuaCATS**, then gate CI on **`emmylua_check`**, a standalone static analyzer from the emmylua-analyzer-rust toolchain. Reason: it turns the `Provider`/`Session`/event contracts into something a machine verifies — a human can't misread them and an agent can't silently break them. LuaLS has no comparable CI-friendly checker, which is why the *check* step is emmylua regardless of which LSP we pick for editing.
- **Config:** `.luarc.json` (shared with the LSP) or `.emmyrc.json`
- **Run:** `emmylua_check .`

### Editor LSP — `emmylua_ls` (primary), lua-language-server (fallback)
**Primary: `emmylua_ls`.** Picking it keeps us on a single Rust toolchain — one language server, one checker (`emmylua_check`), one doc generator (`emmylua_doc_cli`), one config format — which is faster and simpler than mixing vendors. It reads the same `.luarc.json` we already commit for CI, so editor and CI see an identical view.

**Fallback: lua-language-server (LuaLS).** The mature incumbent. This is the more conservative pick; if `emmylua_ls` shows rough edges on our codebase, switch the *editor* LSP to LuaLS and keep `emmylua_check` in CI. Nothing else changes. lazydev supports both, so this swap is free.

> **This is a genuinely contested call.** emmylua is the newer, faster, more capable-on-paper option; LuaLS is the battle-tested one. We lead with emmylua for the unified toolchain + CI checker, and treat LuaLS as a documented escape hatch rather than a regret.

### nvim API types — lazydev.nvim
The standard way to load Neovim's runtime Lua types on demand for the LSP (it replaced neodev.nvim). Gives correct completion/diagnostics for `vim.*` without bloating the workspace, and supports both LuaLS and `emmylua_ls`.

### Tests — busted, with Neovim as the Lua interpreter
**Non-negotiable for this plugin.** harnt.nvim's core lives on `vim.uv` (terminal spawn, TCP/WebSocket, local-HTTP) and `vim.json`; a plain-Lua runner can't touch those. Running **busted with Neovim as the interpreter** (via `luarocks test` + a `.busted` file + a `test` block in the rockspec) gives tests the real Neovim API.
- **Entry point:** `luarocks test` (or Lux's busted-nlua backend / `nlua`)
- **In editor:** neotest-busted
- **Fallback:** plenary's busted-style harness is lighter and fine for pure-Lua units, but we standardize on real busted+nlua because we need the full API.
- **Design tie-in:** the **Fake provider** (see PLAN.md) is the deterministic seam that keeps the whole suite runnable headless and CI-safe — build it first.

### Packaging & release — luarocks (canonical), Lux (optional dev)
**Canonical format: luarocks** (a rockspec). Reason: the release/CI automation we want — the **luarocks-tag-release** GitHub Action, which publishes and runs `luarocks test` on Neovim stable *and* nightly — targets luarocks today and is mature.

**Optional dev-time: Lux.** Lux (from lumen-oss, formerly nvim-neorocks) is luarocks-compatible and nicer to develop against: a single `lux.toml`, it generates our `.luarc.json` from declared dependencies, and it has built-in type-check and busted-nlua backends. Because it's compatible, we can use it locally without changing the canonical rockspec.
- **Revisit trigger:** when rocks.nvim completes its migration to Lux, promote Lux to canonical.

### Release CI — luarocks-tag-release + a checks matrix
On tag, publish via the action. On every PR, run the full gate across an **nvim stable + nightly** matrix:
```
stylua --check .
selene .
emmylua_check .
luarocks test
```
Stable+nightly catches API drift early — cheap insurance for a plugin this API-heavy.

### Conventions — lumen-oss/nvim-best-practices
Our rulebook for the non-tool decisions: validate merged user config with `vim.validate`; expose scoped subcommands (`:Harnt install`) instead of one command per action; ship `:checkhealth harnt`; be careful about what internal types leak into the public API via annotations.

---

## The agent layer

Everything above doubles as agent infrastructure. To make it explicit:

- **Commit `.luarc.json`.** One file gives the human's LSP and the agent's `emmylua_check` the *same* view (nvim runtime library, Lua version, `vim` global). No drift between "looks fine in my editor" and "passes the checker." Lux can generate it.
- **Annotate with LuaCATS, always.** The `Provider`/`Session` contracts become an enforced spec, not a comment.
- **Ship an `AGENTS.md`** at the repo root (symlink or copy to `CLAUDE.md`) whose core is the exact loop:
  ```
  stylua --check .     # format
  selene .             # lint
  emmylua_check .      # typecheck
  luarocks test        # test (busted-in-nvim)
  ```
  An agent that can run those four and read exit codes iterates safely instead of guessing.
- **Gate CI on all four.** That gate is what lets a human *or* an agent refactor the reverse-MCP core without fear — which is the entire reason the project is tractable.

---

## Minimum repo furniture (M0 checklist)

- [ ] `.stylua.toml`
- [ ] `selene.toml` (+ `vim` std lib)
- [ ] `.luarc.json` (shared: LSP + `emmylua_check`)
- [ ] `harnt.nvim-scm-1.rockspec` with a `test` block
- [ ] `.busted`
- [ ] `lux.toml` *(optional, if adopting Lux locally)*
- [ ] `AGENTS.md` (+ `CLAUDE.md`)
- [ ] `.github/workflows/ci.yml` — checks matrix on nvim stable + nightly
- [ ] `.github/workflows/release.yml` — luarocks-tag-release
- [ ] `.editorconfig`

---

## Version / pinning notes

- Pin tool versions in CI (StyLua, Selene, emmylua, busted) so formatting/lint results are reproducible across humans, agents, and CI. A drifting formatter version produces spurious diffs.
- Test against **both** Neovim stable and nightly from day one; don't wait until something breaks.

---

## Contested calls, summarized

Two decisions here are real judgment calls, not settled facts:
1. **`emmylua_ls` vs lua-language-server** as the daily editor LSP — we lead with emmylua for the unified toolchain + CI checker; LuaLS is the safe fallback and the swap is free.
2. **luarocks vs Lux** for packaging — we keep luarocks canonical for the mature release path and use Lux optionally for dev speed, revisiting when the ecosystem finishes moving.

Everything else (StyLua, Selene, LuaCATS, `emmylua_check` in CI, busted-in-nvim, lazydev, the best-practices conventions) is a straightforward recommendation with no serious competing option in 2026.
