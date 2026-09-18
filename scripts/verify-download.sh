#!/usr/bin/env bash
# Verify the exact signed installer served by the website, independently of a build.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?Usage: scripts/verify-download.sh VERSION}"
DMG="$PWD/docs/downloads/Reclaim-$VERSION.dmg"
(cd docs/downloads && shasum -a 256 -c "Reclaim-$VERSION-SHA256SUMS.txt")
codesign --verify --strict --verbose=2 "$DMG"
xcrun stapler validate "$DMG"
hdiutil verify "$DMG"
MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/reclaim-release.XXXXXX")"
cleanup() {
  hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  rmdir "$MOUNT_DIR" 2>/dev/null || true
}
trap cleanup EXIT
hdiutil attach -readonly -nobrowse -mountpoint "$MOUNT_DIR" "$DMG"
APP="$MOUNT_DIR/Reclaim.app"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")" = "$VERSION"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist")" = 'com.reclaimac.app'
test "$(codesign -dv --verbose=4 "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')" = 'L76TDSSV4Z'
codesign --verify --deep --strict --verbose=2 "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"
echo "Verified Reclaim $VERSION: checksum, signed disk image, packaged app version and Apple notarization."
