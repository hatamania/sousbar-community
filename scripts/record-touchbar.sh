#!/bin/bash
# Records the Touch Bar to a GIF (for the README), while a fake Claude Code session plays.
#
#   scripts/record-touchbar.sh [demo-kind] [seconds] [out.gif]
#
# demo-kind is any `sousbar-hook demo` kind (default: flow, which shows working → approval → reply).
# Recording runs for `seconds` (default 30), or until you press Ctrl-C.
# Needs SousBar running. Uses `screencapture -b` (Touch Bar only) and macOS's own GIF encoder.
set -euo pipefail

KIND="${1:-flow}"
SECONDS_TOTAL="${2:-30}"
OUT="${3:-docs/touchbar-$KIND.gif}"
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HOME/.sousbar/bin/sousbar-hook"
FRAMES="$(mktemp -d)"
trap 'rm -rf "$FRAMES"' EXIT

[ -x "$HOOK" ] || { echo "No $HOOK. Open SousBar and connect it first."; exit 1; }
"$HOOK" ping >/dev/null 2>&1 || { echo "SousBar isn't running. Open it first."; exit 1; }

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

echo "Recording the Touch Bar for ${SECONDS_TOTAL}s (Ctrl-C stops early)."
echo "Demo '$KIND' starts in 2 s: answer it on the Touch Bar, then tap the pill and swipe the reply."

start=$(now_ms)
stop=$((start + SECONDS_TOTAL * 1000))
( sleep 2; "$HOOK" demo "$KIND" >/dev/null 2>&1 ) &
DEMO=$!

stopped=0
trap 'stopped=1' INT
while [ "$stopped" = 0 ]; do
    t=$(now_ms)
    [ "$t" -ge "$stop" ] && break
    screencapture -x -b "$FRAMES/$((t - start)).png" 2>/dev/null || true
done
trap 'rm -rf "$FRAMES"' EXIT
kill "$DEMO" 2>/dev/null || true

mkdir -p "$(dirname "$OUT")"
echo "Encoding $(ls "$FRAMES" | wc -l | tr -d ' ') frames…"
swift "$HERE/frames-to-gif.swift" "$FRAMES" "$OUT"
