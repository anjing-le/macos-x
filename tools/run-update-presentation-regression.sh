#!/bin/zsh
set -euo pipefail
update_repo="$(cd "$(dirname "$0")/.." && pwd)"
update_check_dir="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-update-presentation.XXXXXX")"
trap 'rm -rf "$update_check_dir"' EXIT
python3 - "$update_repo" "$update_check_dir" <<'PY'
from pathlib import Path
import sys
source, destination = map(Path, sys.argv[1:])
text = (source / 'Sources/MacOSX/Updates/UpdateUserDriver.swift').read_text()
(destination / 'UpdateUserDriver.swift').write_text(text.replace('import Sparkle\n', ''))
PY
xcrun swiftc "$update_check_dir/UpdateUserDriver.swift" "$update_repo/tools/update-presentation-regression.swift" -o "$update_check_dir/regression"
"$update_check_dir/regression"
cat "$update_repo/Sources/MacOSX/Updates/UpdatePanel.swift" "$update_repo/tools/update-panel-regression.swift" > "$update_check_dir/PanelFixture.swift"
mkdir -p "$update_check_dir/Preview.app/Contents/MacOS" "$update_check_dir/Preview.app/Contents/Resources"
cp "$update_repo/Resources/SketchFont.ttf" "$update_repo/Resources/SketchPaper.png" "$update_repo/Resources/AppIcon.icns" "$update_check_dir/Preview.app/Contents/Resources/"
python3 - "$update_check_dir" <<'PY'
from pathlib import Path
import sys
(Path(sys.argv[1])/'Preview.app/Contents/Info.plist').write_text('<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>cc.anjing.macos-x.update-panel.fixture</string><key>CFBundleExecutable</key><string>Preview</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>')
PY
xcrun swiftc "$update_repo/Sources/MacOSX/UI/SketchTheme.swift" "$update_repo/Sources/MacOSX/UI/SketchIcons.swift" "$update_repo/Sources/MacOSX/UI/MinimalControls.swift" "$update_check_dir/PanelFixture.swift" -o "$update_check_dir/Preview.app/Contents/MacOS/Preview"
"$update_check_dir/Preview.app/Contents/MacOS/Preview"
