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

## Deep dive: the LS boot handshake (2026-07-19, from the IDE extension JS)

Read from `…/extensions/antigravity/dist/extension.js` (readable, unlike agy).
The IDE spawns the LS like:

```
language_server_macos_arm --enable_lsp \
  --csrf_token <random>                      # token CLIENTS present to the LS
  --extension_server_port <P>                # the LS DIALS this (editor actions)
  --extension_server_csrf_token <tok>        # token the LS presents to us
  [--https_server_port <hp> --lsp_port <lp>] # settable; also via env
                                             #   JETSKI_FIXED_SERVER_PORT / JETSKI_FIXED_LSP_PORT
  --app_data_dir antigravity-ide --subclient_type ide \
  --cloud_code_endpoint https://cloudcode-pa.googleapis.com
# env: { ...process.env, ...languageServerEnv, ANTIGRAVITY_EDITOR_APP_ROOT }
```

**Then it writes a binary protobuf `Metadata` message to the LS's stdin and
closes it** (`child.stdin.write(le); child.stdin.end()`). Without it the LS dies
with *"Failed to read initial metadata from stdin"* (verified). Fields:

```
Metadata{ ideName, ideVersion, extensionName, extensionPath, locale,
          deviceFingerprint = <installation id>,
          apiKey            = OAuthPreferences.getOAuthTokenInfo().accessToken,
          disableTelemetry, userTierId }
```

So the stdin bootstrap is **binary protobuf** (not JSON) and **carries the cloud
OAuth token**. The LS's *HTTP* API is Connect-JSON, but this one bootstrap frame
is protobuf.

## ✅ BREAKTHROUGH (2026-07-19): the LS boots under harnt

The hard research step is **solved and verified**. harnt can spawn + boot the real
`language_server` itself:

- **`Metadata` field numbers** (decoded from the LS binary's embedded
  `FieldDescriptorProto`s): `ide_name=1, api_key=3 (OAuth token), locale=4,
  disable_telemetry=6 (bool), ide_version=7, extension_name=12, extension_path=17,
  device_fingerprint=24 (installation id), user_tier_id=29`. A flat string/bool
  message → trivial to hand-encode in Lua.
- **stdin framing = raw protobuf, EOF-delimited** (write the serialized message,
  then close stdin). No length prefix.
- **Verified:** hand-encoding that message (dummy `api_key`) + writing it to the
  LS's stdin gets it **past** *"Failed to read initial metadata from stdin"* and it
  boots. The dummy token is fine to boot — auth is lazy (only cloud/AI calls need
  a real token).
- **Ports are fixable:** `--https_server_port <P> --lsp_port <Q>` (or env
  `JETSKI_FIXED_SERVER_PORT`/`JETSKI_FIXED_LSP_PORT`) → the LS listens exactly
  there. So **agy discovery is trivial** — harnt fixes the port and points agy at
  it. Verified: with `--https_server_port 8899` the LS listens on 8899.

So there are **no deep protocol unknowns left** — the rest is engineering.

## Remaining build tasks (in order) — now unblocked engineering

1. **Metadata proto field numbers.** Only in the minified protobuf-es descriptor
   / the LS binary's embedded FileDescriptorProtos. Decode one of those (base64
   `fileDesc(...)` in extension.js, or protodump the Go binary) to get the
   `Metadata` message's field numbers + types. Needed to encode the stdin frame.
2. **stdin framing.** Confirm how `le` is delimited (length-prefix format) before
   the protobuf bytes.
3. **OAuth token extraction.** Read `getOAuthTokenInfo().accessToken` from the
   `~/.gemini` unified-state store (find the exact file/format). Needed for the
   Metadata frame. (Security: handle the user's token carefully.)
4. **Spawn + boot** the LS with args + env + the hand-encoded stdin metadata;
   confirm it starts and dials our `--extension_server_port`.
5. **Connect-JSON `ExtensionServerService`** (streaming) wired to context/diff/
   apply — the subset the LS calls.
6. **agy launch + LS discovery** — point companion `agy` at our LS.

Each of 1–3 is its own RE step (protobuf descriptor decoding, token store format).
Feasible, but genuinely a dedicated build — and it hard-depends on the Antigravity
IDE being installed (for the LS binary) plus a live OAuth session.

## Verification assets

- `scratchpad/agy_capture.py` — logging server used to probe what agy dials.
- Process inspection (running IDE): LS = `language_server_macos_arm
  --extension_server_port … --extension_server_csrf_token …`; supports
  `application/json` + `Connect-Protocol-Version`.
