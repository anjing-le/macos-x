#!/bin/zsh
set -euo pipefail
shelf_repo="$(cd "$(dirname "$0")/.." && pwd)"
shelf_dir="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-shelf.XXXXXX")"
trap 'rm -rf "$shelf_dir"' EXIT
xcrun swiftc -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
 "$shelf_repo/Sources/MacOSX/UI/SketchTheme.swift" \
 "$shelf_repo/Sources/MacOSX/Capture/CaptureShelfStore.swift" \
 "$shelf_repo/Sources/MacOSX/Capture/CaptureShelf.swift" \
 "$shelf_repo/tools/capture-shelf-regression.swift" -o "$shelf_dir/check"
"$shelf_dir/check"
