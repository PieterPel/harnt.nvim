# harnt.nvim

> Run **any** coding agent in Neovim, at full native fidelity, behind one shared
> editor layer. The agent keeps its own TUI — harnt never renders a chat box, so
> no feature is ever lost.

<!-- Demo: record with `just demo` (see DEMO.md), then:
![harnt.nvim: two agents, one diff flow](./assets/demo.gif) -->
_Demo GIF coming soon — `just demo` stages it; see [`DEMO.md`](./DEMO.md)._

**Status: beta.** Working end-to-end for **Claude Code**, **Codex**,
**Antigravity (`agy`)**, and **OpenCode** — diffs, approvals, editor-context, a change-log, and one
keymap set across all three, each verified against the real CLI. Pure Lua, no
daemon. Not yet on luarocks (install from git — see below). See [`PLAN.md`](./PLAN.md)
for the roadmap and [`BET.md`](./BET.md) for why this exists.

---

## The idea in one paragraph

Every modern coding agent ships its own terminal UI and a way to reach *into*
your editor for editor-shaped work — open this diff, give me the selection, what
are the diagnostics, apply these edits, ask the user to approve. Claude Code
calls it its IDE integration, Codex has `/ide` and its app-server, Antigravity
has lifecycle hooks, OpenCode hosts an HTTP server its own TUI is a client of.
Different wires, one **shape**: the editor is a tool-server
the agent reaches back into. harnt hosts that channel for many agents and unifies
the genuinely shared part — **context, diff, approvals, apply, and one set of
keymaps** — while each agent's own TUI stays untouched in a terminal split. That
is the opposite of ACP-style tools, which unify the *agent protocol* and strip
the deep features in the process.

## What it is (and isn't)

- ✅ One keymap / diff / approval / config surface across every agent.
- ✅ Full native fidelity — plan mode, slash commands, `/compact`, streaming,
  resume all live in the agent's own TUI, which we never replace.
- ✅ Interactive **diffs** and **approvals** shown *in Neovim*, even when the
  agent would otherwise auto-apply; plus a per-session **change-log**
  (`:Harnt changes`) of everything the agent touched.
- ✅ Pure Lua, in-process, on `vim.uv`. No mandatory Node/Bun runtime, no daemon.
- ❌ **Not** a chat UI, and **not** a driver for headless-only agents (ACP /
  app-server as sole surface). Use an ACP client for those — see the non-goal in
  [`PLAN.md`](./PLAN.md).

## Providers

| Provider | How harnt connects | Diffs / approvals | Editor context | Status |
|---|---|---|---|---|
| **Claude Code** | WebSocket IDE integration (lockfile) | `openDiff` | IDE tools (live) | ✅ verified |
| **Codex** | `app-server` proxy (stdio) behind `codex --remote`; `/ide` unix socket for context | app-server tap | `/ide` socket (pull) | ✅ verified |
| **Antigravity (`agy`)** | lifecycle hooks (`.agents/hooks.json`) | `PreToolUse` gate | `PreInvocation` inject | ✅ verified |
| **OpenCode** | client of the agent's own HTTP server (`opencode serve`) behind `opencode attach`; `/event` SSE tap | edit → diff review, cmd → approval (HTTP reply) | `@`-mention push (`/tui/append-prompt`) | ✅ wire verified |
| Fake | in-process | — | — | test seam |
| Qwen | companion spec | — | — | planned |

Each agent is met in its *own* native protocol — there is deliberately no
universal wire format (that's the whole bet). Adding an agent is a Lua table on
the shared editor services; third parties can register one without a core PR.
See [`PROVIDERS.md`](./PROVIDERS.md).

## Requirements

- Neovim **0.10+**.
- The CLI for each agent you want to use, installed and authenticated:
  - Claude Code (`claude`), Codex (`codex`), Antigravity (`agy`), OpenCode (`opencode`).
- `nc` (netcat) — only for Antigravity's hook bridge.
- Run `:checkhealth harnt` — it reports, per provider, what's present and what's missing.

## Installation

Pure Lua, no dependencies beyond Neovim. Not published to luarocks yet, so install
from git.

<details open>
<summary>lazy.nvim</summary>

```lua
{
  "harnt.nvim",
  url = "https://codeberg.org/PieterPel/harnt.nvim",
  opts = {},
  -- optional: your own launch keymaps
  keys = {
    { "<leader>ac", "<cmd>Harnt open claude<cr>", desc = "harnt: Claude" },
    { "<leader>ax", "<cmd>Harnt open codex<cr>",  desc = "harnt: Codex" },
    { "<leader>ag", "<cmd>Harnt open antigravity<cr>", desc = "harnt: Antigravity" },
    { "<leader>ao", "<cmd>Harnt open opencode<cr>", desc = "harnt: OpenCode" },
  },
}
```
</details>

<details>
<summary>rocks.nvim</summary>

```vim
:Rocks install harnt.nvim   " once published to luarocks
```
</details>

## Quickstart

```lua
require("harnt").setup({})   -- registers claude, codex, antigravity, opencode
```

Then:

```
:Harnt open claude        " launch the agent's TUI in a split; harnt hosts its channel
```

Work with the agent as you normally would. When it proposes an edit, harnt shows
it as a diff **in Neovim**; when it wants to run a command, an approval popup
appears. The keys are the same for every agent.

## Commands

| Command | Does |
|---|---|
| `:Harnt open [provider]` | Launch a provider's TUI (default `claude`) |
| `:Harnt toggle [provider]` | Show/hide (or launch) a provider's terminal |
| `:Harnt stop [provider]` | Stop one provider, or all |
| `:Harnt send` | Send the current file/selection to running agents (@-mention) |
| `:Harnt accept` / `reject` | Accept / reject the current diff |
| `:Harnt review` | Reject the diff and send your inline comments back as feedback |
| `:Harnt changes` | Browse the session change-log (read-only) |
| `:Harnt health` | `:checkhealth harnt` |

## Keymaps (buffer-local, inside a diff/review)

| Key | Action |
|---|---|
| `<F9>` | accept the diff |
| `<F10>` | reject the diff |
| `<leader>c` | comment on the current line |
| `<leader>R` | submit review (reject + send comments as feedback) |

All four are configurable:

```lua
require("harnt").setup({
  keymaps = { diff = { accept = "<F9>", reject = "<F10>", comment = "<leader>c", review = "<leader>R" } },
  -- diff = { presenter = fn },          -- swap the diff UI (default: side-by-side vimdiff)
  -- approvals = { chooser = fn },       -- swap the approval prompt (default: vim.ui.select)
})
```

## Per-provider notes

- **Claude Code** — harnt writes `~/.claude/ide/<port>.lock` and hosts the
  WebSocket the CLI connects into; edits are also recorded via a PostToolUse hook
  so auto-applied changes still show in `:Harnt changes`.
- **Codex** — harnt proxies `codex app-server` (stdio) and launches the native
  TUI via `codex --remote`; diffs/approvals are tapped from that stream, while a
  separate `/ide` unix socket feeds the agent your live selection + open files.
- **Antigravity (`agy`)** — harnt merges a `harnt` hook into `.agents/hooks.json`
  (non-destructively, restored on stop): `PreToolUse` gates edits/commands
  (blocking = interactive diffs), `PreInvocation` injects editor context. Needs
  `nc`. Runs `agy` interactively in the split.
- **OpenCode** — harnt spawns `opencode serve` (its own HTTP+SSE server) and
  launches the native TUI via `opencode attach`; it taps the `/event` stream. Edit
  permissions show as an interactive diff (accept/reject/comment, reconstructed
  from the tool call and answered over HTTP with free-text feedback on reject);
  command permissions use the approval popup; auto-applied edits land in `:Harnt
  changes`; and `:Harnt send` pushes the current file/selection as a native
  `@`-mention. The TUI drives and renders; harnt observes. OpenCode also ships a
  headless `opencode acp` surface — the exact thing harnt refuses to render; we use
  the native TUI + server instead. See [`OPENCODE.md`](./OPENCODE.md).

## No feature loss (the guarantee)

Because harnt never renders the agent's chat, the agent's own features are
untouched. Verified end-to-end per provider (`just e2e-*`):

| Agent | Verified intact through harnt |
|---|---|
| Claude | plan mode, slash commands, `/compact`; `openDiff` + diagnostics + selection |
| Codex | `/ide` context ("IDE context is on"), app-server diffs + approvals, native TUI |
| Antigravity | `PreToolUse` diff gate (reject blocks / accept writes), `PreInvocation` context |
| OpenCode | native TUI (plan/build agents, slash commands, sessions) untouched; edit permission → diff review, command → approval, `session.diff` → change-log, `:Harnt send` → `@`-mention |

## Extending

Add an agent with a table — see [`PROVIDERS.md`](./PROVIDERS.md). The shared
services (`context` / `diff` / `approvals` / `apply` / `changes`) are the reusable
heart; a provider is mostly discovery + env + a tool/decision map on top.

## Development

Everything runs through Nix + `just`, identically on your machine and in CI:

```sh
nix develop            # enter the toolchain (stylua, selene, emmylua, busted, …)
just                   # list tasks
just ci                # the full gate: fmt-check · lint · typecheck · test · smoke
just test              # busted, with Neovim as the Lua interpreter (nlua)
just smoke             # clean-room load check (fresh install, nothing else on rtp)
just e2e-codex-ide     # real-CLI smoke (needs the agent authed); see the justfile
```

Tooling decisions live in [`TOOLS.md`](./TOOLS.md).

## License

[MIT](./LICENSE) © 2026 Pieter Pel
