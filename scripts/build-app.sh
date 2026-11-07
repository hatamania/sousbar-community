#!/bin/bash
# Assembles SousBar.app from built binaries: Info.plist (with version), generated chef-hat icon,
# the hook binary inside (Contents/MacOS/sousbar-hook, so a drag-installed app can connect
# itself), ad-hoc signatures. Used by install.sh (from source) and scripts/package.sh (releases).
#
#   scripts/build-app.sh <bin-dir> <output.app> [version] [build-number]
set -euo pipefail
BIN="${1:?usage: build-app.sh <bin-dir> <output.app> [version] [build-number]}"
APP="${2:?usage: build-app.sh <bin-dir> <output.app> [version] [build-number]}"
VERSION="${3:-}"
BUILD="${4:-}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/SousBar" "$APP/Contents/MacOS/SousBar"
cp "$BIN/sousbar-hook" "$APP/Contents/MacOS/sousbar-hook"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -n "$VERSION" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
fi
if [ -n "$BUILD" ]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$APP/Contents/Info.plist"
fi

ICONSET="$(mktemp -d)/AppIcon.iconset"
if "$BIN/SousBar" --write-iconset "$ICONSET" && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"; then
  :
else
  echo "  (couldn't build the app icon; continuing without it)"
fi
rm -rf "$(dirname "$ICONSET")"
# Inside first, then the app (signing the app seals what's inside it). See scripts/sign.sh for
# how SIGN_IDENTITY / HARDENED choose release vs local signing.
"$ROOT/scripts/sign.sh" "$APP/Contents/MacOS/sousbar-hook"
"$ROOT/scripts/sign.sh" "$APP" "$ROOT/Resources/SousBar.entitlements"
