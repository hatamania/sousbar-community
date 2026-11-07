#!/bin/bash
# Removes the hooks from ~/.claude/settings.json (including any left from AgentStrip, the old
# name) and stops the app.
set -uo pipefail

if [ -x "$HOME/.sousbar/bin/sousbar-hook" ]; then
  "$HOME/.sousbar/bin/sousbar-hook" uninstall
fi
pkill -x SousBar 2>/dev/null || true

cat <<EOF

Hooks removed and SousBar stopped. To delete the files too:
  rm -rf "$HOME/Applications/SousBar.app" "$HOME/.sousbar"
EOF
