#!/bin/zsh
set -euo pipefail
source "$(dirname "$0")/localization/fixture-core.sh"
text_repo="$(cd "$(dirname "$0")/.." && pwd)"
text_temp="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-text-pin.XXXXXX")"
trap 'rm -rf "$text_temp"' EXIT
cd "$text_repo"
xcrun swiftc -I "$localization_bin/Modules" "$localization_bin"/MacOSXCore.build/*.swift.o -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
 Sources/MacOSX/Capture/CaptureImageService.swift Sources/MacOSX/Capture/CaptureSampling.swift \
 Sources/MacOSX/Capture/CapturePinRaster.swift Sources/MacOSX/Capture/CapturePinHighlight.swift \
 Sources/MacOSX/Capture/CapturePinContracts.swift Sources/MacOSX/Capture/CaptureTextDocument.swift \
 Sources/MacOSX/Capture/CaptureTextPin.swift tools/text-pin-regression.swift -o "$text_temp/regression"
"$text_temp/regression"
