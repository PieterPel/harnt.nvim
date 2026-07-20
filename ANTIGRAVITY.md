# ANTIGRAVITY.md — Antigravity (`agy`) integration: reverse-engineering & plan

**Status: BUILT — via lifecycle hooks, NOT the language server.** The provider
(`lua/harnt/providers/antigravity.lua`) reaches the whole point of the project —
interactive diffs + approvals in nvim, plus editor-context injection — through
`agy`'s documented `.agents/hooks.json` system. The elaborate `exa`
language-server / ExtensionServer path below was **real reverse-engineering of the
wrong process**: it drives the desktop IDE's Cascade sidebar, not the terminal
`agy` CLI (a fresh `agy -i` spawns no language_server — verified by process tree).
The RE is kept in full because it's accurate about the IDE and documents *why* it
is off harnt's path. See "What actually ships" immediately below, then the
LS record. `agy` = Antigravity CLI (Google's Gemini-CLI successor, Windsurf/
Codeium "exa" lineage).

## What actually ships — the hook gate

Terminal `agy` supports lifecycle hooks (its own shipped docs:
`~/.gemini/antigravity-cli/builtin/skills/agy-customizations/docs/hooks.md`). harnt
injects one named hook (`harnt`) into `.agents/hooks.json`, non-destructively
merged and restored on stop, bridging agy's events to nvim over a per-session unix
socket (`transport/reqsock`, driven from the hook command via `nc -U`):

| agy event | harnt does | contract |
|---|---|---|
| `PreToolUse` (edit tools) | reconstruct the change from `toolCall.args`, render via the `diff` service, return the verdict | out: `{decision:"allow"｜"deny", reason?}` — **blocking**, so this IS the interactive diff |
| `PreToolUse` (`run_command`) | prompt via the `approvals` service | out: `{decision}` |
| `PreInvocation` | inject live editor context (active file, selection, open files, error count) | out: `{injectSteps:[{ephemeralMessage}]}` — the context-push channel |

Decision strings are agy's (`allow`/`deny`/`ask`/`force_ask`); harnt uses
allow/deny. This mirrors Claude (`openDiff`) and Codex (`item/fileChange/
requestApproval`) through the *same* shared `diff`/`approvals`/`changes` services —
a third channel shape (a blocking child-process hook) absorbed without forking them.

**Verified end-to-end against real `agy 1.1.4`** (`just e2e-agy-hooks`, in the nix
devshell) — driving the **interactive** `agy` TUI over a PTY, i.e. the exact mode
harnt spawns (agy in a terminal split), through the real provider path. Both
directions, decisively:
- **reject the diff** → agy attempts the edit, we reject, and the file is **never
  written** (it retried `write_to_file`/`run_command`; every attempt was blocked).
- **accept the diff** → the provider replies `allow` + `permissionOverrides`
  (`write_file(<path>)`), satisfying agy's own permission so it does **not**
  double-prompt, and the file **is written**.

`PreInvocation` fires before each model call (the context-injection channel). The
real edit tool is **`write_to_file`** with args `{TargetFile, CodeContent,
Description, Overwrite}` — `TargetFile`/`CodeContent` are in `_normalize_edit`'s
field lists, so it recovers the real path and renders a real diff (confirmed live,
not the raw-args fallback).

Notes: `nc -U` is a soft dependency of the bridge. `agy -p` (headless/print) is a
*different* permission model — it hard-auto-denies any write needing a prompt
regardless of hooks — so it is NOT representative and the e2e uses interactive
`agy -i`. Open: the hooks.json read-path across versions (bug #49: some builds
read `~/.gemini/config/hooks.json`, others `.agents/hooks.json` — 1.1.4 reads
`.agents/hooks.json` as used here).

---

## LEGACY REVERSE-ENGINEERING (the exa language server — the wrong process)

Everything below reverse-engineers the **desktop IDE's** integration. It is
accurate but off harnt's path (terminal `agy` doesn't use it). Kept as the record.

Original framing — **reverse-engineered, viable, but the wrong integration
point** — a proprietary multi-process Connect/gRPC system with a hard dependency
on the Antigravity IDE being installed.

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

### ⚠️ Correction: the ExtensionServer channel is binary `connect+proto`, not JSON

Live test (harnt-spawned LS + dummy ExtensionServer) produced:

```
Failed to get OAuth token: … invalid content-type: "application/json";
expecting "application/connect+proto"
```

So two things, both raising the cost:
1. **The LS fetches its OAuth token *from* the ExtensionServer** via UnifiedStateSync
   — harnt-as-editor must *serve* the token to the LS (so booting isn't enough;
   auth flows through the ExtensionServer we host).
2. **The LS↔ExtensionServer client is hardwired to `application/connect+proto`**
   (binary protobuf), *not* JSON — my earlier "Connect-JSON, pure Lua" read was
   wrong (the LS binary *advertises* JSON, but its ExtensionServer client uses
   proto). So harnt must hand-implement **binary protobuf** encode/decode for the
   ExtensionServer messages (UnifiedStateSync + OAuth state, OpenDiffZones,
   WriteCascadeEdit, GetLintErrors, …) — dozens of nested messages, no protobuf
   library in Neovim. This is the real remaining hard layer, larger than hoped.

Net: **booting the LS is solved; hosting the ExtensionServer in binary
connect+proto (incl. serving auth via UnifiedStateSync) is a substantial pure-Lua
protobuf build.** That, not the boot, is the true bulk of the work — a dedicated
milestone with its own protobuf-codec + schema-extraction effort.

### OAuth token: served via the ExtensionServer, not the keychain (probably)

The token lives in **Electron `safeStorage`** (keychain item *"Antigravity Safe
Storage"* = the AES key; a `gemini/antigravity` keychain account) — encrypted, the
standard Chromium pattern. Decrypting a user's OAuth token is sensitive and fiddly.

**But the boot test showed a dummy `api_key` boots the LS fine** (auth is lazy).
The open question that decides everything: when the **already-authed `agy`**
connects to a harnt-spawned LS in companion mode, does *agy* supply the real auth
(so harnt never touches the token), or does the LS need its own token in the
metadata? **Test this before building any token extraction** — boot the LS with a
dummy token on a fixed port, launch `agy` (companion env) pointed at it, run one
edit turn, and see if it works. If agy provides auth, the whole credential problem
disappears.

## ✅ SHIPPED (pure Lua, verified): boot handshake

`lua/harnt/transport/protobuf.lua` (minimal wire codec) + `providers/antigravity.lua`
(`find_ls` / `metadata_frame` / `spawn_ls`) now boot the **real** language_server
from Lua: verified `find_ls` → `metadata_frame` (our codec) → `spawn_ls` (writes
the protobuf frame, closes stdin) → the LS listens on the fixed `--https_server_port`.
So the hardest research step is done *and* implemented in the plugin. Not yet
registered (no `start()` until the ExtensionServer host exists).

## ✅ CAPTURED + validated: the ExtensionServer handshake

Booted the real LS pointed at harnt's own `http.lua` server and decoded its calls
with `protobuf.lua` — the transport stack works end-to-end against the real LS:

- First calls: **`POST /exa.extension_server_pb.ExtensionServerService/SubscribeToUnifiedStateSyncTopic`**
  (server-streaming), `content-type: application/connect+proto`. Topics seen:
  `uss-agentPreferences`, `uss-browserPreferences` (more likely incl. auth/user
  status).
- **Connect framing:** each message is `[1 flag byte][4-byte BE length][protobuf]`
  (the 5-byte gRPC/Connect envelope). Request body decodes (after `+5`) to
  `{ field 1 (string) = "<topic>" }`.
- harnt must answer each subscribe with a **server-streaming** response: push the
  topic's current state as enveloped protobuf frames (this is where the OAuth
  token / user status is served to the LS).

## ✅ RESOLVED: OAuth token source + auth mechanism (the last unknowns)

**Token source (no safeStorage decryption needed):** `agy` stores its token in the
macOS **keychain**, item `service=gemini account=antigravity`, go-keyring-wrapped:
the value is `go-keyring-base64:<base64>` and decodes to
`{ "token": { "access_token": "ya29…", "token_type": "Bearer", "refresh_token": …,
"expiry": … }, "auth_method": "consumer" }`. Read it with
`security find-generic-password -s gemini -a antigravity -w` (macOS;
`secret-tool` / go-keyring equivalents elsewhere). This is the same source `agy`
uses ("authenticated via keyring" in its logs) — clean, no Electron `safeStorage`
AES dance.

**Auth mechanism (verified):** the stdin `Metadata` `api_key` is **ignored** for
auth — feeding the real token there still fails. The LS obtains its OAuth token
**only** via the **`uss-oauth`** UnifiedStateSync topic: it subscribes
(`SubscribeToUnifiedStateSyncTopic{ topic="uss-oauth" }`) and harnt must **stream
back the token state** as an enveloped protobuf frame. A non-streamed 200 yields
*"state sync subscription error for topic uss-oauth: unexpected EOF"*.

## ⚠️ PIVOTAL (2026-07-19): terminal `agy` runs standalone — the LS is the IDE *sidebar's*

End-to-end test (`antigravity.start()` hosts the ExtensionServer + spawns the
authed LS; launch `agy` in companion env pointed at it): **`agy` ignored harnt's
LS.** It authenticated on its own (keyring), edited in its **own default scratch
workspace** (not the session cwd), and behaved exactly like standalone `agy -p`.
`ANTIGRAVITY_LS_ADDRESS` didn't wire it in (the real IDE terminal also lacks that
env), and `--persistent_mode` wrote no discovery file `agy` consumed.

**What's confirmed vs open.** Confirmed: with that env setup, terminal `agy` ran
standalone. **Open (honestly):** my connect attempt may have been *misconfigured*
— I pointed `agy` at `http://` on the LS's `--https_server_port` (likely TLS) via
env discovery, and `agy` falls back to standalone when it can't reach an LS. So
this does **not** yet prove terminal `agy` *can't* be a companion — only that this
attempt didn't wire it in. Two live paths:

- **(a) Debug the agy↔LS connection** — right port (there's also `--http_server_port`;
  the LS opens many ports) + protocol (http vs https) + discovery (how `agy` finds
  the LS when `ANTIGRAVITY_CLI_ALIAS=agy-ide`; not the env we tried). Auth is
  already cracked, so if terminal `agy` *can* be a companion, this unlocks the full
  integration.
- **(b) Shape A + hooks** — if terminal `agy` is fundamentally standalone (like
  terminal Codex), mirror the **Claude hook** path: native `agy` TUI in a split +
  a `PostToolUse` hook → change-log. `agy` has Claude-compatible hooks
  (`PreToolUse`/`PostToolUse`; `agy plugin import from gemini|claude`). Quick, sure.

The LS-hosting work below stands as a real reverse-engineering result regardless.

## ✅✅ AUTH CRACKED (serve-verify loop, 6 cycles) — the LS authenticates under harnt

Serving the `uss-oauth` UnifiedStateSync subscription with the following makes the
real LS authenticate (verified: zero errors, no "Failed to get OAuth token"):

`SubscribeResponse{ initial_state{ rows... } }` streamed as one Connect frame,
where `initial_state` (field 1) contains repeated rows (field 1), each row =
`{ #1 key:string, #2 value:{ #1 payload:string } }`. For `uss-oauth`, two rows:

1. **`authStateWithContextSentinelKey`** → value payload = **plain JSON**
   `{ "state": "signedIn", "context": { project, showProjectError, errorMessage, … } }`
   (states: `signedIn`/`signedOut`/`uninitialized`/`loginError`).
2. **`oauthTokenInfoSentinelKey`** → value payload = **base64( protobuf `OAuthTokenInfo` )**
   where `OAuthTokenInfo { access_token=1 (string), token_type=2 (string),
   refresh_token=3 (string), expiry=4 (Timestamp msg, omittable), is_gcp_tos=6 (bool) }`.
   The token comes from the **keychain** (`gemini/antigravity`, go-keyring base64
   → JSON `{token:{access_token,token_type,refresh_token,expiry}}`).

The error progression that nailed it: `unexpected EOF` (framing) → `key not found`
(need `oauthTokenInfoSentinelKey`, not `authStateWithContext`) → `illegal base64`
(value is base64) → `proto: cannot unmarshal` (inner is protobuf, not JSON) →
**clean** (base64(protobuf OAuthTokenInfo)). Different keys use different value
encodings (auth-status = JSON; token = base64+protobuf).

Remaining: build this into the provider's ExtensionServer, then editor-action
methods (`OpenDiffZones`/`WriteCascadeEdit`) → nvim diff, then launch `agy` +
verify a real turn.

### Serve-verify loop progress (against the real LS)

Built a Lua ExtensionServer (our `http`+`connect`+`protobuf`) and iterated:

- **Response shape (from the IDE extension JS):** `subscribeToUnifiedStateSyncTopic`
  is server-streaming and yields `SubscribeResponse{ oneof update_type:
  initial_state=1 (msg) | applied_update=2 (msg) }`. Send one `initial_state`
  frame per subscribe.
- **Cycle 1 (empty `initial_state`):** the `uss-oauth` *"unexpected EOF"* error
  **disappeared** — so our Connect framing + streaming + the `{initial_state=1}`
  response structure are **correct** (verified against the real LS).
- **Cycle 2:** error refined to *"state syncing error: **key not found**"* — so the
  `uss-oauth` state is a **key-value store** and the LS looks up a specific key for
  the token, which our empty state lacks.

**Remaining is now an iterative KV-schema reconstruction** (not cleanly extractable
statically — the descriptor windows are ambiguous and the JS shows the *client*
`subscribe`, not the server value construction): determine the `initial_state`
KV/row message shape, the oauth **key name**, and the token **value format** (JSON
vs nested proto), by serve-verify cycles until auth succeeds. Then the same for
`OpenDiffZones`/`WriteCascadeEdit`, then `agy` launch. Each cycle is a real
guess→serve→read-LS-error step — bounded but multi-cycle.

Remaining, concretely (bounded — all infra exists):
1. Extract the **UnifiedStateSync response** + **`uss-oauth` state** message schemas
   from the LS descriptors (same technique as `Metadata`); the oauth payload
   mirrors the keychain JSON (access_token / token_type / refresh_token / expiry).
2. Build the **ExtensionServer** in the provider (`http.lua` + `connect.lua` +
   `protobuf.lua`): route `SubscribeToUnifiedStateSyncTopic`, and for `uss-oauth`
   stream the token (read from the keychain) as protobuf. Ack/stub other topics.
3. Editor-action methods `OpenDiffZones` / `WriteCascadeEdit` → `diff` service.
4. Launch `agy` pointed at the LS + `start()` + register + verify a real turn.

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
