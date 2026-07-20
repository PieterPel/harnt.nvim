# DEMO.md — recording the README demo

The single highest-leverage marketing asset for an nvim plugin is a short GIF of
it working. This is the storyboard + how to capture it.

## The stage

```sh
just demo
```

Launches a clean Neovim (only harnt loaded) in a fresh temp git project seeded
with a small buggy `fizzbuzz.lua`, with `<leader>` demo keymaps and an on-launch
help popup. Nothing touches your real config. You need at least one agent CLI
installed + authenticated (`claude`, `codex`, or `agy`).

## Storyboard (~30–40s)

Keep it tight — one loop per agent, same keys throughout.

1. **Open on the seeded file.** The help popup shows the keys; let it sit ~1s.
2. **Launch an agent** — `<leader>ac` (Claude). Its real TUI opens in a split.
3. **Ask it to work** — type in the agent's TUI:
   *"Fix the off-by-one in fizzbuzz.lua and add a short doc comment."*
4. **The diff appears in Neovim** (not a chat box) — the winbar shows
   `F9 accept · F10 reject · <leader>c comment · <leader>R review`.
5. **Accept with `F9`.** The file updates; the agent continues in its own TUI.
6. **The payoff line:** switch agents — `<leader>ax` (Codex) — and show the
   *same keys* drive its diff. This is the whole pitch: one editor surface, every
   agent, native TUIs intact.
7. *(Optional)* `<leader>aC` to show the change-log, or reject + `<leader>c` a
   comment to show review feedback flowing back.

On-screen caption to add in post: **"Two agents. One diff flow. No feature lost."**

## Capturing it

Any of these; pick what you have.

- **vhs** (deterministic, great for READMEs): scripted keystrokes → GIF.
  Because the agents make live API calls, a fully-scripted tape is flaky — record
  the terminal live with vhs's `Screenshot`/manual mode, or use asciinema.
- **asciinema + agg**: `asciinema rec demo.cast` → drive it → `agg demo.cast
  demo.gif`. Crisp, small, text-selectable source.
- **Screen recorder** (QuickTime / OBS / peek) → trim → convert to GIF. Simplest.

Target: ≤ 6 MB GIF or a short mp4, ~800px wide, 12–15 fps.

## Wiring it into the README

Drop the file in `assets/` and replace the placeholder near the top of
`README.md`:

```markdown
![harnt.nvim: two agents, one diff flow](./assets/demo.gif)
```

Record one clean take per agent you want to feature; the Claude→Codex switch is
the money shot.
