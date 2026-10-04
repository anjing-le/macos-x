#!/bin/zsh
set -euo pipefail
access_repo="$(cd "$(dirname "$0")/.." && pwd)"
access_check_dir="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-capture-access.XXXXXX")"
trap 'rm -rf "$access_check_dir"' EXIT
python3 - "$access_repo" "$access_check_dir" <<'PY'
from pathlib import Path
import sys
source, destination = Path(sys.argv[1]), Path(sys.argv[2])
for filename in ['CaptureImageService.swift', 'CaptureRecorder.swift', 'CaptureModule.swift']:
    text = (source / 'Sources/MacOSX/Capture' / filename).read_text()
    # The only substituted production text is the framework import. The test
    # provides asynchronous ScreenCaptureKit and non-presenting UI doubles.
    text = text.replace('@preconcurrency import ScreenCaptureKit\n', '')
    (destination / filename).write_text(text)
PY
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  "$access_check_dir/CaptureImageService.swift" \
  "$access_check_dir/CaptureRecorder.swift" \
  "$access_check_dir/CaptureModule.swift" \
  "$access_repo/Sources/MacOSX/Capture/CaptureSampling.swift" \
  "$access_repo/tools/capture-access-regression.swift" \
  -o "$access_check_dir/capture-access-regression"
"$access_check_dir/capture-access-regression"
