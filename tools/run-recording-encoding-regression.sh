#!/bin/zsh
set -euo pipefail
encoding_root="$(cd "$(dirname "$0")/.." && pwd)"
encoding_work="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-encoding.XXXXXX")"
trap 'rm -rf "$encoding_work"' EXIT
xcrun swiftc -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
 "$encoding_root/Sources/MacOSX/Capture/RecordingEncoding.swift" \
 "$encoding_root/tools/recording-encoding-regression.swift" -o "$encoding_work/regression"
"$encoding_work/regression"
