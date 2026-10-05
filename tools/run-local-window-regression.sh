#!/bin/zsh
set -euo pipefail
local_repo="$(cd "$(dirname "$0")/.." && pwd)"
local_check_dir="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-local-window.XXXXXX")"
trap 'rm -rf "$local_check_dir"' EXIT
python3 - "$local_repo" "$local_check_dir" <<'PY'
from pathlib import Path
import sys
source, destination = Path(sys.argv[1]), Path(sys.argv[2])
text = (source / 'Sources/MacOSX/WindowSwitcher/WindowInventory.swift').read_text()
(destination / 'WindowInventory.swift').write_text(text.replace('import MacOSXCore\n', ''))
PY
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  "$local_repo/Sources/MacOSXCore/WindowRecency.swift" \
  "$local_repo/Sources/MacOSXCore/WindowFocusResolution.swift" \
  "$local_check_dir/WindowInventory.swift" \
  "$local_repo/Sources/MacOSX/WindowSwitcher/LocalSwitcherWindows.swift" \
  "$local_repo/Sources/MacOSX/WindowSwitcher/PrivateWindowBridge.swift" \
  "$local_repo/tools/local-window-regression.swift" \
  -o "$local_check_dir/local-window-regression"
"$local_check_dir/local-window-regression"
