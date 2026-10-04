#!/bin/zsh
set -euo pipefail
capture_repo="$(cd "$(dirname "$0")/.." && pwd)"
capture_check_dir="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-capture-regression.XXXXXX")"
trap 'rm -rf "$capture_check_dir"' EXIT
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  "$capture_repo/Sources/MacOSX/Capture/CaptureSampling.swift" \
  "$capture_repo/Sources/MacOSX/Capture/CaptureImageService.swift" \
  "$capture_repo/tools/capture-regression.swift" \
  -o "$capture_check_dir/capture-regression"
"$capture_check_dir/capture-regression"
