#!/bin/bash
set -eo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VFS="$ROOT_DIR/vfs.yaml"
FW="/Library/Developer/CommandLineTools/Library/Developer/Frameworks"

REAL='_$s18PackageDescription0A0C4name19defaultLocalization9platforms9pkgConfig9providers8products12dependencies7targets18swiftLanguageModes01cN8Standard03cxxnP0ACSS_AA0N3TagVSgSayAA17SupportedPlatformVGSgSSSgSayAA06SystemA8ProviderOGSgSayAA7ProductCGSayAC10DependencyCGSayAA6TargetCGSayAA05SwiftN4ModeOGSgAA09CLanguageP0OSgAA011CXXLanguageP0OSgtcfC'
MISSING='_$s18PackageDescription0A0C4name19defaultLocalization9platforms9pkgConfig9providers8products12dependencies7targets21swiftLanguageVersions01cN8Standard03cxxnP0ACSS_AA0N3TagVSgSayAA17SupportedPlatformVGSgSSSgSayAA06SystemA8ProviderOGSgSayAA7ProductCGSayAC10DependencyCGSayAA6TargetCGSayAA12SwiftVersionOGSgAA09CLanguageP0OSgAA011CXXLanguageP0OSgtcfC'

export DYLD_FRAMEWORK_PATH="$FW:${DYLD_FRAMEWORK_PATH:-}"

echo "==> Running NetBoost Tests with Apple Testing.framework..."
swift test \
  -Xbuild-tools-swiftc -vfsoverlay -Xbuild-tools-swiftc "$VFS" \
  -Xbuild-tools-swiftc -Xlinker -Xbuild-tools-swiftc -alias \
  -Xbuild-tools-swiftc -Xlinker -Xbuild-tools-swiftc "$REAL" \
  -Xbuild-tools-swiftc -Xlinker -Xbuild-tools-swiftc "$MISSING" \
  -Xswiftc -vfsoverlay -Xswiftc "$VFS" \
  -Xswiftc -Xcc -Xswiftc -ivfsoverlay -Xswiftc -Xcc -Xswiftc "$VFS" \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  "$@"
