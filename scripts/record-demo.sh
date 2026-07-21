#!/usr/bin/env bash
# Record one demo GIF with vhs, then trim to the action + a light uniform speedup.
# Run inside the dev shell (nvim + the agent CLIs on PATH):
#   nix develop -c bash scripts/record-demo.sh <agent> <scenario> <out> [trust]
#     agent    = antigravity | claude | codex
#     scenario = accept | review | changelog
#     out      = output basename (assets/<out>.gif)
#     trust    = pass "trust" to send an Enter early (codex's first-run prompt)
#
# Timing is driven by demo-gif-init responding to the diff-open event, so this
# only needs a generous outer Sleep; the action end is detected from the frames
# and the tail is trimmed. No mid-video frame cutting.
set -euo pipefail

AGENT="${1:?agent}"; SCENARIO="${2:?scenario}"; OUT="${3:?out}"; TRUST="${4:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK=/tmp/harnt-demo
mkdir -p "$WORK" "$ROOT/assets"
TAPE="$WORK/$OUT.tape"

{
  echo "Output \"$WORK/$OUT.mp4\""
  echo 'Require nvim'
  echo 'Set Shell "bash"'
  echo 'Set FontSize 16'
  echo 'Set Width 1200'
  echo 'Set Height 720'
  echo 'Set Padding 16'
  echo 'Set Theme "Catppuccin Mocha"'
  echo 'Hide'
  echo "Type \"cd $ROOT\" Enter"
  echo "Type \"export HARNT_DEMO_AGENT=$AGENT HARNT_DEMO_SCENARIO=$SCENARIO\" Enter"
  echo 'Type "clear" Enter'
  echo 'Show'
  echo 'Type "nvim -u scripts/demo-gif-init.lua" Enter'
  if [ "$TRUST" = "trust" ]; then
    echo 'Sleep 7s'
    echo 'Enter' # accept codex's first-run "trust this directory?" prompt
  fi
  echo 'Sleep 28s'
} > "$TAPE"

echo "== recording $AGENT/$SCENARIO -> assets/$OUT.gif =="
nix run nixpkgs#vhs -- "$TAPE"

# Detect where the action ends (last visual change), trim there, speed 1.67x.
rm -rf "$WORK/s"; mkdir "$WORK/s"
nix run nixpkgs#ffmpeg -- -i "$WORK/$OUT.mp4" -vf "fps=1,scale=240:-1" "$WORK/s/%03d.png" 2>/dev/null
prev=""; last=0
for f in "$WORK"/s/*.png; do
  h=$(md5 -q "$f"); n=$(basename "$f" .png | sed 's/^0*//'); [ -z "$n" ] && n=0
  [ "$h" != "$prev" ] && last=$n; prev="$h"
done
END=$((last + 1))
echo "action ends ~${last}s; trimming to ${END}s, 1.67x"

nix run nixpkgs#ffmpeg -- -y -ss 0 -t "$END" -i "$WORK/$OUT.mp4" \
  -filter:v "setpts=0.6*PTS,fps=13" -an "$WORK/$OUT.trim.mp4" 2>/dev/null
nix run nixpkgs#ffmpeg -- -y -i "$WORK/$OUT.trim.mp4" \
  -vf "scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=128[p];[b][p]paletteuse=dither=bayer:bayer_scale=3" \
  "$ROOT/assets/$OUT.gif" 2>/dev/null

ls -la "$ROOT/assets/$OUT.gif"
