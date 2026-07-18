# harnt.nvim

> Run **any** coding agent in Neovim, at full native fidelity, behind one shared
> editor layer. The agent keeps its own TUI — harnt never renders a chat box, so
> no feature is ever lost.

**Status: pre-alpha (M0).** The architecture is settled; the code is being built
Fake-provider-first. Not yet usable. See [`PLAN.md`](./PLAN.md) for the roadmap
and [`BET.md`](./BET.md) for why this exists.

---

## The idea in one paragraph

Every modern coding agent ships its own terminal UI and a way to reach *into*
your editor for editor-shaped work — open this diff, give me the selection,
what are the diagnostics, apply these edits, ask the user to approve. Claude
Code calls it its IDE integration, Codex calls it `/ide`, Gemini/Antigravity
call it the IDE companion. Different wires, one **shape**: the editor is a
tool-server the agent connects back into (reverse-MCP). harnt hosts that channel
for many agents and unifies the genuinely shared part — **context, diff,
approvals, apply, and one set of keymaps** — while each agent's own TUI stays
untouched. That's the opposite of ACP-style tools, which unify the agent
protocol and strip the deep features in the process.

## What it is (and isn't)

- ✅ One keymap / diff / approval / config surface across every agent.
- ✅ Full native fidelity — plan mode, slash commands, `/compact`, streaming,
  resume all live in the agent's own TUI, which we never replace.
- ✅ Pure Lua, in-process, on `vim.uv`. No mandatory Node/Bun runtime, no daemon.
- ❌ **Not** a chat UI, and **not** a driver for headless-only agents (ACP /
  app-server as sole surface). Use an ACP client for those — see the non-goal in
  [`PLAN.md`](./PLAN.md).

## Providers

| Provider | Transport | Native surface | Status |
|---|---|---|---|
| Fake | — | in-process | v1 (test seam) |
| Claude Code | WebSocket | IDE integration | v1 |
| Codex | local-HTTP/SSE | `/ide` | v1 |
| Antigravity CLI | local-HTTP | IDE Companion spec | v1.1 |
| Qwen | local-HTTP | companion spec | fast-follow |

Adding an agent is a config table on the reverse-MCP base — third parties can
register one without touching core.

## Requirements

- Neovim **0.10+**

## Installation

> Nothing to install yet — this section is the intended shape once v1 lands.

<details>
<summary>lazy.nvim (via rocks)</summary>

```lua
{
  "PieterPel/harnt.nvim",
  -- url = "https://codeberg.org/PieterPel/harnt.nvim",
  opts = {},
}
```
</details>

## Development

Everything runs through Nix + `just`, identically on your machine and in CI:

```sh
nix develop            # enter the toolchain (stylua, selene, emmylua, busted, …)
just                   # list tasks
just ci                # the full gate: fmt-check · lint · typecheck · test
just test              # busted, with Neovim as the Lua interpreter (nlua)
```

Tooling decisions live in [`TOOLS.md`](./TOOLS.md).

## License

[MIT](./LICENSE) © 2026 Pieter Pel
