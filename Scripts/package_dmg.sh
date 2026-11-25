#!/bin/bash
set -euo pipefail

# NetBoost Application Packaging & DMG Builder
# Creates standalone NetBoost.app bundle and NetBoost-<version>.dmg

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_DIR"

APP_NAME="NetBoost"
VERSION="1.0.0"

usage() {
    echo "Usage: $0 [--version <version>]" >&2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version)
            if [ "$#" -lt 2 ] || [ -z "${2:-}" ]; then
                echo "Error: --version requires a value" >&2
                usage
                exit 2
            fi
            VERSION="$2"
            shift 2
            ;;
        --version=*)
            VERSION="${1#--version=}"
            if [ -z "$VERSION" ]; then
                echo "Error: --version requires a non-empty value" >&2
                usage
                exit 2
            fi
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown argument '$1'" >&2
            usage
            exit 2
            ;;
    esac
done

case "$VERSION" in
    */*|*..*)
        echo "Error: Invalid version string '$VERSION'" >&2
        exit 2
        ;;
esac

BUNDLE_VERSION="${VERSION%%-*}"
if [ -z "$BUNDLE_VERSION" ]; then
    BUNDLE_VERSION="1.0.0"
fi

STAGING_DIR="$REPO_DIR/.build/staging"
ICONSET_DIR="$REPO_DIR/.build/AppIcon.iconset"
APP_BUNDLE="$STAGING_DIR/$APP_NAME.app"
DMG_STAGING="$REPO_DIR/.build/dmg_staging"
OUTPUT_DMG="$REPO_DIR/$APP_NAME-$VERSION.dmg"

generate_app_icon() {
    local dest_icns="$1"
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"

    if [ -f "$REPO_DIR/Assets/AppIcon.png" ]; then
        echo "    Generating AppIcon.icns from Assets/AppIcon.png..."
        local src_icon="$REPO_DIR/Assets/AppIcon.png"
        local entries=(
            "icon_16x16.png:16"
            "icon_16x16@2x.png:32"
            "icon_32x32.png:32"
            "icon_32x32@2x.png:64"
            "icon_128x128.png:128"
            "icon_128x128@2x.png:256"
            "icon_256x256.png:256"
            "icon_256x256@2x.png:512"
            "icon_512x512.png:512"
            "icon_512x512@2x.png:1024"
        )
        local entry fname dim
        for entry in "${entries[@]}"; do
            fname="${entry%%:*}"
            dim="${entry##*:}"
            /usr/bin/sips -s format png -z "$dim" "$dim" "$src_icon" --out "$ICONSET_DIR/$fname" >/dev/null
        done
        iconutil -c icns "$ICONSET_DIR" -o "$dest_icns"
        rm -rf "$ICONSET_DIR"
        return 0
    fi

    echo "    Generating AppIcon.icns using Swift CoreGraphics (2048px supersampled N-bridge mark)..."
    local master_2x="$ICONSET_DIR/master_2048.png"
    local final_1024="$ICONSET_DIR/icon_512x512@2x.png"
    local swift_src="$ICONSET_DIR/icon_gen.swift"
    local dev_dir
    dev_dir="$(xcode-select -p 2>/dev/null || true)"

    cat <<'SWIFTEOF' > "$swift_src"
import AppKit
import CoreGraphics
import Foundation

let outputPath = CommandLine.arguments[1]
let size = 2048

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size,
    pixelsHigh: size,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else {
    fputs("Failed to allocate icon bitmap context\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = nsCtx
let ctx = nsCtx.cgContext
ctx.setShouldAntialias(true)
ctx.setAllowsAntialiasing(true)
let f = CGFloat(size)

// macOS HIG squircle icon padding (~9.8% inset)
let pad = f * 0.098
let side = f - 2 * pad
let iconRect = CGRect(x: pad, y: pad, width: side, height: side)
let radius = side * 0.2237
let rounded = CGPath(roundedRect: iconRect, cornerWidth: radius, cornerHeight: radius, transform: nil)

ctx.saveGState()
ctx.addPath(rounded)
ctx.clip()

let cs = CGColorSpaceCreateDeviceRGB()
let bgColors = [
    CGColor(red: 8.0 / 255.0, green: 16.0 / 255.0, blue: 34.0 / 255.0, alpha: 1.0),
    CGColor(red: 16.0 / 255.0, green: 34.0 / 255.0, blue: 72.0 / 255.0, alpha: 1.0)
] as CFArray
if let grad = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0.0, 1.0]) {
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: f), options: [])
}

let glowColors = [
    CGColor(red: 14.0 / 255.0, green: 165.0 / 255.0, blue: 233.0 / 255.0, alpha: 0.34),
    CGColor(red: 14.0 / 255.0, green: 165.0 / 255.0, blue: 233.0 / 255.0, alpha: 0.0)
] as CFArray
if let glow = CGGradient(colorsSpace: cs, colors: glowColors, locations: [0.0, 1.0]) {
    let c = CGPoint(x: f * 0.5, y: f * 0.56)
    ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: f * 0.38, options: [])
}
ctx.restoreGState()

// Crisp glass inner rim highlight
let rimInset: CGFloat = 3.0
let rimRect = iconRect.insetBy(dx: rimInset, dy: rimInset)
let rimPath = CGPath(roundedRect: rimRect, cornerWidth: max(1, radius - rimInset), cornerHeight: max(1, radius - rimInset), transform: nil)
ctx.setStrokeColor(CGColor(red: 148.0 / 255.0, green: 210.0 / 255.0, blue: 255.0 / 255.0, alpha: 0.30))
ctx.setLineWidth(6.0)
ctx.addPath(rimPath)
ctx.strokePath()

// Subtle outer concentric guide arc
ctx.saveGState()
ctx.setStrokeColor(CGColor(red: 56.0 / 255.0, green: 189.0 / 255.0, blue: 248.0 / 255.0, alpha: 0.27))
ctx.setLineWidth(f * 0.020)
ctx.setLineCap(.round)
let guidePath = CGMutablePath()
guidePath.addArc(
    center: CGPoint(x: f * 0.5, y: f * 0.5),
    radius: f * 0.27,
    startAngle: -.pi * 0.19,
    endAngle: .pi * 0.83,
    clockwise: false
)
ctx.addPath(guidePath)
ctx.strokePath()
ctx.restoreGState()

// Geometric N-bridge vector mark with soft cyan ambient shadow
ctx.saveGState()
ctx.setShadow(
    offset: .zero,
    blur: f * 0.045,
    color: CGColor(red: 14.0 / 255.0, green: 165.0 / 255.0, blue: 233.0 / 255.0, alpha: 0.45)
)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setLineWidth(f * 0.068)

// Flip Y for bottom-left CG origin: y_cg = 1 - y_top
let arc = CGMutablePath()
arc.move(to: CGPoint(x: f * 0.29, y: f * 0.32))
arc.addCurve(
    to: CGPoint(x: f * 0.56, y: f * 0.69),
    control1: CGPoint(x: f * 0.29, y: f * 0.60),
    control2: CGPoint(x: f * 0.44, y: f * 0.69)
)
ctx.setStrokeColor(CGColor(red: 14.0 / 255.0, green: 165.0 / 255.0, blue: 233.0 / 255.0, alpha: 1.0))
ctx.addPath(arc)
ctx.strokePath()

let chev = CGMutablePath()
chev.move(to: CGPoint(x: f * 0.46, y: f * 0.32))
chev.addLine(to: CGPoint(x: f * 0.72, y: f * 0.51))
chev.addLine(to: CGPoint(x: f * 0.54, y: f * 0.69))
ctx.setStrokeColor(CGColor(red: 125.0 / 255.0, green: 211.0 / 255.0, blue: 252.0 / 255.0, alpha: 1.0))
ctx.addPath(chev)
ctx.strokePath()

// Active emerald bridge node (lower-left uplink anchor)
let nodeR = f * 0.068
let nodeRect = CGRect(x: f * 0.29 - nodeR, y: f * 0.32 - nodeR, width: nodeR * 2, height: nodeR * 2)
ctx.setFillColor(CGColor(red: 16.0 / 255.0, green: 185.0 / 255.0, blue: 129.0 / 255.0, alpha: 1.0))
ctx.fillEllipse(in: nodeRect)
ctx.setStrokeColor(CGColor(red: 209.0 / 255.0, green: 250.0 / 255.0, blue: 229.0 / 255.0, alpha: 0.86))
ctx.setLineWidth(6.0)
ctx.strokeEllipse(in: nodeRect)

// Right apex ice node
let nodeR2 = f * 0.048
let nodeRect2 = CGRect(x: f * 0.72 - nodeR2, y: f * 0.51 - nodeR2, width: nodeR2 * 2, height: nodeR2 * 2)
ctx.setFillColor(CGColor(red: 224.0 / 255.0, green: 242.0 / 255.0, blue: 254.0 / 255.0, alpha: 1.0))
ctx.fillEllipse(in: nodeRect2)
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()

guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode PNG icon\n", stderr)
    exit(1)
}
try pngData.write(to: URL(fileURLWithPath: outputPath))
SWIFTEOF

    if [[ "$dev_dir" != *.app/Contents/Developer ]] && [ -f "$REPO_DIR/.build/vfs.generated.yaml" ]; then
        swift -vfsoverlay "$REPO_DIR/.build/vfs.generated.yaml" -Xcc -ivfsoverlay -Xcc "$REPO_DIR/.build/vfs.generated.yaml" "$swift_src" "$master_2x"
    else
        swift "$swift_src" "$master_2x"
    fi
    rm -f "$swift_src"

    local python_bin=""
    if command -v python >/dev/null 2>&1 && python -c "import PIL" >/dev/null 2>&1; then
        python_bin="python"
    elif command -v python3 >/dev/null 2>&1 && python3 -c "import PIL" >/dev/null 2>&1; then
        python_bin="python3"
    fi

    if [ -n "$python_bin" ]; then
        "$python_bin" - "$master_2x" "$ICONSET_DIR" <<'PYEOF'
import os
import sys
from PIL import Image

master = Image.open(sys.argv[1])
iconset_dir = sys.argv[2]
resample = getattr(Image, "Resampling", Image).LANCZOS
targets = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]
for fname, dim in targets:
    master.resize((dim, dim), resample).save(os.path.join(iconset_dir, fname), format="PNG")
PYEOF
    else
        /usr/bin/sips -z 1024 1024 "$master_2x" --out "$final_1024" >/dev/null
        local entries=(
            "icon_16x16.png:16"
            "icon_16x16@2x.png:32"
            "icon_32x32.png:32"
            "icon_32x32@2x.png:64"
            "icon_128x128.png:128"
            "icon_128x128@2x.png:256"
            "icon_256x256.png:256"
            "icon_256x256@2x.png:512"
            "icon_512x512.png:512"
        )
        local entry fname dim
        for entry in "${entries[@]}"; do
            fname="${entry%%:*}"
            dim="${entry##*:}"
            /usr/bin/sips -z "$dim" "$dim" "$master_2x" --out "$ICONSET_DIR/$fname" >/dev/null
        done
    fi
    rm -f "$master_2x"

    iconutil -c icns "$ICONSET_DIR" -o "$dest_icns"
    rm -rf "$ICONSET_DIR"
}

echo "==> Step 1: Building NetBoost ($VERSION)..."
BUILD_CONFIG="release"
if ! "$REPO_DIR/Scripts/build.sh" -c release -j 4; then
    echo "Warning: Release build failed (possible memory limit on local CLT); falling back to debug build..." >&2
    BUILD_CONFIG="debug"
    "$REPO_DIR/Scripts/build.sh" -c debug -j 4
fi

BIN_DIR="$("$REPO_DIR/Scripts/build.sh" -c "$BUILD_CONFIG" --show-bin-path 2>/dev/null | tail -n 1 || true)"
BIN_PATH=""
if [ -n "$BIN_DIR" ] && [ -x "$BIN_DIR/${APP_NAME}App" ]; then
    BIN_PATH="$BIN_DIR/${APP_NAME}App"
else
    BIN_PATH="$(find "$REPO_DIR/.build" -maxdepth 4 -type f -name "${APP_NAME}App" -path "*/${BUILD_CONFIG}/*" 2>/dev/null | head -n 1 || true)"
fi

if [ -z "$BIN_PATH" ] || [ ! -x "$BIN_PATH" ]; then
    echo "Error: Could not locate compiled ${APP_NAME}App binary for configuration '$BUILD_CONFIG'." >&2
    exit 1
fi
echo "    Located binary ($BUILD_CONFIG): $BIN_PATH"

HELPER_BIN_DIR="$(dirname "$BIN_PATH")"
HELPER_BIN_PATH=""
if [ -x "$HELPER_BIN_DIR/NetBoostHelper" ]; then
    HELPER_BIN_PATH="$HELPER_BIN_DIR/NetBoostHelper"
else
    HELPER_BIN_PATH="$(find "$REPO_DIR/.build" -maxdepth 4 -type f -name "NetBoostHelper" -path "*/${BUILD_CONFIG}/*" 2>/dev/null | head -n 1 || true)"
fi

if [ -z "$HELPER_BIN_PATH" ] || [ ! -x "$HELPER_BIN_PATH" ]; then
    echo "Error: Could not locate compiled NetBoostHelper binary for configuration '$BUILD_CONFIG'." >&2
    exit 1
fi
echo "    Located helper ($BUILD_CONFIG): $HELPER_BIN_PATH"

echo "==> Step 2: Creating macOS Application Bundle ($APP_NAME.app)..."
rm -rf "$STAGING_DIR" "$DMG_STAGING" "$OUTPUT_DMG"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executables
cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$HELPER_BIN_PATH" "$APP_BUNDLE/Contents/MacOS/NetBoostHelper"
chmod +x "$APP_BUNDLE/Contents/MacOS/NetBoostHelper"

# Bundle privileged helper script inside Resources/ for PrivilegeHelper.locateHelperScript()
cp "$REPO_DIR/Scripts/netboost-helper.sh" "$APP_BUNDLE/Contents/Resources/netboost-helper.sh"
chmod +x "$APP_BUNDLE/Contents/Resources/netboost-helper.sh"

# Generate high-resolution AppIcon.icns
generate_app_icon "$APP_BUNDLE/Contents/Resources/AppIcon.icns"

# Generate Info.plist
cat <<EOF > "$APP_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
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
    <string>$BUNDLE_VERSION</string>
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

echo "==> Step 3: Signing $APP_NAME.app bundle..."
codesign --force --sign - --identifier "com.netboost.helper" "$APP_BUNDLE/Contents/MacOS/NetBoostHelper"
codesign --force --sign - --identifier "com.netboost.app" "$APP_BUNDLE"
codesign --verify --deep --strict "$APP_BUNDLE"

echo "==> Step 4: Preparing DMG staging directory..."
mkdir -p "$DMG_STAGING"
cp -R "$APP_BUNDLE" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

echo "==> Step 5: Generating compressed UDZO DMG installer..."
hdiutil create -volname "$APP_NAME $VERSION" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO \
    "$OUTPUT_DMG"

if [ ! -s "$OUTPUT_DMG" ]; then
    echo "Error: Failed to produce DMG at $OUTPUT_DMG" >&2
    exit 1
fi

echo "==> NetBoost DMG successfully created at:"
ls -lh "$OUTPUT_DMG"
