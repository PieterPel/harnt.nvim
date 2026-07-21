# DEMO.md — recording the README demos

The single highest-leverage marketing asset for an nvim plugin is a short GIF of
it working. harnt records one **per agent**, fully automated, against the *real*
CLI — no hand-driving, no post-hoc frame cutting.

## Record one

```sh
just record-demo codex            # → assets/codex.gif
just record-demo antigravity      # → assets/antigravity.gif
just record-demo claude           # → assets/claude.gif
just record-demo codex review     # comment + reject instead of accept
```

Each needs the agent CLI installed + authenticated (run inside `nix develop` so
`codex` / `agy` / `claude` are on `$PATH`). The GIFs are wired into `README.md`.

## How it works (no corner-cutting)

Two pieces, both agent-agnostic:

- **`scripts/demo-gif-init.lua`** — a clean Neovim (only harnt loaded) in a fresh
  temp git project seeded with a genuinely buggy `fizzbuzz.lua`. The chosen agent
  (`HARNT_DEMO_AGENT`) launches with the fix as an *initial prompt*, so no typing
  into the agent's TUI is scripted. Crucially, harnt **responds to the diff
  opening**: it wraps `diff.open`/`diff.open_review` so that a readable beat after
  the diff actually appears, it acts the way the review keys do — accept, or (for
  `HARNT_DEMO_SCENARIO=review`) comment + reject. Timing is driven by the real
  open event, not a guessed `sleep`, so every take is tight regardless of model
  latency.
- **`scripts/record-demo.sh`** — writes a vhs tape that launches that init,
  records to mp4, detects the end of on-screen activity by frame-hashing at 1 fps
  (so the trailing idle is dropped, not the content), then trims to the action and
  applies a light uniform speedup → `assets/<agent>.gif`.

## The scenarios

- `accept` (default) — the agent proposes an edit; harnt's diff opens in Neovim
  (never a chat box), dwells so it's readable, then accepts. The winbar shows the
  real keys: `<leader>a accept · <leader>r reject · <leader>c comment ·
  <leader>R review`.
- `review` — instead of accepting, harnt attaches an inline comment and submits a
  review (reject + the comment flows back to the agent as feedback).
- `changelog` — accept, then open the read-only change-log view.

## The pitch the set makes

Three agents, three different reverse channels (Claude WebSocket, Codex
app-server proxy, Antigravity lifecycle hooks) — and the **same diff flow, same
approval popup, same keymaps** in every GIF, each agent's own TUI untouched in a
split. One editor surface, every agent, no feature lost.

Target: each GIF stays a few hundred KB to a couple MB, ~1200px wide.
