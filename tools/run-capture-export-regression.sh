#!/bin/zsh
set -euo pipefail
export_repo="$(cd "$(dirname "$0")/.." && pwd)"
export_check_dir="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-export.XXXXXX")"
trap 'rm -rf "$export_check_dir"' EXIT
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  "$export_repo/Sources/MacOSX/Capture/CaptureSampling.swift" \
  "$export_repo/Sources/MacOSX/Capture/CaptureImageService.swift" \
  "$export_repo/Sources/MacOSX/Capture/CaptureAnnotations.swift" \
  "$export_repo/Sources/MacOSX/Capture/CaptureRecordingFile.swift" \
  "$export_repo/tools/capture-export-regression.swift" \
  -o "$export_check_dir/capture-export-regression"
"$export_check_dir/capture-export-regression"
