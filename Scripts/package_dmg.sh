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

    local python_bin=""
    if command -v python >/dev/null 2>&1 && python -c "import PIL" >/dev/null 2>&1; then
        python_bin="python"
    elif command -v python3 >/dev/null 2>&1 && python3 -c "import PIL" >/dev/null 2>&1; then
        python_bin="python3"
    fi

    if [ -n "$python_bin" ]; then
        echo "    Generating AppIcon.icns using $python_bin + Pillow (supersampled N-bridge mark)..."
        "$python_bin" - "$ICONSET_DIR" <<'PYEOF'
import math
import os
import sys
from PIL import Image, ImageDraw, ImageFilter

iconset_dir = sys.argv[1]
canvas = 2048  # 2x supersampled master -> LANCZOS downsample for sharp edges

def make_master() -> Image.Image:
    base = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    # macOS HIG squircle icon padding (~9.7% inset inside 1024 grid)
    pad = int(canvas * 0.098)
    radius = int((canvas - 2 * pad) * 0.2237)
    box = [pad, pad, canvas - pad, canvas - pad]

    # Deep vertical indigo-obsidian studio gradient
    grad = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    gdraw = ImageDraw.Draw(grad)
    for y in range(canvas):
        t = y / max(1, canvas - 1)
        r = int(16 - 8 * t)
        g = int(34 - 18 * t)
        b = int(72 - 38 * t)
        gdraw.line([(0, y), (canvas, y)], fill=(r, g, b, 255))

    mask = Image.new("L", (canvas, canvas), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)
    base.paste(grad, (0, 0), mask)

    # Top studio backlight bloom clipped inside squircle
    glow = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    cx, cy = canvas // 2, int(canvas * 0.44)
    gr = int(canvas * 0.34)
    gd.ellipse([cx - gr, cy - gr, cx + gr, cy + gr], fill=(14, 165, 233, 88))
    glow = glow.filter(ImageFilter.GaussianBlur(radius=int(canvas * 0.11)))
    base = Image.alpha_composite(base, Image.composite(glow, Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0)), mask))

    # Crisp glass inner rim highlight
    rim = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    rdraw = ImageDraw.Draw(rim)
    rdraw.rounded_rectangle(
        [pad + 3, pad + 3, canvas - pad - 3, canvas - pad - 3],
        radius=max(1, radius - 3),
        outline=(148, 210, 255, 76),
        width=6,
    )
    base = Image.alpha_composite(base, rim)

    # Geometric vector mark: wired uplink arc + velocity bridge chevron + active emerald node
    mark = Image.new("RGBA", (canvas, canvas), (0, 0, 0, 0))
    md = ImageDraw.Draw(mark)
    sw = int(canvas * 0.068)

    # Subtle outer concentric guide arc
    guide_r = int(canvas * 0.27)
    md.arc(
        [canvas // 2 - guide_r, canvas // 2 - guide_r, canvas // 2 + guide_r, canvas // 2 + guide_r],
        start=210,
        end=35,
        fill=(56, 189, 248, 70),
        width=int(canvas * 0.020),
    )

    # Left rising bezier curve approximated cleanly via high-res polyline + round joints
    pts_arc = []
    p0 = (canvas * 0.29, canvas * 0.68)
    p1 = (canvas * 0.29, canvas * 0.40)
    p2 = (canvas * 0.44, canvas * 0.31)
    p3 = (canvas * 0.56, canvas * 0.31)
    steps = 48
    for i in range(steps + 1):
        t = i / steps
        mt = 1 - t
        x = (mt**3)*p0[0] + 3*(mt**2)*t*p1[0] + 3*mt*(t**2)*p2[0] + (t**3)*p3[0]
        y = (mt**3)*p0[1] + 3*(mt**2)*t*p1[1] + 3*mt*(t**2)*p2[1] + (t**3)*p3[1]
        pts_arc.append((x, y))
    md.line(pts_arc, fill=(14, 165, 233, 255), width=sw, joint="curve")
    r_cap = sw // 2
    for px_c, py_c in (pts_arc[0], pts_arc[-1]):
        md.ellipse([px_c - r_cap, py_c - r_cap, px_c + r_cap, py_c + r_cap], fill=(14, 165, 233, 255))

    # Forward high-throughput chevron + stem
    chev = [
        (canvas * 0.46, canvas * 0.68),
        (canvas * 0.72, canvas * 0.49),
        (canvas * 0.54, canvas * 0.31),
    ]
    md.line(chev, fill=(125, 211, 252, 255), width=sw, joint="curve")
    for px_c, py_c in chev:
        md.ellipse([px_c - r_cap, py_c - r_cap, px_c + r_cap, py_c + r_cap], fill=(125, 211, 252, 255))

    # Active emerald bridge node (lower-left uplink anchor)
    nr = int(canvas * 0.068)
    nx, ny = int(canvas * 0.29), int(canvas * 0.68)
    md.ellipse([nx - nr, ny - nr, nx + nr, ny + nr], fill=(16, 185, 129, 255), outline=(209, 250, 229, 220), width=6)

    # Top-right ice node
    nx2, ny2 = int(canvas * 0.72), int(canvas * 0.49)
    nr2 = int(canvas * 0.048)
    md.ellipse([nx2 - nr2, ny2 - nr2, nx2 + nr2, ny2 + nr2], fill=(224, 242, 254, 255))

    mark_glow = mark.filter(ImageFilter.GaussianBlur(radius=int(canvas * 0.028)))
    base = Image.alpha_composite(base, mark_glow)
    base = Image.alpha_composite(base, mark)
    return base

master = make_master()
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

resample = getattr(Image, "Resampling", Image).LANCZOS
for fname, dim in targets:
    img = master.resize((dim, dim), resample)
    img.save(os.path.join(iconset_dir, fname), format="PNG")
PYEOF
    else
        echo "    Generating AppIcon.icns using Swift CoreGraphics + sips fallback..."
        local master_png="$ICONSET_DIR/icon_512x512@2x.png"
        local swift_src="$ICONSET_DIR/icon_gen.swift"
        local dev_dir
        dev_dir="$(xcode-select -p 2>/dev/null || true)"

        cat <<'SWIFTEOF' > "$swift_src"
import AppKit
import CoreGraphics
import Foundation

let outputPath = CommandLine.arguments[1]
let size = 1024

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
let f = CGFloat(size)

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
    CGColor(red: 0.03, green: 0.06, blue: 0.13, alpha: 1.0),
    CGColor(red: 0.06, green: 0.13, blue: 0.28, alpha: 1.0)
] as CFArray
if let grad = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0.0, 1.0]) {
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: f), options: [])
}

let glowColors = [
    CGColor(red: 0.05, green: 0.65, blue: 0.91, alpha: 0.34),
    CGColor(red: 0.05, green: 0.65, blue: 0.91, alpha: 0.0)
] as CFArray
if let glow = CGGradient(colorsSpace: cs, colors: glowColors, locations: [0.0, 1.0]) {
    let c = CGPoint(x: f * 0.5, y: f * 0.56)
    ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: f * 0.36, options: [])
}
ctx.restoreGState()

ctx.setStrokeColor(CGColor(red: 0.58, green: 0.82, blue: 1.0, alpha: 0.3))
ctx.setLineWidth(f * 0.006)
ctx.addPath(rounded)
ctx.strokePath()

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
ctx.setStrokeColor(CGColor(red: 0.05, green: 0.65, blue: 0.91, alpha: 1.0))
ctx.addPath(arc)
ctx.strokePath()

let chev = CGMutablePath()
chev.move(to: CGPoint(x: f * 0.46, y: f * 0.32))
chev.addLine(to: CGPoint(x: f * 0.72, y: f * 0.51))
chev.addLine(to: CGPoint(x: f * 0.54, y: f * 0.69))
ctx.setStrokeColor(CGColor(red: 0.49, green: 0.83, blue: 0.99, alpha: 1.0))
ctx.addPath(chev)
ctx.strokePath()

let nodeR = f * 0.068
ctx.setFillColor(CGColor(red: 0.06, green: 0.73, blue: 0.51, alpha: 1.0))
ctx.fillEllipse(in: CGRect(x: f * 0.29 - nodeR, y: f * 0.32 - nodeR, width: nodeR * 2, height: nodeR * 2))

NSGraphicsContext.restoreGraphicsState()

guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode PNG icon\n", stderr)
    exit(1)
}
try pngData.write(to: URL(fileURLWithPath: outputPath))
SWIFTEOF

        if [[ "$dev_dir" != *.app/Contents/Developer ]] && [ -f "$REPO_DIR/.build/vfs.generated.yaml" ]; then
            swift -vfsoverlay "$REPO_DIR/.build/vfs.generated.yaml" -Xcc -ivfsoverlay -Xcc "$REPO_DIR/.build/vfs.generated.yaml" "$swift_src" "$master_png"
        else
            swift "$swift_src" "$master_png"
        fi
        rm -f "$swift_src"

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
            /usr/bin/sips -z "$dim" "$dim" "$master_png" --out "$ICONSET_DIR/$fname" >/dev/null
        done
    fi

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
