#!/bin/bash
# Builds VPSManager.app in Release from VPSManager.xcodeproj — the same project
# you run from Xcode — and installs it to /Applications. Run this from the
# project root.
#
#   chmod +x build_app.sh
#   ./build_app.sh
#
set -e

APP_NAME="VPSManager"
APP_BUNDLE="$APP_NAME.app"
DERIVED_DATA=".build/xcode"

echo "→ Building Release with Xcode..."
xcodebuild \
    -project "$APP_NAME.xcodeproj" \
    -scheme "$APP_NAME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    build | grep -E "error:|warning: .*$APP_NAME|BUILD (SUCCEEDED|FAILED)" || true

BUILT_APP="$DERIVED_DATA/Build/Products/Release/$APP_BUNDLE"
if [ ! -d "$BUILT_APP" ]; then
    echo "❌ Build failed — run the xcodebuild command above without the grep to see the full log."
    exit 1
fi

rm -rf "$APP_BUNDLE"
cp -R "$BUILT_APP" "$APP_BUNDLE"

echo "→ Installing to /Applications..."
rm -rf "/Applications/$APP_BUNDLE"
cp -R "$APP_BUNDLE" /Applications/

echo "→ Refreshing Launch Services so it shows up immediately..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP_BUNDLE"

echo ""
echo "✅ Done. $APP_NAME.app is now in /Applications."
echo "   First launch: right-click it → Open (Gatekeeper will ask once, since it's not signed with a paid Developer ID)."
echo "   After that, launch it normally, and you can drag it to the Dock."
