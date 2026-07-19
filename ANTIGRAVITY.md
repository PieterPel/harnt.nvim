# ANTIGRAVITY.md — Antigravity (`agy`) integration: reverse-engineering & plan

**Status: reverse-engineered, viable, NOT yet built.** This is the hardest
provider by far — a proprietary multi-process Connect/gRPC system with a hard
dependency on the Antigravity IDE being installed. But it *is* feasible, and the
path is mapped below. Left as a documented milestone of its own rather than
rushed. `agy` = Antigravity CLI (Google's Gemini-CLI successor, Windsurf/Codeium
"exa" lineage).

## The dead assumption (owning the miss)

PLAN.md originally listed Antigravity as *"IDE Companion spec (MCP/HTTP), reuses
base"* — copied from the Gemini-CLI companion lineage **without reading the
binary**. That was wrong, the same unverified-assumption mistake as Codex's
"/ide". Antigravity's editor integration is **not** a simple MCP-over-HTTP
companion; it's the Windsurf/Codeium `exa` language-server protocol.

## Architecture (reverse-engineered from the running IDE, 2026-07-19)

```
Antigravity IDE (Electron, VS Code fork)
  ├─ hosts ExtensionServerService  (editor actions: diffs, edits, lint, terminal)
  └─ spawns  language_server_macos_arm  --extension_server_port <P> \
                                        --extension_server_csrf_token <tok> \
                                        --app_data_dir antigravity-ide --subclient_type ide
        │  the LS is the "brain" (Cascade/AI); it calls BACK into the IDE's
        │  ExtensionServerService for every editor action (OpenDiffZones, …)
        └─ listens on many 127.0.0.1 ports for clients (the IDE UI; and `agy`)

agy  (companion mode)  ── connects to the LS ──▶  language_server
   • integrated terminal sets ANTIGRAVITY_CLI_ALIAS=agy-ide (marks companion mode)
   • standalone `agy -p` does NOT use the LS at all — it talks to its own cloud
     backend and edits files directly (verified: wrote to ~/.gemini/…/scratch/).
```

**Protocol:** `exa` services over **Connect** (connectrpc) — and critically the
LS accepts **`application/json`** (Connect-JSON), not only binary protobuf. So the
editor side is implementable in **pure Lua over HTTP+JSON** (no protobuf library,
which Neovim lacks). Services seen in the binary:
- `exa.extension_server_pb.ExtensionServerService` — **54 methods**, editor-hosted.
  The ones harnt cares about: `OpenDiffZones`, `WriteCascadeEdit`, `SaveDocument`,
  `AcknowledgeCascadeCodeEdit`, `GetLintErrors`, `GetDefinition`,
  `FindAllReferences`, `OpenFilePointer`, `InsertCodeAtCursor`, `Heartbeat`,
  `LanguageServerStarted`, `SubscribeToUnifiedStateSyncTopic`,
  `PushUnifiedStateSyncUpdate`, `ExecuteCommand`, `OpenTerminal`, …
- `exa.language_server_pb.LanguageServerService` — the brain (huge; we reuse the
  real binary, don't reimplement).
- `exa.api_server_pb.ApiServerService`, `exa.cascade_plugins_pb`, etc. — cloud.

## The viable harnt path (Codex-app-server analog: reuse the engine, host the editor)

harnt plays the **editor**: reuse the vendor's real brain binary, implement only
the editor-side service.

1. **Discover** the IDE's `language_server_macos_arm` binary (present in the app
   bundle: `…/Antigravity IDE.app/Contents/Resources/app/extensions/antigravity/
   bin/language_server_macos_arm`, 109 MB). Provider `detect()` = binary present.
2. **Host** `ExtensionServerService` over **Connect-JSON** on a local port
   (`transport/http.lua` + JSON handlers per method) — wired to harnt's `context`
   / `diff` / `apply` services. Implement the subset the LS calls; stub the rest
   with sensible acks.
3. **Spawn** the real `language_server_macos_arm` with
   `--extension_server_port <harnt-port> --extension_server_csrf_token <tok>
   --app_data_dir antigravity-ide`. The LS now calls harnt for editor actions.
4. **Launch** `agy` in a terminal split with `ANTIGRAVITY_CLI_ALIAS=agy-ide` +
   the discovery env pointing at the spawned LS (harnt controls agy's env, so it
   can set `ANTIGRAVITY_LS_ADDRESS`/token directly — the IDE uses a different
   discovery, but a spawned agy can be told the address). agy's native TUI runs;
   diffs/edits/lint route through harnt → nvim.

Everything stays on-thesis: agy's native TUI is the chat; harnt is the editor the
brain calls into. Connect-JSON keeps it pure Lua.

## Open questions (resolve before/while building)

- **agy → LS discovery:** the integrated terminal had `ANTIGRAVITY_CLI_ALIAS`
  but **no** `ANTIGRAVITY_LS_ADDRESS`; standalone `agy -p` ignored a set
  `ANTIGRAVITY_LS_ADDRESS`. So how companion-mode agy finds the LS is unconfirmed
  (env in interactive mode? a discovery file? a fixed manager port?). Capture a
  real IDE companion session (proxy the LS port) to confirm, then replicate.
- **ExtensionServer startup handshake:** which methods the LS *requires* on
  connect (Heartbeat/LanguageServerStarted/UnifiedStateSync subscribe?) vs. which
  are lazy. Capture LS→ExtensionServer traffic (proxy `--extension_server_port`)
  to get the minimal viable set + exact JSON payloads.
- **Streaming:** `SubscribeToUnifiedStateSyncTopic` / `PushUnifiedStateSyncUpdate`
  imply server-streaming (Connect streaming over HTTP). Confirm framing.
- **IDE dependency:** the build requires the Antigravity IDE installed (for the
  LS binary). Acceptable? Or ship only when detected.

## Effort assessment

Biggest provider by a wide margin: a Connect-JSON server implementing a dozen+
editor methods + streaming, plus spawning/managing the real LS, plus confirming
discovery — a milestone, not a table. Feasible (Connect-JSON = pure Lua), but
disproportionate to bolt onto other work. Recommended: dedicated milestone.

## Verification assets

- `scratchpad/agy_capture.py` — logging server used to probe what agy dials.
- Process inspection (running IDE): LS = `language_server_macos_arm
  --extension_server_port … --extension_server_csrf_token …`; supports
  `application/json` + `Connect-Protocol-Version`.
