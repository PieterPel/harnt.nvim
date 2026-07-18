# PLAN.md — harnt.nvim

**Goal:** One Neovim plugin that drives *any* native-TUI coding agent **at full native fidelity** by hosting the reverse-MCP / IDE-callback channel each agent already speaks, behind a single shared editor-context / diff / approvals / keymap layer. No lowest-common-denominator chat box. No feature loss. We never render the agent's chat — its own TUI does.

This document is the *what* and the *how*. See `BET.md` for the *why* and what we're wagering on.

---

## 0. The one thing to understand first

Every modern coding agent ships **its own TUI** and a way to reach *into* the editor for the editor-shaped work. That reverse channel has different names and different wires per vendor, but one shape:

| | **The one shape — editor as tool-server (reverse-MCP)** |
|---|---|
| Who drives | The agent — it keeps its own full TUI |
| Editor's job | Answer `openDiff` / `getDiagnostics` / selection, push context, surface approvals, apply edits |
| Wire | Editor hosts a local server; the agent's CLI connects *in* |
| Discovery | lockfile / discovery dir + env var + auth token |
| Native names | Claude Code IDE integration · Codex `/ide` · Gemini IDE companion · Qwen |
| Fidelity | 100% — we never replace or wrap the agent's UI |

**We host that channel for N agents and share everything on the editor side.** The wire differs (Claude: WebSocket; Codex/Gemini: local-HTTP/SSE) and the discovery differs (lockfile paths, env var names), but those are *parameters of one base*, not different architectures.

**Rule:** always use each agent's richest native surface — its own TUI plus its IDE-callback channel. Never a bridge, never a shim, never a headless app-server we'd have to render ourselves.

**Corollary / hard boundary:** an agent that offers *only* a headless "editor drives and renders" surface (ACP, app-server as sole surface) is **out of scope** — see §7. We host reverse channels; we do not build chat UIs.

---

## 1. Architecture

Three layers. The bottom two are shared across every provider; only the adapter layer is vendor-specific, and an adapter is a config table.

```
┌─────────────────────────────────────────────────────────────┐
│  Frontend (one shape, shared)                                │
│   agent's own TUI in a terminal split                        │
│   + our diff popup · approval popup · statusline             │
├─────────────────────────────────────────────────────────────┤
│  Provider registry  (dap/conform-style; 3rd parties extend)  │
│   reverse_mcp base                                           │
│     └ claude (ws) · codex (http) · antigravity (http) · qwen │
├─────────────────────────────────────────────────────────────┤
│  Editor services  (WRITTEN ONCE, agent-agnostic)             │
│   context · diff · approvals · apply/reload                  │
├─────────────────────────────────────────────────────────────┤
│  Transport primitives                                        │
│   jsonrpc codec · ws server · local-http/SSE server          │
└─────────────────────────────────────────────────────────────┘
```

### 1.1 Transport primitives (`lua/harnt/transport/`)
- `jsonrpc.lua` — JSON-RPC 2.0 codec: request/response id-correlation + notification dispatch. Transport-agnostic; used by every adapter. Built on `vim.json` + `vim.uv`.
- `ws.lua` — RFC-6455 server (lift/borrow claudecode.nvim's implementation). Powers Claude's IDE integration.
- `http.lua` — local streamable-HTTP / SSE MCP server, listen on port 0. Powers Codex `/ide` and the Gemini companion.

**Deliberate stance:** pure Lua, in-process, on `vim.uv`. No mandatory Node/Bun runtime, no mandatory daemon. (See `BET.md` bet #4.)

### 1.2 Editor services (`lua/harnt/services/`) — the crown jewels
These read/write Neovim and know **nothing** about any agent. They are the real shared value, and they are identical for every provider.
- `context.lua` — normalized selection, open buffers, cursor, workspace roots, diagnostics; debounced change events. **Plus** optional LSP + Tree-sitter symbol resolution exposed as agent tools (borrowed from vaijab/gemini-cli.nvim) — offered to *every* agent, not just Gemini.
- `diff.lua` — native split diff, **file-level** accept(with-edits)/reject. Sets buffer-local vars so auto-save plugins don't auto-accept (a bug claudecode.nvim had to fix). Copies claudecode's simplicity, not avante's per-hunk complexity.
- `approvals.lua` — allow-once / allow-always / deny-once / deny-always via `nui` or `vim.ui.select`.
- `apply.lua` — apply edits + `checktime`/reload touched buffers.

### 1.3 Provider adapters (`lua/harnt/providers/`)
A single `Provider`/`Session` contract over one base class every agent parameterizes:

```
---@class Provider
---@field name string
---@field detect fun():boolean            -- CLI present + authenticated
---@field start fun(ctx):Session

---@class Session
---@field interrupt fun()
---@field on fun(event, cb)                -- canonical events (see 1.5)
---@field respond fun(id, result)          -- answer server-initiated requests (approvals)
---@field stop fun()
```

- **`reverse_mcp` base:** listen → write discovery file → set env for the spawned terminal → validate auth token → register editor tools → push context notifications → route the agent's server-initiated requests (diff, approval) to our services. `claude`, `codex`, `antigravity` specialize via a config table: transport (`ws` vs `http`), discovery path (`~/.claude/ide/*.lock` vs Codex's / Antigravity's dir), env var names (`ENABLE_IDE_INTEGRATION`, `CODEX_CODE_SSE_PORT`, `*_IDE_SERVER_PORT`, …), auth header, tool-name map.
- **We do not render a chat UI. Ever.** The agent's own TUI, launched in a terminal split, *is* the chat. Our job is context + diff + approvals + apply, plus a consistent keymap surface around it.

> **Pin the wire before you build an adapter.** The IDE-callback protocols (especially Codex `/ide`) are under-documented by vendors. Read the reference plugin (claudecode.nvim for Claude; ishiooon/codex.nvim for Codex) or the CLI source to confirm transport, discovery path, env vars, tool names, and auth *before* committing the config table. The architecture is confirmed; the exact bytes are per-vendor homework.

### 1.4 Provider registry
Modeled on `nvim-dap` adapters / `conform.nvim` formatters: a table anyone can register. Because every adapter is the same shape, the table *is* the adapter.

```lua
require("harnt").register_provider({
  name = "codex",
  cmd = { "codex" },                    -- launched in a terminal split; /ide connects back
  transport = "http",                   -- vs "ws" for claude
  discovery = { ... },                  -- dir + lockfile format
  env = { ENABLE_IDE_INTEGRATION = "true", CODEX_CODE_SSE_PORT = "%PORT%" },
  tools = { open_diff = "...", ... },   -- tool-name map onto our services
})
```

### 1.5 Canonical events + capability passthrough
Normalize **only the UI-critical surface** the editor services actually react to: `session.started/completed/failed`, `tool.started/completed`, `approval.requested/resolved`, `diff.ready/closed`.

**Never flatten provider-native semantics into a fake universal schema.** Every native payload stays attached under `payload.provider`, and provider-specific requests surface as namespaced events on a `HarntEvent` `User` autocmd. This is the anti-ACP guarantee at the schema level: consistency for the common surface, a documented escape hatch for the long tail. Feature loss is a **bug**, not a tradeoff. (In practice most of the agent's richness never touches this schema at all — it lives in the agent's own TUI, which we never intercept.)

---

## 2. Scope

### v1 in scope
- Shared transport + editor services (`context`, `diff`, `approvals`, `apply`) against a **Fake** provider.
- **Claude** provider — reverse-MCP over **WebSocket**, lockfile discovery. *Flagship: the proven model.*
- **Codex** provider — reverse-MCP over **local-HTTP/SSE** (`/ide`), its own discovery. *Proves the base generalizes across a second transport + second vendor.*
- **Fake** provider — in-process, for E2E + services dev without real CLIs.
- Provider registry + capability passthrough + `HarntEvent` autocmd.
- Unified command + keymap surface across all providers.
- `:checkhealth harnt` per provider (binary present, version, auth, discovery dir writable, port bindable).

### v1 explicitly out of scope
- Headless / editor-drives-and-renders agents (ACP, app-server-only). **Permanent non-goal**, not a deferral — see §7.
- Persistence / session restore across restarts (see Open Questions — optional, never a daemon).
- Multi-instance attach.
- Per-hunk diff (v1 is file-level).
- Worktree orchestration; supervisor / parallel multi-agent workflows.
- Web/desktop UI.
- Cursor `cursor-agent` (does it expose an `/ide`-style channel? — research spike first).

### Why this cut
Shipping **two agents on two different transports** in v1 is the whole point: it validates that one reverse-MCP base generalizes across vendors and wires. claudecode.nvim proved the model for one agent over one transport; we prove it's a *base*, not a one-off. If the model doesn't generalize, we want to know in week 3, not month 3.

---

## 3. Provider roadmap

| Provider | Transport | Native surface | Milestone |
|---|---|---|---|
| Fake | — | in-process | v1 (gate) |
| **Claude** | WebSocket | IDE integration (lockfile) | v1 (gate) |
| **Codex** | local-HTTP/SSE | `/ide` (`ENABLE_IDE_INTEGRATION`) | v1 (gate) |
| Antigravity | local-HTTP | IDE Companion spec (MCP/HTTP) | v1.1 — reuses base |
| Qwen | local-HTTP | Gemini/Antigravity companion spec | fast-follow |
| ~~Gemini CLI~~ | local-HTTP | IDE companion | **dropped** — consumer access ended 2026-06-18; superseded by Antigravity CLI |
| Cursor | ? | unknown | research spike first |

> **Note (2026-07):** Gemini CLI was the obvious third provider — its IDE Companion spec is textbook reverse-MCP over HTTP — but Google deprecated it in favour of **Antigravity CLI**, which inherits the same companion spec. We target Antigravity directly. Same base, same transport, live tool.

---

## 4. Implementation sequence

Order matters. Fake provider exists early so services work proceeds without real CLIs.

- [ ] **M0 — Bootstrap.** Repo layout, `plugin/harnt.lua`, `checkhealth`, busted-in-nvim harness, CI. Fake provider stub emitting canned tool/diff/approval events.
- [ ] **M1 — Transport + editor services.** `jsonrpc` codec; `context`/`diff`/`approvals`/`apply` services fully tested against Fake. This is the reusable heart; get it right before any real agent.
- [ ] **M2 — Claude (WebSocket).** `reverse_mcp` base + `ws` transport + lockfile discovery + auth token + editor-tool registration. Claude's own TUI runs in a terminal split; we provide context + `openDiff` + `getDiagnostics` + selection + apply. **Acceptance: plan mode, slash commands, and `/compact` all still work — because we never touched its UI.**
- [ ] **M3 — Codex (local-HTTP/SSE) — the generalization proof.** `http` transport + Codex `/ide` adapter as a *config table* on the same base. Confirm the base didn't need to fork for a second vendor/transport. **Acceptance: Codex `/ide` diffs, approvals, and context all route through our shared services; the base gained parameters, not conditionals.**
- [ ] **M4 — Registry + passthrough + unified UX.** Provider registry API, `payload.provider` passthrough, `HarntEvent` autocmd, unified `:Harnt*` commands and keymaps, docs.
- [ ] **M5 — Fast-follow adapters.** Antigravity and Qwen, each a thin table on the existing base — the proof that the base pays off.
- [ ] **M6 — (Optional) persistence.** State file or lightweight SQLite for session listing/resume, strictly opt-in. No mandatory daemon. Cross-instance attach only if it stays in-process-friendly.
- [ ] **M7 — Release gating.** See §6.

---

## 5. Frontend

There is one frontend shape, and it is deliberately minimal:

- The agent's native TUI, launched in a terminal split — **this is the transcript, and we never touch it.**
- Our **diff popup** (file-level accept-with-edits / reject).
- Our **approval popup** (allow/deny, once/always).
- A **statusline** segment (which agent, session state).
- One consistent set of **commands + keymaps** wrapping all of the above.

That's the entire surface. The value is that it's *identical across every agent* — same diff flow, same approval keys, same config, whether you're driving Claude or Codex or Gemini. We are not a chat UI; we are the editor-side connective tissue that every native-TUI agent needs and none of them share today. (The old "two plugins in a trenchcoat" risk is gone: there is one surface, one shape.)

### Commands (v1)
`:HarntOpen` · `:HarntNew [provider]` · `:HarntStop` · `:HarntAddFile` · `:HarntDiffAccept` · `:HarntDiffReject` · `:HarntApprove`

### Keymaps (v1)
`<CR>` open session · `n` new · `q` close panel · `1`–`4` approval (allow once/always, deny once/always) · `F9`/`F10`/`F11` diff accept/reject/close.

---

## 6. Testing & release gate

- **busted-in-nvim** — editor services (context/diff/approvals/apply), transport codec, adapter state machines, all against the Fake provider.
- **Real-CLI smoke** — Claude and Codex behind env gates: launch the TUI, connect the reverse channel, propose+accept a diff, approve a command.
- **No-feature-loss acceptance (the differentiator's guardrail)** — per provider, enumerate native features and assert they still work end-to-end. Claude: plan mode, slash commands, `/compact`. Codex: `/ide` diffs, approval workflow, thread resume. **A provider does not ship until its native features are demonstrably intact.** (Cheap to satisfy, because we never render its chat — but we still assert it.)

Release v1 only when: Fake E2E green · Claude green with no-feature-loss check passing · Codex green with no-feature-loss check passing · `checkhealth` accurate.

---

## 7. Non-goals / guardrails

- Do **not** build a chat UI, transcript, or session-tree renderer for any agent — the agent's TUI is the chat. This is the whole project.
- Do **not** drive a headless / editor-drives-and-renders agent (ACP, app-server-only). It's a **permanent non-goal**: use an ACP client for those. Codex is in scope via `/ide`, not via app-server.
- Do **not** bridge an agent through a lossy surface when it has a richer native one.
- Do **not** require an external runtime or mandatory daemon.
- Do **not** ship per-hunk diff, worktrees, or a web UI in v1.
- Do **not** let "shared services" degrade into a pile of `if provider == …` conditionals — if behavior truly diverges, it belongs in the adapter's config table.

---

## 8. Open questions

- **Persistence:** state file vs. an optional SQLite binding vs. a *narrow optional* out-of-process sidecar — decided post-v1, and only if in-process can't do it cleanly.
- **Shape A editor UI depth:** how much beyond diff/approvals to give the agents before it stops being idiomatic (e.g. a picker for the agent's own slash commands? or is that its job?).
- **Codex `/ide` wire:** confirm exact transport, discovery, env vars, tool names, and auth from source before M3 (docs are thin).
- **Cursor `cursor-agent`:** does it expose an `/ide`-style reverse channel at all? If it's headless-only, it's a non-goal by §7. Research spike before committing.
- **Windows:** WS + local-HTTP both need a Windows path; framed-JSON transports were chosen partly for this.
