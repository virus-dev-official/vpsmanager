#!/bin/bash
# Builds a universal Release VPSManager.app and packs it into dist/VPSManager.dmg
# (the app plus an Applications shortcut to drag it onto). Run from the repo root.
#
# The app is ad-hoc signed, so on first launch macOS asks once: right-click the
# app → Open. Set SIGN_IDENTITY to a "Developer ID Application" identity to sign
# it properly instead.
set -euo pipefail

APP_NAME="VPSManager"
DERIVED_DATA=".build/xcode"
DIST="dist"
STAGING="$DIST/dmg"

echo "→ Building Release..."
xcodebuild \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    ONLY_ACTIVE_ARCH=NO \
    build | grep -E "error:|BUILD (SUCCEEDED|FAILED)" || true

BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
[ -d "$BUILT_APP" ] || { echo "❌ Build failed"; exit 1; }

rm -rf "$DIST"
mkdir -p "$STAGING"
cp -R "$BUILT_APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    echo "→ Signing with $SIGN_IDENTITY..."
    codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$STAGING/$APP_NAME.app"
fi

echo "→ Creating disk image..."
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DIST/$APP_NAME.dmg" >/dev/null
rm -rf "$STAGING"

echo "✅ $DIST/$APP_NAME.dmg"
