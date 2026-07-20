# PROVIDERS.md — the harnt provider contract

This is the reference for **adding an agent to harnt**. Third parties extend
harnt the way `nvim-dap` / `conform.nvim` do: register a table, no core PR.

harnt deliberately has **no universal wire protocol** — that is the whole bet
(see `BET.md`). Each agent is met in its *own* native protocol (reverse-MCP over
WebSocket/HTTP). What harnt standardizes is the **editor side**: a small Lua
contract every provider implements, plus shared services the provider composes.
So "our protocol" is this contract, not a wire format.

---

## 1. Registering a provider

```lua
require("harnt").register_provider(provider)   -- or require("harnt.providers").register(provider)
```

A `provider` is a plain table. Most providers are a thin specialization of the
reverse-MCP base (§4); you rarely implement `start` from scratch.

---

## 2. The `Provider` table

| field | required | type | purpose |
|---|---|---|---|
| `name` | ✓ | `string` | unique registry key |
| `detect` | ✓ | `fun(): boolean` | CLI present + authenticated |
| `start` | ✓ | `fun(ctx): Session` | begin a session (usually `reverse_mcp.start`) |
| `cmd` | | `string[]` | command to spawn the agent's TUI (Shape A) |
| `env` | | `fun(info): table<string,string>` | env for the spawned TUI (discovery) |
| `review` | | `fun(ctx: ReviewContext)` | deliver diff-review feedback natively |
| `on_selection` | | `fun(session)` | push a live selection update as the cursor moves |
| `on_mention` | | `fun(session)` | @-mention the current file/selection to the agent |

The optional capabilities are how harnt avoids lowest-common-denominator flatten-
ing: the generic layer calls them and the *provider* decides the native shape.
If a provider omits `review`, the review key is a plain reject; omit
`on_selection`/`on_mention` and no context is pushed.

---

## 3. The `Session` interface

`start` returns a session:

| method | purpose |
|---|---|
| `on(self, event, handler): fun()` | subscribe to a canonical event; returns unsubscribe |
| `respond(self, id, result)` | answer a server-initiated request (e.g. an approval) |
| `interrupt(self)` | interrupt the current turn |
| `stop(self)` | end the session (close server, remove discovery, emit `session.completed`) |
| `push?(self, method, params)` | *(optional)* send an unsolicited notification to the agent |

### Canonical events (`require("harnt.events").TYPES`)

`session.started/completed/failed`, `message.delta/completed`,
`tool.started/completed`, `approval.requested/resolved`, `diff.ready/closed`.
Every emitted event is also mirrored onto a `User HarntEvent` autocmd
(`{ event, payload }` in `args.data`) for dependency-free frontends. Native
detail rides under `payload.provider` and is never flattened.

### `ReviewContext` (passed to `review`)

`{ comments = {{line, text}}, path?, reject = fun(), send_text = fun(text), session }`
— the generic layer supplies the primitives; the provider composes them (type
prose into a TUI, send a structured protocol message, whatever fits).

---

## 4. The reverse-MCP base (what most providers use)

```lua
local reverse_mcp = require("harnt.providers.reverse_mcp")

function M.start(ctx)
  return reverse_mcp.start({
    name = "myagent",
    host = "127.0.0.1",        -- optional (default)
    port = 0,                  -- optional (0 = OS-assigned)
    auth_header = "x-...",     -- optional; header the CLI must send with the token
    discovery = { write = fn(info), remove = fn(info) },
    tools = function(ctx) return { ...mcp.Tool... } end,
    server_info = { name = "harnt.nvim", version = "0.1.0" },
  }, ctx)
end
```

The base hosts the WebSocket server, generates a 128-bit auth token, writes the
discovery entry, validates the auth header, and serves MCP per connection. It
returns a session that also carries `info = { host, port, auth_token, pid }` —
the frontend uses `info` to spawn the CLI with the right discovery env.

### Discovery

`discovery.write(info)` / `discovery.remove(info)` place and remove whatever file
the CLI scans to find the server (e.g. Claude's `~/.claude/ide/<port>.lock`).

### Editor tools (`require("harnt.transport.mcp").Tool`)

```lua
{
  name = "openDiff",
  description = "…",
  inputSchema = { type = "object", properties = { … } },  -- JSON Schema
  handler = function(args, respond)
    -- do editor work, then answer (async-friendly: hold `respond` and call later)
    respond(require("harnt.transport.mcp").content("FILE_SAVED"))
  end,
}
```

`respond(result)` sends the MCP result; `mcp.content(value, is_error?)` wraps a
value in the `{ content = {{type="text", …}} }` envelope.

### Shared services a tool handler composes (agent-agnostic)

- `require("harnt.services.context")` — selection, buffers, cursor, diagnostics, roots, `file_range`.
- `require("harnt.services.diff")` — `open(spec, cb)`, `accept`/`reject`, comments, `current`.
- `require("harnt.services.apply")` — write to disk + reload buffers.
- `require("harnt.services.approvals")` — allow/deny × once/always.

These are the "crown jewels": written once, reused by every provider. A provider
adapter should be mostly *config* (discovery, env, tool names/schemas) plus thin
handlers that delegate to these services.

---

## 5. Worked example

`lua/harnt/providers/claude.lua` is the reference implementation: reverse-MCP over
WebSocket, `~/.claude/ide/<port>.lock` discovery, `x-claude-code-ide-authorization`
auth, `CLAUDE_CODE_SSE_PORT`/`ENABLE_IDE_INTEGRATION` env, the openDiff/getDiagnostics/
getCurrentSelection/… tool set, and `review`/`on_selection`/`on_mention` mapping
Claude's `selection_changed`/`at_mentioned` shapes onto the shared services.

Not every agent fits the reverse-MCP base — some channels aren't "the CLI dials
into a server we host." Those implement `start` directly but compose the *same*
shared services, so the provider still boils down to a small protocol map:
- `codex.lua` — proxies `codex app-server` (stdio) and taps the stream.
- `opencode.lua` — is a *client* of the agent's own HTTP server (`opencode
  serve`): it taps the `/event` SSE stream (`transport/httpclient`). An
  edit/write/patch `permission.v2.asked` → interactive `diff` review (change
  correlated via `source.callID` + the cached tool input); a command permission →
  `approvals`; `session.diff` → `changes`; and `on_mention` pushes an `@`-mention
  via `POST /tui/append-prompt`. The native TUI (`opencode attach`) drives and
  renders. All OpenCode protocol knowledge (event names, the
  `once`/`always`/`reject` reply enum, tool-input shapes, endpoint paths) lives in
  that one file. See `OPENCODE.md`.

---

## 6. Checklist for a new provider

- [ ] `detect()` returns true only when the CLI is usable.
- [ ] `start()` returns a session (use `reverse_mcp.start` unless truly bespoke).
- [ ] discovery `write`/`remove` match what the CLI scans for.
- [ ] `auth_header` set if the CLI authenticates the handshake.
- [ ] tools delegate to the shared services; names/schemas match the CLI.
- [ ] `cmd`/`env` so the manager can spawn the TUI with discovery env.
- [ ] optional `review`/`on_selection`/`on_mention` in the agent's native shape.
- [ ] a no-feature-loss check: the agent's native features still work through harnt.
