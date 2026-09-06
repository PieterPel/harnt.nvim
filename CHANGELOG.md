# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project aims to
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) once it leaves
`0.x`.

## [0.3.0](https://github.com/PieterPel/harnt.nvim/compare/v0.2.0...v0.3.0) (2026-09-06)


### Features

* package harnt.nvim as a flake output (packages.default) ([#10](https://github.com/PieterPel/harnt.nvim/issues/10)) ([b4b4424](https://github.com/PieterPel/harnt.nvim/commit/b4b4424152fdb943b9a640f63163be71fc6a66ef))

## [0.2.0](https://github.com/PieterPel/harnt.nvim/compare/v0.1.1...v0.2.0) (2026-09-05)


### Features

* add just try-edgy harness for testing edgy.nvim docking ([#7](https://github.com/PieterPel/harnt.nvim/issues/7)) ([e9e185e](https://github.com/PieterPel/harnt.nvim/commit/e9e185ecaeee8685f2278d0f041496246f8fd030))

## [0.1.1](https://github.com/PieterPel/harnt.nvim/compare/v0.1.0...v0.1.1) (2026-08-02)


### Bug Fixes

* WebSocket subprotocol echo + diff-buffer syntax highlighting ([#3](https://github.com/PieterPel/harnt.nvim/issues/3)) ([cf695e6](https://github.com/PieterPel/harnt.nvim/commit/cf695e6680093df7692871ae5417a0c288834385))

## [Unreleased]

## [0.1.0] - 2026-07-24

### Added

- Providers, each verified against the real CLI: **Claude Code** (WebSocket IDE
  integration), **Codex** (`app-server` proxy behind `codex --remote`, plus the
  `/ide` unix socket for editor context), **Antigravity** (`agy` lifecycle
  hooks), and **OpenCode** (client of the agent's own HTTP server, `/event` SSE
  tap).
- Shared editor services written once and reused across every provider:
  `context`, `diff` (file-level accept-with-edits / reject), `approvals`
  (allow/deny, once/always), and `apply`.
- A per-session change-log (`:Harnt changes`) of every file an agent touched.
- `@`-mention / interactive send (`:Harnt send` → `on_mention`) across
  providers.
- One unified command + keymap surface (`:Harnt …`, buffer-local diff keys),
  a statusline segment, and `:checkhealth harnt` per provider.
- Provider registry so third parties can add an agent as a config table, plus
  `HarntEvent` capability passthrough for provider-native payloads.
- Pure-Lua transport primitives on `vim.uv` (jsonrpc, ws, mcp, stdio, filetail,
  protobuf, http, httpclient) — no mandatory daemon or Node/Bun runtime.

### Notes

- Codex full-file diffs: single-file approvals reconstruct the whole
  before/after by applying the unified diff against the on-disk file, so the
  popup shows the full file focused on the change — consistent with the other
  providers.

[Unreleased]: https://github.com/PieterPel/harnt.nvim/compare/v0.1.0...trunk
[0.1.0]: https://github.com/PieterPel/harnt.nvim/releases/tag/v0.1.0
