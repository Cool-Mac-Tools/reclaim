#!/bin/bash
# Package Reclaim into a signed, notarizable .app bundle (and .dmg).
#
# Usage:
#   scripts/package.sh                      # release .app, ad-hoc/dev signed
#   SIGN_ID="Developer ID Application: …" scripts/package.sh --dmg
#   … --notarize   (requires NOTARY_PROFILE stored via notarytool store-credentials)
#
# Env:
#   BUNDLE_ID   default com.reclaimac.app
#   VERSION     default 1.0.0
#   BUILD       default 1
#   SIGN_ID     codesign identity; default first "Developer ID Application" in keychain,
#               else falls back to ad-hoc "-" (local testing only).
#   TEAM_ID     Apple Team ID (for notarization).
#   NOTARY_PROFILE  name of a stored notarytool credential profile.
set -euo pipefail
cd "$(dirname "$0")/.."

BUNDLE_ID="${BUNDLE_ID:-com.reclaimac.app}"
VERSION="${VERSION:-1.0.0}"
BUILD="${BUILD:-1}"
APP_NAME="Reclaim"
PRODUCT="ReclaimApp"          # SPM executable target name
DIST="dist"
APP="$DIST/$APP_NAME.app"

want_dmg=false; want_notarize=false
for arg in "$@"; do
  case "$arg" in
    --dmg) want_dmg=true ;;
    --notarize) want_notarize=true ;;
  esac
done

# Pick a signing identity.
if [ -z "${SIGN_ID:-}" ]; then
  SIGN_ID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)"/\1/') || true
fi
if [ -z "${SIGN_ID:-}" ]; then
  echo "⚠️  No Developer ID identity found — ad-hoc signing (runs on THIS Mac only)."
  SIGN_ID="-"
fi
echo "▸ Signing identity: $SIGN_ID"

echo "▸ Building release (arm64)…"
swift build -c release --product "$PRODUCT"

BIN=".build/release/$PRODUCT"

echo "▸ Assembling $APP …"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPhotoLibraryUsageDescription</key><string>Reclaim reads your Photos library locally to show individual photos and videos with their real sizes, so you can clear the biggest ones. Your photos never leave this Mac.</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Reclaim. All rights reserved.</string>
</dict>
</plist>
PLIST

echo "▸ Signing (hardened runtime)…"
if [ "$SIGN_ID" = "-" ]; then
  codesign --force --deep --sign - "$APP"
else
  codesign --force --options runtime --timestamp \
    --entitlements Resources/Reclaim.entitlements --sign "$SIGN_ID" "$APP"
  echo "▸ Verifying signature…"; codesign --verify --deep --strict --verbose=2 "$APP"
fi
echo "✓ Built $APP"

if $want_dmg; then
  DMG="$DIST/$APP_NAME-$VERSION.dmg"
  echo "▸ Building $DMG …"
  rm -f "$DMG"
  STAGE="$DIST/dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp -R "$APP" "$STAGE/"
  ln -s /Applications "$STAGE/Applications"
  hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  rm -rf "$STAGE"
  [ "$SIGN_ID" != "-" ] && codesign --force --sign "$SIGN_ID" "$DMG"
  echo "✓ Built $DMG"

  if $want_notarize; then
    : "${NOTARY_PROFILE:?set NOTARY_PROFILE (see: xcrun notarytool store-credentials)}"
    echo "▸ Submitting to Apple for notarization (this can take a few minutes)…"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "▸ Stapling…"
    xcrun stapler staple "$DMG"
    xcrun stapler staple "$APP"
    echo "✓ Notarized & stapled $DMG"
  fi
fi

echo "Done. Distribute: ${DMG:-$APP}"
