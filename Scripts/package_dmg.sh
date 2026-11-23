#!/bin/bash
set -euo pipefail

# NetBoost Application Packaging & DMG Builder
# Creates standalone NetBoost.app bundle and NetBoost-1.0.0.dmg

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

APP_NAME="NetBoost"
VERSION="1.0.0"
BUILD_DIR="$REPO_DIR/.build/arm64-apple-macosx/debug"
STAGING_DIR="$REPO_DIR/.build/staging"
APP_BUNDLE="$STAGING_DIR/$APP_NAME.app"
DMG_STAGING="$REPO_DIR/.build/dmg_staging"
OUTPUT_DMG="$REPO_DIR/$APP_NAME-$VERSION.dmg"

echo "==> Step 1: Building binary with Swift 6.2..."
"$REPO_DIR/Scripts/build.sh"

echo "==> Step 2: Creating macOS Application Bundle ($APP_NAME.app)..."
rm -rf "$STAGING_DIR" "$DMG_STAGING" "$OUTPUT_DMG"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy binary
cp "$BUILD_DIR/$APP_NAME"App "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Generate Info.plist
cat <<EOF > "$APP_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>com.netboost.app</string>
    <key>CFBundleName</key>
    <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>
    <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
</dict>
</plist>
EOF

echo "==> Step 3: Preparing DMG staging directory..."
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

echo "==> Step 4: Generating compressed UDZO DMG installer..."
hdiutil create -volname "$APP_NAME $VERSION" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$OUTPUT_DMG"

echo "==> NetBoost DMG successfully created at:"
ls -lh "$OUTPUT_DMG"
