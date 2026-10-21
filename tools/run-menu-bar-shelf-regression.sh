#!/bin/zsh
set -euo pipefail
menu_repo="$(cd "$(dirname "$0")/.." && pwd)"
menu_dir="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-menu-shelf.XXXXXX")"
trap 'rm -rf "$menu_dir"' EXIT
cd "$menu_repo"
swift build --disable-keychain --target MenuBarVisibilityBridge
menu_bin="$(swift build --disable-keychain --show-bin-path)"
mkdir -p "$menu_dir/Preview.app/Contents/MacOS" "$menu_dir/Preview.app/Contents/Resources"
cp Resources/SketchFont.ttf Resources/SketchPaper.png "$menu_dir/Preview.app/Contents/Resources/"
cat > "$menu_dir/Preview.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>cc.anjing.macos-x.menu-bar-shelf.fixture</string><key>CFBundleExecutable</key><string>Preview</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
PLIST
xcrun swiftc -parse-as-library -Xcc "-fmodule-map-file=$menu_bin/MenuBarVisibilityBridge.build/module.modulemap" \
 -I Sources/MenuBarVisibilityBridge/include "$menu_bin"/MenuBarVisibilityBridge.build/*.o \
 Sources/MacOSX/UI/SketchTheme.swift Sources/MacOSX/UI/MinimalControls.swift \
 Sources/MacOSX/MenuBarShelf/*.swift tools/menu-bar-shelf-regression.swift \
 -o "$menu_dir/Preview.app/Contents/MacOS/Preview"
"$menu_dir/Preview.app/Contents/MacOS/Preview"
