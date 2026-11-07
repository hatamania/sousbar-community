#!/bin/bash
# Builds a universal (Apple silicon + Intel) release and packs it for GitHub Releases:
#   dist/SousBar-<version>.dmg         SousBar.app + an Applications shortcut: drag, open, Connect
#   dist/SousBar-<version>.zip         SousBar.app, sousbar-hook, install.sh, uninstall.sh, README.md
#                                      (unzip and run ./install.sh: scripted install, no Swift needed)
#   dist/*.sha256                      checksums
#
# Signing (see scripts/sign.sh): ad-hoc by default. Set SIGN_IDENTITY to a "Developer ID
# Application: …" identity in the keychain to sign for release, and also NOTARY_KEY (path to an
# App Store Connect API key .p8), NOTARY_KEY_ID and NOTARY_ISSUER to notarize and staple, so the
# DMG opens on any Mac without a Gatekeeper warning. The Release workflow sets these from secrets.
#
#   scripts/package.sh <version> [build-number]
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARIZE=0
if [ -n "${SIGN_IDENTITY:-}" ] && [ "$SIGN_IDENTITY" != "-" ] \
   && [ -n "${NOTARY_KEY:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER:-}" ]; then
  NOTARIZE=1
fi

# Submits a file to Apple's notary service and waits. On rejection, prints Apple's log and stops.
notarize() {
  local file="$1" out status id
  echo "  submitting $(basename "$file") to Apple (usually a few minutes)…"
  out="$(xcrun notarytool submit "$file" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" \
           --issuer "$NOTARY_ISSUER" --wait --output-format json)" || true
  status="$(plutil -extract status raw -o - - <<<"$out" 2>/dev/null || echo "unknown")"
  id="$(plutil -extract id raw -o - - <<<"$out" 2>/dev/null || echo "")"
  if [ "$status" != "Accepted" ]; then
    echo "Notarization failed for $(basename "$file"): $status"
    echo "$out"
    [ -n "$id" ] && xcrun notarytool log "$id" --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" || true
    exit 1
  fi
  echo "  accepted ($id)"
}
VERSION="${1:?usage: scripts/package.sh <version> [build-number]}"
BUILD="${2:-1}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
  echo "Version must look like 1.2.3 or 1.2.3-beta.1 (got: $VERSION)"
  exit 1
fi

ARCHS=(--arch arm64 --arch x86_64)
echo "▸ Building universal release (arm64 + x86_64)…"
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

NAME="SousBar-$VERSION"
STAGE="dist/$NAME"
rm -rf "$STAGE" "dist/$NAME".zip* "dist/$NAME".dmg* "dist/dmg-$NAME"
mkdir -p "$STAGE"

echo "▸ Assembling $NAME"
scripts/build-app.sh "$BIN" "$STAGE/SousBar.app" "$VERSION" "$BUILD"
cp "$BIN/sousbar-hook" "$STAGE/sousbar-hook"
scripts/sign.sh "$STAGE/sousbar-hook"
cp install.sh uninstall.sh README.md "$STAGE/"

echo "▸ Checking"
for f in "$STAGE/SousBar.app/Contents/MacOS/SousBar" "$STAGE/SousBar.app/Contents/MacOS/sousbar-hook" "$STAGE/sousbar-hook"; do
  archs="$(lipo -archs "$f")"
  [[ "$archs" == *arm64* && "$archs" == *x86_64* ]] || { echo "Not universal: $f ($archs)"; exit 1; }
done
codesign --verify --deep --strict "$STAGE/SousBar.app"

make_zip() { rm -f "dist/$NAME.zip"; (cd dist && ditto -c -k --keepParent "$NAME" "$NAME.zip"); }

echo "▸ Zipping"
make_zip
if [ "$NOTARIZE" = 1 ]; then
  echo "▸ Notarizing the app and hook"
  notarize "dist/$NAME.zip"
  xcrun stapler staple "$STAGE/SousBar.app" # so it opens even offline
  spctl --assess --type execute -vv "$STAGE/SousBar.app" 2>&1 | grep -q "Notarized Developer ID" \
    || { echo "Gatekeeper doesn't accept the stapled app"; spctl --assess --type execute -vv "$STAGE/SousBar.app"; exit 1; }
  make_zip # again, now with the stapled app inside
fi
(cd dist && shasum -a 256 "$NAME.zip" > "$NAME.zip.sha256")

echo "▸ Making the disk image"
# The usual layout: the app next to a shortcut to /Applications. HFS+ so macOS 12 can open it.
DMGROOT="dist/dmg-$NAME"
mkdir -p "$DMGROOT"
ditto "$STAGE/SousBar.app" "$DMGROOT/SousBar.app"
ln -s /Applications "$DMGROOT/Applications"
hdiutil create -volname "SousBar $VERSION" -srcfolder "$DMGROOT" -fs HFS+ -format UDZO -ov \
  "dist/$NAME.dmg" >/dev/null
rm -rf "$DMGROOT"
hdiutil verify "dist/$NAME.dmg" >/dev/null
if [ "$NOTARIZE" = 1 ]; then
  echo "▸ Notarizing the disk image"
  codesign --force --sign "$SIGN_IDENTITY" --timestamp "dist/$NAME.dmg"
  notarize "dist/$NAME.dmg"
  xcrun stapler staple "dist/$NAME.dmg"
  xcrun stapler validate "dist/$NAME.dmg"
fi
(cd dist && shasum -a 256 "$NAME.dmg" > "$NAME.dmg.sha256")

if [ "$NOTARIZE" = 1 ]; then
  echo "Signed with: $SIGN_IDENTITY (notarized and stapled)"
else
  echo "Signed ad-hoc (not notarized): macOS will warn when a downloaded copy is first opened."
fi
echo "Done:"
cat "dist/$NAME.dmg.sha256" "dist/$NAME.zip.sha256"
