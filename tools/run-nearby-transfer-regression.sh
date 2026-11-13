#!/bin/zsh
set -euo pipefail
nearby_repo="$(cd "$(dirname "$0")/.." && pwd)"
nearby_fixture="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-nearby-fixture.XXXXXX")"
trap 'rm -rf "$nearby_fixture"' EXIT
cd "$nearby_repo"
swift build --disable-keychain --target MacOSXCore
nearby_bin="$(swift build --disable-keychain --show-bin-path)"
mkdir -p "$nearby_fixture/Preview.app/Contents/MacOS" "$nearby_fixture/Preview.app/Contents/Resources"
cp Resources/SketchFont.ttf Resources/SketchPaper.png Resources/CardNearbyTransfer.png "$nearby_fixture/Preview.app/Contents/Resources/"
python3 - "$nearby_fixture" <<'PY'
import pathlib,sys
p=pathlib.Path(sys.argv[1])/'Preview.app/Contents/Info.plist'
p.write_text('<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>cc.anjing.nearby.fixture</string><key>CFBundleExecutable</key><string>Preview</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>')
PY
xcrun swiftc -parse-as-library -I "$nearby_bin/Modules" "$nearby_bin"/MacOSXCore.build/*.swift.o \
 Sources/MacOSX/UI/SketchTheme.swift Sources/MacOSX/UI/SketchIcons.swift Sources/MacOSX/UI/MinimalControls.swift \
 Sources/MacOSX/NearbyTransfer/*.swift tools/nearby-transfer-regression.swift \
 -o "$nearby_fixture/Preview.app/Contents/MacOS/Preview"
"$nearby_fixture/Preview.app/Contents/MacOS/Preview"
