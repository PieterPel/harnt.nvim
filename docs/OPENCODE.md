# OPENCODE.md — OpenCode integration: reverse-engineering log & decision

**Status: BUILT (wire verified against real `opencode-1.17.9`; full turn-driving
smoke is env-gated).** OpenCode is a **full-fidelity provider** on a *fourth*
channel shape. Where Claude has the editor host a WebSocket the CLI dials into,
and Codex has us proxy an app-server, **OpenCode's own TUI is a client of an HTTP
server the agent hosts** (`opencode serve`). So harnt joins as a *second client*
of that server: it taps the `/event` SSE stream for diffs + approvals and answers
approvals over HTTP, while the native TUI (`opencode attach`) renders the chat,
untouched. On-thesis: `opencode serve` is the *wire*, not a chat UI we paint.

This document is authoritative for OpenCode; it supersedes any OpenCode specifics
elsewhere.

---

## TL;DR of the final design

```
opencode serve  (HTTP + SSE on 127.0.0.1:<P> — the transport harnt spawns)
   ├── opencode attach http://127.0.0.1:<P>   ← the real native TUI = the chat, DRIVES turns
   └── harnt  (HTTP client)                    ← observer/answerer
         ├─ GET /event  (SSE)  ── permission.v2.asked
         │                     │     ├ edit/write/patch → services/diff (interactive review)
         │                     │     └ everything else  → services/approvals (4-way popup)
         │                     ── session.next.tool.called → cache input (for the diff above)
         │                     ── session.diff             → services/changes (dedup'd)
         │                     ── session.next.tool.*       → canonical tool events
         ├─ POST /api/session/{sid}/permission/{id}/reply  {reply, message?}   (answer)
         └─ POST /tui/append-prompt {text}                 (`:Harnt send` → @mention)
```

- **Transport:** harnt spawns `opencode serve --hostname 127.0.0.1 --port <P>` and
  is a pure HTTP client of it (`transport/httpclient`, pure Lua on `vim.uv` — no
  curl, no runtime). It subscribes to the `text/event-stream` at `GET /event`.
- **Chat + driving:** the user's `opencode attach http://127.0.0.1:<P>` **native
  TUI** connects to the same server and renders everything itself. Crucially, the
  **TUI is what drives turns** — see "The load-bearing discovery" below. We never
  draw chat.
- **Editor services (full parity with the other providers):** harnt taps the SSE
  stream and gives OpenCode every editor-side capability —
  - **approvals** — `permission.v2.asked` → answered over HTTP. An edit/write/patch
    permission is shown as an **interactive diff review** (accept / reject /
    comment), the actual change reconstructed by correlating the permission's
    `source.callID` with the cached `tool.called` input; other permissions use the
    four-way approval popup.
  - **change-log** — `session.diff` file changes recorded for `:Harnt changes`.
  - **editor context** — `:Harnt send` pushes the current file/selection as a
    native `@path#Lstart-end` mention via `POST /tui/append-prompt`.
- **On-thesis:** the HTTP server is used only as the *wire*, the same role
  WebSocket plays for Claude and app-server plays for Codex. OpenCode *also* ships
  a headless `opencode acp` surface — the exact §7 non-goal — and we deliberately
  do **not** use it. Same binary, both surfaces; we pick the native-TUI one.

---

## The verified wire (`opencode-1.17.9`)

Authoritative source: the server's own OpenAPI document at `GET /doc` (OpenAPI
3.1, title `opencode`), cross-checked against live runs.

**Server framing.** `GET /api/health` → `{"healthy":true}` with `Content-Length`.
`GET /event` → `Content-Type: text/event-stream`, `Transfer-Encoding: chunked`,
`x-accel-buffering: no`; events are standard SSE `data: {json}\n\n`. The first
event is always `{"type":"server.connected"}`; `server.heartbeat` keepalives
arrive periodically. Auth is optional (`OPENCODE_SERVER_PASSWORD`/basic-auth);
loopback + unset by default.

**Events we act on** (from the `Event` discriminated union — ~90 variants; we tap
only the editor-shaped few):

| SSE `type` | payload (`properties`) | harnt routing |
|---|---|---|
| `permission.v2.asked` | `{id ^per, sessionID ^ses, action, resources[], save[], metadata, source:{callID,messageID}}` | edit/write/patch → `diff` review; else `approvals` popup; answered over HTTP |
| `permission.v2.replied` | `{id}` | clear the "open permission" (may have been answered in the TUI) |
| `session.next.tool.called` | `{tool, input, callID, …}` | `tool.started` **+ cache `input` by `callID`** so the permission above can render the real diff |
| `session.diff` | `{sessionID, diff: SnapshotFileDiff[]}` where `SnapshotFileDiff = {file, patch, additions, deletions, status:added\|deleted\|modified}` | record each changed file once (dedup) into `changes` |
| `file.edited` | `{file}` (path only, no content) | (informational; the diff comes from `session.diff`) |
| `session.next.tool.success` / `.failed` | `{tool, …}` | `tool.completed {ok}` |
| `session.error` | — | `session.failed` |

**Answering a permission:** `POST /api/session/{sessionID}/permission/{id}/reply`
with `{reply, message?}` where `reply ∈ {once, always, reject}`. harnt maps its
four-way approval decision → this enum: `allow_once→once`, `allow_always→always`,
`deny_once`/`deny_always→reject` (deny-always is remembered on *our* side by the
approvals service, keyed on the action). The optional free-text `message` is why
OpenCode's **review is lossless** — a rejection carries the reviewer's inline
comments, richer than agents whose decline is verdict-only.

**Inline diff at approval time.** A `permission.v2.asked` for a mutating tool
(`edit`/`write`/`apply_patch`) references the tool call via `source.callID`. The
`session.next.tool.called` event for that `callID` carries the tool `input`
(`edit`: `{filePath, oldString, newString}`; `write`: `{filePath, content}`;
`apply_patch`: a patch string — OpenCode's public tool contracts). harnt caches
those inputs and, on the permission, renders the proposed change into the shared
`diff` service as an interactive review: **accept → reply `once`**, **reject →
reply `reject`** with any inline comments as the `message`. This is the OpenCode
analogue of Codex correlating fileChange items by `itemId`. (The on-disk file is
still the *old* version at permission time — the new content is only in the tool
input, which is why we render from there, not from `session.diff`.)

**Pushing editor context.** `POST /tui/append-prompt {text}` appends to the
attached TUI's prompt input. `:Harnt send` (`on_mention`) uses it to drop a native
`@path` / `@path#Lstart-end` mention of the current buffer/selection into the
prompt — the same channel OpenCode's own editor integration uses — left for the
user to send, not auto-submitted. (`/tui/submit-prompt`, `/tui/clear-prompt`, and
`/tui/publish` exist too; we only need append.)

All of this protocol knowledge lives in `providers/opencode.lua`; the generic
layers stay agent-agnostic (per repo convention).

---

## The load-bearing discovery — the server is transport, the TUI drives

Trying to drive an edit through the **headless** server API (create session → POST
`/prompt`) revealed the key fact: **`opencode serve` admits prompts but does not
autonomously execute turns.** The prompt is accepted (`session.next.prompt.admitted`
fires, `admittedSeq` increments) but no assistant message, tool call, or diff ever
appears — while the same model driven by `opencode run` edits the file
immediately. Turns are pumped by a **connected driving client** (the TUI /
`opencode run`'s in-process driver), not by the bare server.

This is *exactly* the role split harnt wants, and it validates the architecture
rather than threatening it:

- **The native TUI (`opencode attach`) is the driver and the chat.** It pumps
  turns and renders everything. We never touch it.
- **harnt is a pure observer/answerer.** It taps `/event` and answers editor
  concerns (approvals) over HTTP. It never drives a turn, never renders chat.

It also means a real `permission.v2.asked` can only be produced with a driving
client attached — so the fully-live permission→diff→reply loop is **interactive /
env-gated** (open the TUI via `just try` + `:Harnt open opencode`), not a headless
unit test. What *is* pinned: the wire shapes (permission request, reply enum,
`session.diff`, `tool.called` input) from the server's own OpenAPI + live SSE, the
edit/write/patch input contracts from OpenCode's public tool definitions, and the
routing logic (`tool.called` → cache → permission → diff/reply) as unit tests over
`M._router` in `tests/providers/opencode_spec.lua`.

---

## Diffs vs. approvals — two distinct surfaces

OpenCode applies its own edits, and whether it *asks first* depends on config
(`permission: { edit: "ask" }`; `opencode run` auto-applied with no prompt). harnt
covers both cases with two different surfaces:

- **When it asks** — `permission.v2.asked`. For a mutating tool
  (`edit`/`write`/`apply_patch`) harnt shows the **actual proposed change as an
  interactive diff** (accept → allow once / reject → decline + comments), the diff
  reconstructed from the correlated `tool.called` input (see "Inline diff at
  approval time"). For a command (`bash`, …) it's the four-way approval popup.
- **When it doesn't ask** (auto-applied edits) — `session.diff`, a *cumulative*
  post-hoc snapshot of every file touched this session, re-emitted as it grows.
  harnt dedups it per-file (by patch) and records each real edit into the
  **changes** log (`:Harnt changes`) — a look-back, exactly the role Codex's
  `record_change` plays for auto-applied edits. We deliberately do **not** pop a
  review window per snapshot (it would flood, and the edit is already applied).

---

## Double-surface note (approvals appear in both nvim and the TUI)

Because harnt is a *peer client* (not an interception proxy like Codex), a
`permission.v2.asked` is visible to **both** the attached TUI and harnt. OpenCode
permissions are **server-side broadcast state**: whichever client replies first
resolves it for everyone (a late second reply just 404s, which we ignore
idempotently), and a `permission.v2.replied` event tells the other client it's
done. So harnt answering in nvim resolves the TUI's prompt too. The residual wart
— a permission may momentarily show in both places — is documented here as the
known v1 UX cost of the peer-client shape; it is not a correctness bug. (Contrast
Codex, where proxying lets us hide the prompt from the TUI entirely.)

---

## Dead ends checked and rejected (so we don't revisit them)

- **`opencode acp` (ACP server):** OpenCode ships one. It is the headless,
  editor-drives-and-renders surface — the **permanent non-goal** (PLAN §7). Use an
  ACP client (agentic.nvim / CodeCompanion) for that. harnt uses the native TUI +
  HTTP server instead. That OpenCode offers *both* in one binary is a clean, live
  illustration of harnt's whole bet (see BET.md).
- **Driving turns from harnt via the headless API:** possible in principle, but it
  would make harnt the *driver* and push us toward rendering chat — off-thesis.
  The TUI drives; we observe.
- **Auto-opening a review diff on `session.diff`:** rejected — cumulative snapshots
  would flood; the edit is already applied. Recorded to the change-log instead.

---

## Lessons

1. **Ask the server for its own protocol.** `GET /doc` (OpenAPI 3.1) replaced all
   guessing about event shapes, permission enums, and endpoints — the OpenCode
   analogue of Codex's `generate-json-schema`.
2. **"Can't reproduce X headless" can be a finding, not a failure.** The turn not
   running without a driver *is* the architecture (TUI drives, harnt observes) —
   confirmed by contrasting `opencode run` (drives) with bare `serve` (queues).
3. **A fourth channel shape fit the same shared services.** `diff`/`approvals`/
   `events` absorbed an *agent-hosts-HTTP-server, editor-is-client* channel with no
   fork — the strongest evidence yet for Bet 3.

---

## Verification assets

- `scripts/e2e-opencode.lua` — env-gated real-CLI smoke: spawns the real `opencode
  serve`, and over harnt's own HTTP client asserts health, the `/event` SSE tap
  (parses `server.connected`), a session create, and the `/tui/append-prompt`
  context push all round-trip. (The live permission→diff→reply loop needs the TUI
  attached — the interactive part.) Nondeterministic; NOT part of `just ci`.
- Wire captures were taken against `opencode serve` on loopback: `GET /doc`,
  live `/event` SSE, and `opencode run` producing a real unified-diff edit.
