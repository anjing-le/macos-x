#!/bin/zsh
set -euo pipefail
switcher_repo="$(cd "$(dirname "$0")/.." && pwd)"
switcher_check_dir="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-switcher.XXXXXX")"
trap 'rm -rf "$switcher_check_dir"' EXIT
python3 - "$switcher_repo" "$switcher_check_dir" <<'PY'
from pathlib import Path
import sys
source, destination = Path(sys.argv[1]), Path(sys.argv[2])
text = (source / 'Sources/MacOSX/WindowSwitcher/WindowThumbnailService.swift').read_text()
(destination / 'WindowThumbnailService.swift').write_text(text.replace('@preconcurrency import ScreenCaptureKit\n', ''))
errors = (source / 'Sources/MacOSX/Capture/CaptureImageService.swift').read_text()
(destination / 'CaptureFailure.swift').write_text('import AppKit\n' + errors[errors.index('enum CaptureFailure:'):errors.index('\n/// Serial')])
PY
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  "$switcher_check_dir/WindowThumbnailService.swift" \
  "$switcher_check_dir/CaptureFailure.swift" \
  "$switcher_repo/tools/switcher-regression.swift" \
  -o "$switcher_check_dir/switcher-regression"
"$switcher_check_dir/switcher-regression"
