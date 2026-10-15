#!/bin/zsh
set -euo pipefail
radar_repo="$(cd "$(dirname "$0")/.." && pwd)"
cd "$radar_repo"
scripts/build.sh --disable-updates --configuration debug --output-dir dist/shortcut-radar-preview/app
python3 - <<'PY'
from pathlib import Path
import plistlib, subprocess
app = Path('dist/shortcut-radar-preview/app/MacOSX.app')
info_path = app/'Contents/Info.plist'
info = plistlib.loads(info_path.read_bytes())
assert info['MacOSXUpdatesEnabled'] is False
assert 'SUFeedURL' not in info and 'SUPublicEDKey' not in info
info['CFBundleIdentifier'] = 'cc.anjing.macos-x.shortcut-radar-preview'
info['CFBundleDisplayName'] = 'macos-x 快捷键雷达预览'
info_path.write_bytes(plistlib.dumps(info))
subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', '--identifier', info['CFBundleIdentifier'], str(app)], check=True)
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print('Isolated preview only; no launch, installation, permission changes or OTA.')
print(app.resolve())
PY
