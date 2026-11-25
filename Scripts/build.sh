#!/bin/bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

SHOW_BIN_PATH=0
for arg in "$@"; do
    if [ "$arg" = "--show-bin-path" ]; then
        SHOW_BIN_PATH=1
        break
    fi
done

DEV_DIR="$(xcode-select -p 2>/dev/null || true)"

# Full Xcode (.app/Contents/Developer) works natively without CLT VFS/alias workarounds.
if [[ "$DEV_DIR" == *.app/Contents/Developer ]]; then
    if [ "$SHOW_BIN_PATH" -eq 0 ]; then
        echo "==> Building NetBoost with Xcode toolchain ($DEV_DIR)..."
    fi
    exec swift build "$@"
fi

# Command Line Tools fallback (e.g. local Swift 6.2 CLT): generate portable VFS overlay in .build/.
CLT_DIR="${DEV_DIR:-/Library/Developer/CommandLineTools}"
mkdir -p "$ROOT_DIR/.build"
VFS="$ROOT_DIR/.build/vfs.generated.yaml"
VFS_TMP="$VFS.tmp.$$"

ROOT_JSON="${ROOT_DIR//\\/\\\\}"
ROOT_JSON="${ROOT_JSON//\"/\\\"}"
CLT_JSON="${CLT_DIR//\\/\\\\}"
CLT_JSON="${CLT_JSON//\"/\\\"}"

cat <<EOF > "$VFS_TMP"
{
  "version": 0,
  "case-sensitive": "false",
  "roots": [
    {
      "type": "directory",
      "name": "${CLT_JSON}/usr/include/swift",
      "contents": [
        {
          "type": "file",
          "name": "module.modulemap",
          "external-contents": "${ROOT_JSON}/Scripts/empty.modulemap"
        }
      ]
    },
    {
      "type": "directory",
      "name": "${CLT_JSON}/Library/Developer/Frameworks/Testing.framework/Versions/Current/Modules/Testing.swiftcrossimport",
      "contents": [
        {
          "type": "file",
          "name": "Foundation.swiftoverlay",
          "external-contents": "${ROOT_JSON}/Scripts/empty.swiftoverlay"
        }
      ]
    },
    {
      "type": "directory",
      "name": "${CLT_JSON}/Library/Developer/Frameworks/Testing.framework/Modules/Testing.swiftcrossimport",
      "contents": [
        {
          "type": "file",
          "name": "Foundation.swiftoverlay",
          "external-contents": "${ROOT_JSON}/Scripts/empty.swiftoverlay"
        }
      ]
    }
  ]
}
EOF
mv -f "$VFS_TMP" "$VFS"

REAL='_$s18PackageDescription0A0C4name19defaultLocalization9platforms9pkgConfig9providers8products12dependencies7targets18swiftLanguageModes01cN8Standard03cxxnP0ACSS_AA0N3TagVSgSayAA17SupportedPlatformVGSgSSSgSayAA06SystemA8ProviderOGSgSayAA7ProductCGSayAC10DependencyCGSayAA6TargetCGSayAA05SwiftN4ModeOGSgAA09CLanguageP0OSgAA011CXXLanguageP0OSgtcfC'
MISSING='_$s18PackageDescription0A0C4name19defaultLocalization9platforms9pkgConfig9providers8products12dependencies7targets21swiftLanguageVersions01cN8Standard03cxxnP0ACSS_AA0N3TagVSgSayAA17SupportedPlatformVGSgSSSgSayAA06SystemA8ProviderOGSgSayAA7ProductCGSayAC10DependencyCGSayAA6TargetCGSayAA12SwiftVersionOGSgAA09CLanguageP0OSgAA011CXXLanguageP0OSgtcfC'

if [ "$SHOW_BIN_PATH" -eq 0 ]; then
    echo "==> Building NetBoost with CLT toolchain ($CLT_DIR)..."
fi

exec swift build \
  -Xbuild-tools-swiftc -vfsoverlay -Xbuild-tools-swiftc "$VFS" \
  -Xbuild-tools-swiftc -Xlinker -Xbuild-tools-swiftc -alias \
  -Xbuild-tools-swiftc -Xlinker -Xbuild-tools-swiftc "$REAL" \
  -Xbuild-tools-swiftc -Xlinker -Xbuild-tools-swiftc "$MISSING" \
  -Xswiftc -vfsoverlay -Xswiftc "$VFS" \
  -Xswiftc -Xcc -Xswiftc -ivfsoverlay -Xswiftc -Xcc -Xswiftc "$VFS" \
  "$@"
