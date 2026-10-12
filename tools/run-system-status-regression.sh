#!/bin/zsh
set -euo pipefail
status_repo="$(cd "$(dirname "$0")/.." && pwd)"
status_dir="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-system-status.XXXXXX")"
trap 'rm -rf "$status_dir"' EXIT
cd "$status_repo"
if [[ "${MACOSX_SKIP_CORE_BUILD:-0}" != 1 ]]; then
  swift build --disable-keychain --target MacOSXCore
fi
status_bin="$(swift build --disable-keychain --show-bin-path)"
mkdir -p "$status_dir/Preview.app/Contents/MacOS" "$status_dir/Preview.app/Contents/Resources"
cp Resources/SketchFont.ttf Resources/SketchPaper.png "$status_dir/Preview.app/Contents/Resources/"
python3 - "$status_repo" "$status_dir" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
# Keep private fixture inspection in this temporary compilation unit; production
# source needs no test-only callback, metric mutator, observer or status item.
paths = ['Sources/MacOSX/SystemStatus/SystemStatusSampler.swift',
         'Sources/MacOSX/SystemStatus/SystemStatusDashboardView.swift',
         'Sources/MacOSX/SystemStatus/SystemStatusModule.swift',
         'tools/system-status-regression.swift']
(out / 'SystemStatusAndFixture.swift').write_text('\n'.join((root / p).read_text() for p in paths))
(out / 'Preview.app/Contents/Info.plist').write_text('''<?xml version="1.0"?><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>cc.anjing.macos-x.system-status.fixture</string>
<key>CFBundleExecutable</key><string>Preview</string><key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/></dict></plist>''')
PY
xcrun swiftc -I "$status_bin/Modules" "$status_bin"/MacOSXCore.build/*.swift.o \
  Sources/MacOSX/UI/SketchTheme.swift "$status_dir/SystemStatusAndFixture.swift" \
  -o "$status_dir/Preview.app/Contents/MacOS/Preview"
"$status_dir/Preview.app/Contents/MacOS/Preview" "$@"
