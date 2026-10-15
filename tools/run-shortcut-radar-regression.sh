#!/bin/zsh
set -euo pipefail
radar_repo="$(cd "$(dirname "$0")/.." && pwd)"
radar_dir="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-radar.XXXXXX")"
trap 'rm -rf "$radar_dir"' EXIT
cd "$radar_repo"
swift build --disable-keychain --target MacOSXCore
radar_bin="$(swift build --disable-keychain --show-bin-path)"
mkdir -p "$radar_dir/Preview.app/Contents/MacOS" "$radar_dir/Preview.app/Contents/Resources"
cp Resources/SketchFont.ttf Resources/SketchPaper.png "$radar_dir/Preview.app/Contents/Resources/"
python3 - "$radar_repo" "$radar_dir" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
paths = ['Sources/MacOSX/ShortcutRadar/ShortcutRadarScanner.swift',
         'Sources/MacOSX/ShortcutRadar/ShortcutRadarDashboard.swift',
         'Sources/MacOSX/ShortcutRadar/ShortcutRadarModule.swift',
         'tools/shortcut-radar-regression.swift']
(out/'RadarAndFixture.swift').write_text('\n'.join((root/p).read_text() for p in paths))
(out/'Preview.app/Contents/Info.plist').write_text('''<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>cc.anjing.macos-x.shortcut-radar.fixture</string>
<key>CFBundleExecutable</key><string>Preview</string><key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/></dict></plist>''')
PY
xcrun swiftc -I "$radar_bin/Modules" "$radar_bin"/MacOSXCore.build/*.swift.o \
  Sources/MacOSX/UI/SketchTheme.swift Sources/MacOSX/UI/MinimalControls.swift Sources/MacOSX/UI/SketchIcons.swift Sources/MacOSX/UI/ToolCard.swift \
  "$radar_dir/RadarAndFixture.swift" -o "$radar_dir/Preview.app/Contents/MacOS/Preview"
"$radar_dir/Preview.app/Contents/MacOS/Preview" "$@"
