# CODEX.md — Codex integration: reverse-engineering log & decision

**Status: RESOLVED.** Codex is a **full-fidelity provider**. harnt runs a thin
proxy in front of `codex app-server` and drives the diff/approval loop through
our own `diff`/`approvals` services, while codex's **native TUI** (`codex
--remote`) renders the chat untouched. Diffs and approvals show up **in nvim**,
with zero feature loss. Proven end-to-end against the pinned `codex-0.144.4`.

This document is a log on purpose. It kept two wrong conclusions before the right
one, and the wrong turns are left in (clearly marked) because *how* we were wrong
is the useful part — see "Lessons" at the end.

---

## TL;DR of the final design

```
codex --remote ws://127.0.0.1:<B>   ──ws──▶   harnt (ws SERVER)  ──stdio──▶   codex app-server
   (real native TUI = the chat)                     │  taps the stream
                                                     ├─ item/fileChange            → nvim diff view
                                                     └─ item/fileChange/requestApproval → nvim approval
                                                        (harnt answers app-server; TUI never sees the prompt)
```

- **Transport:** harnt spawns `codex app-server` and speaks its JSON protocol
  over **stdio** (newline-delimited JSON). harnt is the *sole* app-server client,
  so there is no multi-client question to answer.
- **Chat:** the user's `codex` **native TUI** connects to harnt's WebSocket server
  via `codex --remote ws://…` and renders everything itself. We never draw chat.
- **Editor services:** harnt taps the proxied stream, renders file changes in the
  `diff` service and approvals in the `approvals` service, and answers the
  app-server's approval requests. This is codex's equivalent of Claude's
  `openDiff` — obtained by proxying app-server instead of receiving a direct call.
- **On-thesis:** app-server is used only as the *wire*, the same role WebSocket
  plays for Claude. The native TUI is the chat, so the no-feature-loss guarantee
  holds and we are not building the Shape-B chat UI that PLAN §7 forbids.

---

## The verified wire (codex-0.144.4)

Authoritative source: `codex app-server generate-json-schema --out DIR` (the
binary emits its own protocol — 41 schema files, version-matched). Cross-checked
against `codex-rs/tui/src/ide_context/…` and live runs.

**Envelope:** bare JSON-RPC-ish objects, **no `jsonrpc` field**. Requests
`{id, method, params}`; responses `{id, result}` / `{id, error}`; notifications
`{method, params}`. Over stdio: one JSON object per line. Over ws: one per text
frame.

**Drive flow (harnt → app-server):**
1. `initialize` `{clientInfo:{name,version}}` → response carries `codexHome`, etc.
2. `thread/start` `{cwd, sandbox:"workspace-write", approvalPolicy:"untrusted"}`
   → `{thread:{id}}`. (`untrusted` forces an approval before any write.)
3. `turn/start` `{threadId, input:[{type:"text", text:"…"}]}`.

**Tap flow (app-server → harnt):**
- Notification `item/started|updated|completed` with an `item` of
  `type:"fileChange"` carrying `changes: [{ path, kind:{type:add|update|delete},
  diff }]`. `diff` = full content for `add`, unified diff for `update`. Correlate
  by `item.id`.
- Server **request** `item/fileChange/requestApproval` (v2) `{itemId, threadId,
  turnId, startedAtMs, reason?, grantRoot?}` — the diff is *not* inline; look it
  up by `itemId` from the fileChange item above. (v1 `applyPatchApproval` carries
  `fileChanges` inline; we get v2 by default, i.e. without `experimentalApi`.)
- Answer with `{decision: …}`:
  - **v2** `FileChangeApprovalDecision`: `accept` | `acceptForSession` | `decline` | `cancel`.
  - **v1** `ReviewDecision`: `approved` | `approved_for_session` | `denied` | `abort`.
- Command approvals: `item/commandExecution/requestApproval` / `execCommandApproval`.

**Proven live:** accept → file written to disk; decline → *"patch rejected by
user"*. Codex obeys our decision. (Spike: `scratchpad/spike_appserver.py`.)

---

## The `/ide` context channel (implemented — the second reverse channel)

The app-server proxy carries diffs + approvals. It does **not** carry editor
*context* (active file, selection, open tabs) — that's a separate codex channel,
and harnt now hosts it too. The two are orthogonal and run at the same time:

```
codex TUI ──unix socket──▶ harnt (unixsock SERVER at $TMPDIR/codex-ipc/ipc-{uid}.sock)
   asks "ide-context"          answers {activeFile, openTabs} from services/context
```

Verified wire (`codex-rs/tui/src/ide_context/ipc.rs`, codex-0.144.x):

- **Direction:** the editor hosts the unix socket; codex is the client and
  `connect()`s in. (harnt therefore *binds* `$TMPDIR/codex-ipc/ipc-{uid}.sock`.)
- **Framing:** 4-byte **little-endian** `u32` length prefix + JSON payload.
- **Request (codex → editor):** `{type:"request", requestId, sourceClientId:
  "codex-tui", version:0, method:"ide-context", params:{workspaceRoot}}` — sent
  immediately on connect, no discovery handshake gating it.
- **Response (editor → codex):** `{type:"response", requestId, resultType:
  "success", method:"ide-context", handledByClientId:"harnt", result:{ideContext:
  {activeFile:{label,path,fsPath,selection,activeSelectionContent,selections},
  openTabs:[…]}}}`. codex reads `result.ideContext`.
- **Security:** codex refuses a socket dir not owned by the current user or group/
  world-writable, so harnt creates `codex-ipc` at mode 0700.
- **Rendezvous safety:** the socket path is per-user (shared), so harnt probes
  before binding — a *live* owner (a running IDE) is left untouched and context is
  skipped; only a stale file from a crashed session is reclaimed.

This is codex's analogue of Claude's `getCurrentSelection` / `getOpenEditors`
IDE tools. It's pull-based (codex asks each turn; we answer with the live state),
so there's nothing to push. `providers/codex.lua::M.serve_ide_context`, on
`transport/unixsock`.

**Verified end-to-end against real `codex 0.144.4`** (`just e2e-codex-ide`, in the
nix devshell): harnt hosts the socket, the real `codex` TUI runs `/ide`, issues an
`ide-context` request with `sourceClientId:"codex-tui"` + our workspace root, and
on our response prints *"IDE context is on. Future messages will include your
current IDE selection and open tabs."* Cross-checked against codex's own source
test `fetch_ide_context_uses_unregistered_request_route` (the response shape +
`requestId` echo + interleaved discovery/no-handler frames all match).

## The journey (kept deliberately — including the two wrong conclusions)

### ❌ Wrong conclusion #1 — "Codex `/ide` needs VS Code; not reverse-MCP"

First pass mined the binary for the loudest strings and built a story around them:
`VSCODE_IPC_HOOK_CLI`, `app-server`, `codex-code-mode-host`. Concluded `/ide` was
bound to the VS Code/Cursor extension and that Codex's only editor-agnostic
surface was the headless `app-server` (Shape B) — so "drop it or accept Shape B."
Even tested a `VSCODE_IPC_HOOK_CLI` socket spoof (it did nothing).

**Why it was wrong:** `/ide` was never gated on VS Code. It looks for a unix
socket at `$TMPDIR/codex-ipc/ipc-{uid}.sock` and connects in. The "open this
project in VS Code or Cursor" message just meant *no socket was listening*.
`VSCODE_IPC_HOOK_CLI` and `code-mode-host` are unrelated machinery I pattern-
matched onto because I grepped the binary instead of reading the source module
(`codex-rs/tui/src/ide_context/ipc.rs`) that literally names the feature.

### ❌ Wrong conclusion #2 — "Codex `/ide` is real but context-only; codex owns diffs"

Second pass read `ide_context/ipc.rs` properly and found the real `/ide` channel:
a unix socket, length-prefixed JSON, method `ide-context`, editor answers with
`{activeFile, openTabs}`. Correct — but I concluded the `/ide` channel is the
*only* reverse channel and it is context-only (it is: the TUI's `/ide` only
*pulls* editor context and refuses all inbound requests). So: "codex renders its
own diffs; harnt can only mirror context; unified diffs are impossible."

**Why it was wrong (well — incomplete):** `/ide` genuinely is context-only. But it
is not codex's only reverse channel. `app-server` + `codex --remote` is a second
one — a native TUI talking to an app-server over a socket — and *that* stream
carries file changes and answerable approvals. Proxying it gives full-fidelity
diffs **and** the native TUI. I stopped at the first channel that fit "reverse-MCP"
and declared the diff goal impossible; the user pushed ("is there really no way…
we also have that headless app") and pointed at `--remote`, which cracked it.

### ✅ Right conclusion — proxy `app-server`, keep the native TUI

Above. Verified by driving the real app-server through a file-editing turn and
watching accept write the file / decline reject it.

---

## Dead ends checked and rejected (so we don't revisit them)

- **`/ide` unix socket (context-only):** real, but only feeds active-file/selection
  into the prompt. No diffs/approvals. **Now implemented as a second, independent
  channel** — see "The `/ide` context channel" below. It is *not* the diff path
  (the app-server proxy is); the two run side by side, exactly as the real IDE
  integration does.
- **Hooks (`PreToolUse`/`PermissionRequest`):** codex has a Claude-style hook
  system, but it's under-development and `apply_patch` doesn't reliably fire
  `PreToolUse` (openai/codex#16732 — "hooks only fire for Bash"). Not viable for
  diffs.
- **Observer-only (2nd app-server client, read-only):** app-server ws is
  multi-client, so harnt *could* subscribe and mirror diffs read-only — but
  approvals route to the driving connection, so it can't answer them. The stdio
  proxy is strictly better (full control, no multi-client edge cases).
- **`app-server` as Shape B (editor renders chat):** permanent non-goal (PLAN §7).
  We use app-server as transport only; the native TUI renders chat.
- **`VSCODE_IPC_HOOK_CLI` / `code-mode-host`:** unrelated to editor diffs.

---

## Lessons (the reason this log exists)

1. **For an open-source agent, "reverse-engineer" = read the source first, then
   confirm against the pinned binary.** `strings | grep` is a tiebreaker, not a
   map. Both wrong conclusions came from grepping the binary and narrating the
   loudest symbols instead of reading the module that named the feature.
2. **`generate-json-schema` / `generate-ts` exist — ask the binary for its own
   protocol.** That one command replaced all the guessing.
3. **"No native channel for X" is a claim to test empirically, not deduce.** The
   spike (drive app-server, watch a real diff + approval) settled in minutes what
   two rounds of static analysis got wrong.
4. **Don't stop at the first channel that fits the thesis.** `/ide` fit
   "reverse-MCP" and I stopped; the better channel (`app-server` + `--remote`) was
   one doc page away.

## Verification assets

- `scratchpad/spike_appserver.py` — drives `codex app-server` over stdio through a
  file-editing turn; asserts the fileChange diff arrives and accept writes the file.
- `scratchpad/appschema/` — the 41 schema files from `generate-json-schema`.
