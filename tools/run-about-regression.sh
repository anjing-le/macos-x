#!/bin/zsh
set -euo pipefail
source "$(dirname "$0")/localization/fixture-core.sh"
about_repo="$(cd "$(dirname "$0")/.." && pwd)"
about_fixture="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-about.XXXXXX")"
trap 'rm -rf "$about_fixture"' EXIT
mkdir -p "$about_fixture/Preview.app/Contents/MacOS" "$about_fixture/Preview.app/Contents/Resources"
cp "$about_repo/Resources/SketchFont.ttf" "$about_repo/Resources/SketchPaper.png" "$about_repo/Resources/AppIcon.icns" "$about_fixture/Preview.app/Contents/Resources/"
cat > "$about_fixture/Preview.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>cc.anjing.about.fixture</string><key>CFBundleExecutable</key><string>Preview</string><key>LSUIElement</key><true/></dict></plist>
PLIST
xcrun swiftc -parse-as-library -I "$localization_bin/Modules" "$localization_bin"/MacOSXCore.build/*.swift.o \
 "$about_repo/Sources/MacOSX/UI/SketchTheme.swift" "$about_repo/Sources/MacOSX/UI/SketchIcons.swift" "$about_repo/Sources/MacOSX/UI/MinimalControls.swift" \
 "$about_repo/Sources/MacOSX/Shared/AboutWindowController.swift" "$about_repo/tools/about-regression.swift" -o "$about_fixture/Preview.app/Contents/MacOS/Preview"
"$about_fixture/Preview.app/Contents/MacOS/Preview"
