#!/bin/zsh
set -euo pipefail
source "$(dirname "$0")/localization/fixture-core.sh"
audio_repo="$(cd "$(dirname "$0")/.." && pwd)"
audio_dir="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-audio.XXXXXX")"
trap 'rm -rf "$audio_dir"' EXIT
xcrun swiftc -I "$localization_bin/Modules" "$localization_bin"/MacOSXCore.build/*.swift.o -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  "$audio_repo/Sources/MacOSX/Capture/CaptureSampling.swift" \
  "$audio_repo/Sources/MacOSX/Capture/CaptureImageService.swift" \
  "$audio_repo/Sources/MacOSX/Capture/RecordingAudio.swift" \
  "$audio_repo/tools/recording-audio-regression.swift" \
  -o "$audio_dir/recording-audio-regression"
"$audio_dir/recording-audio-regression"
