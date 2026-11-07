#!/bin/bash
# Builds SousBar, installs it to ~/Applications, and adds the Claude Code hooks.
# Also upgrades an install from before the rename (AgentStrip).
set -euo pipefail
cd "$(dirname "$0")"

# Two ways to run this:
#   • from a release zip: SousBar.app and sousbar-hook sit next to this script (no Swift needed)
#   • from the source tree: builds them first (needs Xcode or the Command Line Tools)
PREBUILT=0
if [ -d "./SousBar.app" ] && [ -f "./sousbar-hook" ]; then
  PREBUILT=1
  echo "▸ Installing the prebuilt release"
else
  if ! command -v swift >/dev/null 2>&1; then
    echo "Swift not found. Install Xcode or run: xcode-select --install"
    exit 1
  fi
  echo "▸ Building (release)…"
  swift build -c release
  BIN="$(swift build -c release --show-bin-path)"
fi

# Upgrading from AgentStrip (the old name): stop and remove the old app. Its hook entries in
# settings.json are replaced below. ~/.agentstrip is left in place on purpose: Claude Code
# sessions that are still running loaded the old hook command, and it keeps exiting quietly
# until they restart. Delete it after that.
UPGRADED=0
OLD_APP="$HOME/Applications/AgentStrip.app"
if [ -d "$OLD_APP" ]; then
  echo "▸ Replacing the old AgentStrip.app with SousBar"
  pkill -x AgentStrip 2>/dev/null || true
  rm -rf "$OLD_APP"
  UPGRADED=1
fi

APP="$HOME/Applications/SousBar.app"
echo "▸ Installing $APP"
pkill -x SousBar 2>/dev/null || true
mkdir -p "$HOME/Applications"
if [ "$PREBUILT" = 1 ]; then
  rm -rf "$APP"
  ditto "./SousBar.app" "$APP"
else
  scripts/build-app.sh "$BIN" "$APP"
fi
# Downloaded files carry a quarantine flag; the app is ad-hoc signed, so macOS would block it.
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

echo "▸ Installing hook binary"
mkdir -p "$HOME/.sousbar/bin"
chmod 700 "$HOME/.sousbar"
if [ "$PREBUILT" = 1 ]; then
  cp "./sousbar-hook" "$HOME/.sousbar/bin/sousbar-hook"
else
  cp "$BIN/sousbar-hook" "$HOME/.sousbar/bin/sousbar-hook"
fi
chmod 755 "$HOME/.sousbar/bin/sousbar-hook"
xattr -d com.apple.quarantine "$HOME/.sousbar/bin/sousbar-hook" 2>/dev/null || true
codesign --force --sign - "$HOME/.sousbar/bin/sousbar-hook" >/dev/null 2>&1 || true

echo "▸ Adding hooks to ~/.claude/settings.json"
"$HOME/.sousbar/bin/sousbar-hook" install

echo "▸ Launching"
open "$APP"
sleep 1

cat <<'EOF'

Done. Next:
  1. Make sure your Touch Bar shows the Control Strip
     (System Settings › Keyboard › Touch Bar Settings › Show Control Strip: on).
     Look for the chef-hat pill at the right side of the Touch Bar.
  2. Try it without Claude:   ~/.sousbar/bin/sousbar-hook demo
  3. Restart any running Claude Code sessions so they load the hooks.
EOF

if [ "$UPGRADED" = 1 ]; then
  cat <<EOF

Upgraded from AgentStrip. Your settings were carried over.
  • Restart running Claude Code sessions: until then they use the old hook and won't show up.
  • Then remove the old files:   rm -rf "$HOME/.agentstrip"
  • If you used "Launch at login", turn it on again from the menu bar chef hat.
EOF
fi
