#!/bin/zsh
set -euo pipefail
file_actions_repo="$(cd "$(dirname "$0")/.." && pwd)"
file_actions_temp="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-file-actions.XXXXXX")"
trap 'rm -rf "$file_actions_temp"' EXIT
cd "$file_actions_repo"
swift build --disable-keychain --product FileActionsWorker
scripts/build-file-document-worker.sh
file_actions_bin="$(swift build --disable-keychain --show-bin-path)"
mkdir -p "$file_actions_temp/Preview.app/Contents/MacOS" "$file_actions_temp/Preview.app/Contents/Resources" "$file_actions_temp/Preview.app/Contents/Helpers" "$file_actions_temp/data"
cp "$file_actions_bin/FileActionsWorker" "$file_actions_temp/Preview.app/Contents/Helpers/"
cp vendor/file-actions/target/release/file-document-worker "$file_actions_temp/Preview.app/Contents/Helpers/FileDocumentWorker"
cp Resources/SketchFont.ttf Resources/SketchPaper.png "$file_actions_temp/Preview.app/Contents/Resources/"
cat > "$file_actions_temp/Preview.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>cc.anjing.file-actions.fixture</string><key>CFBundleExecutable</key><string>Preview</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>
PLIST
xcrun swiftc -parse-as-library -I "$file_actions_bin/Modules" "$file_actions_bin"/MacOSXCore.build/*.swift.o \
 Sources/MacOSX/UI/SketchTheme.swift Sources/MacOSX/UI/SketchIcons.swift Sources/MacOSX/UI/MinimalControls.swift \
 Sources/MacOSX/FileActions/*.swift tools/file-actions-regression.swift -o "$file_actions_temp/Preview.app/Contents/MacOS/Preview"
"$file_actions_temp/Preview.app/Contents/MacOS/Preview" "$file_actions_temp/data" "$file_actions_repo/tools/fixtures/file-actions"
