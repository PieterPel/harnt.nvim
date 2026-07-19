# BET.md — why harnt.nvim, and what we're wagering

## The bet, in one sentence

**Every existing multi-agent editor tool unified the wrong layer.** They tried to unify the *agent protocol* — and to do that they had to pick one integration shape and force every agent through it, losing features for any agent richer than that shape. We bet the layer actually worth unifying is the **editor side** (context, diff, approvals, keymaps), which is genuinely shared — while every agent keeps its own native TUI, so **nothing is ever lost**.

---

## The problem we're attacking

Coding agents multiplied — Claude Code, Codex, Gemini CLI, Qwen — and people increasingly want more than one, on the same codebase, in the same editor. Each agent ships a good CLI *and* a way to plug into an editor. But the community's answer has split badly:

- **Per-agent plugins** (claudecode.nvim, codex.nvim, gemini-cli.nvim) each nail one agent at full fidelity — but every one has different keymaps, a different diff flow, a different config, a different approval popup. Run three agents and you're learning three plugins.
- **Protocol-unifying tools** (ACP clients, daemon-driven harnesses) give you one UI across agents — but only by bridging every agent down to a lowest-common-denominator surface, which **strips exactly the deep features** (plan mode, slash commands, `/compact`, streaming diffs) that power users came for.

So today you pick: **fidelity without consistency**, or **consistency without fidelity**. Nobody gives you both.

The reason nobody gives you both is that everyone tried to unify the *agent* — the thing that genuinely differs. The insight is that you don't have to. The agents already agree on something: **the modern coding agent keeps its own TUI and calls *into* the editor** for the editor-shaped work — open this diff, give me the selection, what are the diagnostics, apply these edits, ask the user to approve. Claude Code calls this its IDE integration; Codex calls it `/ide`; Gemini calls it the IDE companion. Different wires, identical *shape*: **the editor is a tool-server the agent reaches back into.**

That shape — call it reverse-MCP — is the thing worth unifying. Not the agent. The editor side.

---

## Why nothing that exists wins

| Tool | What it is | Where it falls short |
|---|---|---|
| **claudecode.nvim** | reverse-MCP, Claude only | Single vendor. The definitive proof that the reverse-MCP model works — but it's one agent, and the model isn't generalized. |
| **codex.nvim / gemini-cli.nvim / …** | Single vendor, native | Correct fidelity, zero breadth. Fragmented — a different UI, keymaps, and config per agent. You install and learn N of them. |
| **agentic.nvim / CodeCompanion (ACP)** | ACP client, many agents | ACP is the *lossy* bridge. Fine for ACP-native agents, but for Claude/Gemini/Codex it strips the deep features. The editor renders a generic chat; the agent's own experience is gone. |
| **harness.nvim** (sandudorogan) | daemon-driven, headless agents | Committed to the editor-drives-and-renders model, so it can't host a native-TUI agent without going headless (and it says so — Claude is deferred). Also requires a Bun daemon on `$PATH`. |

The gap is specific and unclaimed: **no tool generalizes the reverse-MCP model across every native-TUI agent, under one editor-services + keymap layer, with a no-feature-loss guarantee.** That's not a missing adapter. It's a missing architecture. It's claudecode.nvim's model, made vendor-neutral.

---

## What we bet on

Each bet is falsifiable. If the "wrong if" comes true, we should know and adjust.

### Bet 0 — Agents will keep offering (and improving) an `/ide`-style reverse mode

This is the load-bearing bet, so it goes first. Our whole architecture assumes the agent runs its **own** TUI and reaches back into the editor over a reverse channel — Claude's IDE integration, Codex's app-server, Gemini's companion. We do not render their chat.

> **Refinement (2026-07-19), from reverse-engineering real Codex.** The reverse
> channel is *not* always an `/ide`-style callback where the agent calls into a
> server we host. Codex taught us a second, equally valid shape: the agent's
> **native TUI talks to an app-server**, and we sit in the middle as a **proxy**,
> tapping the stream for the editor-shaped events (diffs, approvals). So the bet is
> really: *agents keep shipping a native-TUI mode whose editor-facing traffic we
> can host or tap* — broader than "`/ide` callback," and Codex is the proof. Note
> the sharpened line: "we do not render their chat" is the invariant; "we do not
> run any headless process" is **not** — harnt runs `codex app-server` purely as
> the wire while Codex's own TUI renders the chat. Driving a headless engine is
> fine; *rendering the agent's chat ourselves* is the thing we refuse. (Codex's
> `/ide` unix socket does exist but is context-only — see `CODEX.md`.)

- **Right if:** the major agents keep shipping a native-TUI-plus-editor-callback mode, and new agents adopt it (the direction of travel — Claude, Codex, Antigravity (née Gemini CLI), Qwen all have it; Codex is actively making its `/ide` *more* automatic, citing Claude Code as the bar; and Google carried the Gemini CLI IDE Companion spec forward into Antigravity CLI rather than dropping it).
- **Wrong if:** a genuinely popular agent ships **headless-only** (ACP/app-server as its *only* editor surface) and never adds a callback mode. That agent we structurally cannot host — see the non-goal below. If that becomes the norm rather than the exception, the bet is lost and the editor-drives-and-renders crowd was right.

### Bet 1 — The future is many agents, not one winner
People will keep running 2+ agents (different strengths, price, availability, taste), and will want to switch without switching editors or relearning the plugin.
- **Right if:** users routinely keep multiple agents configured and swap between them.
- **Wrong if:** one agent so dominates that lock-in is painless and breadth is worthless.

### Bet 2 — Native fidelity beats a unified generic UI
Given the choice, power users would rather keep each agent's *real* experience (plan mode, slash commands, streaming, thread resume) than have a prettier uniform chat box that quietly drops those features. This is the ACP objection, made load-bearing. Because we never render the agent's chat, we **cannot** drop a feature — this guarantee is structural, not aspirational.
- **Right if:** people choose us over ACP-based tools *specifically* to stop losing features.
- **Wrong if:** most users just want a simple consistent chat and never miss the deep features.

### Bet 3 — The shared layer is editor services + keymaps, not agent protocol
The genuinely reusable value is context capture, diff review, approvals, apply/reload, and *one consistent command/keymap surface*. Every native-TUI agent needs exactly these, in exactly the same shape. So we write them once, agent-agnostic, and let each adapter be a thin config table.
- **Right if:** `context`/`diff`/`approvals`/`apply` + keymaps cover the bulk of shared value and adapters stay small (a table, not a module).
- **Wrong if:** per-agent behavior leaks so heavily that "shared services" rot into `if provider == …` conditionals — meaning the agents share less than we think.

### Bet 4 — In-process and dependency-light beats a mandatory daemon
The nvim community rewards plugins that don't drag a Node/Bun runtime or a background daemon into every install. Reverse-MCP in pure Lua is already proven (claudecode.nvim); the transports are just WebSocket / local-HTTP, which `vim.uv` does natively. Persistence and multi-client are *opt-in*, not the price of entry.
- **Right if:** install friction and community trust favor us, and Lua-side clients stay maintainable.
- **Wrong if:** persistence / multi-instance attach prove to be must-haves that in-process Lua can't do cleanly.

### Bet 5 — A registry the community extends wins the ecosystem
Like `nvim-dap` and `conform.nvim`, the tool that lets third parties add an agent with a table — not a core PR — accumulates coverage faster than any single team. Because every adapter is the *same* shape (reverse-MCP: a transport, a discovery path, env vars, a tool-name map), a table is genuinely all it takes.
- **Right if:** outside contributors ship adapters.
- **Wrong if:** agent IDE protocols churn so fast that only a funded core can keep adapters alive.

---

## The guarantee that makes it real

**Feature loss is a bug, not a tradeoff.** Every provider ships with a no-feature-loss acceptance test that enumerates the agent's native capabilities and proves they still work through us. This is easy to promise *because we never render the agent's chat* — its TUI is untouched, so plan mode, slash commands, `/compact`, streaming, and resume are its concern, not ours. If we ever caught ourselves wrapping an agent's chat in our own UI, we'd be building the thing we exist to replace. This is the promise ACP structurally cannot make, and it's our whole reason to exist.

---

## The explicit non-goal (the edge of the bet)

**harnt does not drive headless agents.** An agent whose *only* editor surface is a headless, editor-drives-and-renders protocol (ACP, app-server as sole surface) is **out of scope** — supporting it would mean building the generic chat UI this project exists to avoid. For those, use an ACP client. This is a deliberate line, not an oversight: a sharp "no" is better positioning than a lossy "yes." (Codex is *in* scope precisely because it also offers `/ide`; we use that, not its app-server.)

---

## What winning looks like

- A user runs Claude in its full TUI *and* Codex in its full TUI, side by side, over the same file context, with **one** set of keymaps, one diff flow, one approval popup, one config — and loses nothing from either.
- Adding Antigravity or Qwen is a **table**, contributed from outside, on the existing reverse-MCP base.
- "I want more than one agent in Neovim without giving up features *or* learning five plugins" has exactly one obvious answer.

## What would kill us

- **Bet 0 is wrong:** the ecosystem drifts toward headless-only editor surfaces, and the agents worth running stop offering an `/ide`-style mode.
- **Bet 2 is wrong:** people don't actually value native fidelity enough to leave the simpler ACP tools.
- **Bet 3 is wrong:** the agents' reverse modes differ so much that "shared services" is a mirage and every adapter needs its own UI after all.
- A vendor ships a genuinely good universal *lossless* protocol that every agent adopts — collapsing the whole problem — at which point unifying at the editor layer was more machinery than needed.

We think Bet 0 and Bet 2 are the real risks, and both are answerable in the first two milestones — because v1 deliberately ships **two agents with two genuinely different reverse channels** (Claude: we host a WebSocket the CLI calls into; Codex: we proxy its app-server over stdio behind its native `--remote` TUI) and checks fidelity on both. That contrast is stronger than the original plan intended — the shared `diff`/`approvals`/`events` services had to absorb not just a second transport but a second *channel shape* (host-a-server vs proxy-a-stream). They did. If the model didn't generalize across vendors, we'd have found out in week 3, not month 3. (v1 originally said "Codex over local-HTTP/SSE" — that wire was wrong; see `CODEX.md`.)
