#!/bin/bash
# Signs one binary or app bundle the same way everywhere.
#
#   scripts/sign.sh <path> [entitlements.plist]
#
#   SIGN_IDENTITY="Developer ID Application: …"  release signing: hardened runtime + secure
#                                                timestamp + entitlements (needed to notarize)
#   (unset)                                      ad-hoc, as for install.sh and local builds
#   HARDENED=1 (with ad-hoc)                     ad-hoc but with the hardened runtime and
#                                                entitlements, to test a release-like build locally
set -euo pipefail
TARGET="${1:?usage: sign.sh <path> [entitlements.plist]}"
ENTITLEMENTS="${2:-}"
IDENTITY="${SIGN_IDENTITY:--}"

args=(--force --sign "$IDENTITY")
if [ "$IDENTITY" != "-" ]; then
  args+=(--options runtime --timestamp)
elif [ "${HARDENED:-0}" = 1 ]; then
  args+=(--options runtime)
fi
if [ -n "$ENTITLEMENTS" ] && { [ "$IDENTITY" != "-" ] || [ "${HARDENED:-0}" = 1 ]; }; then
  args+=(--entitlements "$ENTITLEMENTS")
fi
# Quiet unless it fails ("replacing existing signature" is noise; real errors aren't).
if ! out="$(codesign "${args[@]}" "$TARGET" 2>&1)"; then
  echo "$out" >&2
  exit 1
fi
