#!/bin/bash
# Records every README GIF in one go. Each scenario's instructions are spoken aloud
# (so you can watch the Touch Bar, not the terminal), then it records while you follow them.
#
#   scripts/record-readme-gifs.sh                 # all scenarios
#   scripts/record-readme-gifs.sh question reader # only these
#
# Output: docs/gifs/<scenario>.gif. Before starting, close the full bar so only the pill shows,
# and quit or idle any real Claude Code sessions so they don't show up in the recordings.
set -euo pipefail
cd "$(dirname "$0")/.."

ALL=(flow question always reader voice-deny)
# What to say for voice-deny. Short, everyday words are recognized best. Override with
# PHRASE="keep the old files" scripts/record-readme-gifs.sh voice-deny
PHRASE="${PHRASE:-run the tests first}"

if [ "$#" -gt 0 ]; then SCENARIOS=("$@"); else SCENARIOS=("${ALL[@]}"); fi

speak() { echo "→ $1"; say -r 200 "$1"; }

for name in "${SCENARIOS[@]}"; do
    case "$name" in
        flow)       kind=flow;       secs=30; tip="Tap the chef hat when it turns blue. When the approval appears, hold Allow. When it turns green, swipe through the reply." ;;
        question)   kind=question;   secs=22; tip="Pick p n p m. Then tick Lint and Unit tests, and tap Done." ;;
        always)     kind=always;     secs=16; tip="Long-press the text to show the rule. Then hold Always." ;;
        reader)     kind=response;   secs=24; tip="Tap the green chef hat. Then tap Play, and let it read." ;;
        voice-deny) kind=permission; secs=22; tip="Hold the mic Deny button and say: $PHRASE. Release, then tap Deny." ;;
        *) echo "Unknown scenario: $name (choose from: ${ALL[*]})"; exit 1 ;;
    esac
    speak "Next: $name. $tip"
    sleep 1
    say -r 220 "Recording." &
    scripts/record-touchbar.sh "$kind" "$secs" "docs/gifs/$name.gif" | grep -E "^Wrote|Need|isn't|No " || true
    speak "Done. Close the bar with the eye button."
    sleep 4
done
speak "All recorded."
ls -la docs/gifs/
