#!/bin/bash
set -euo pipefail
source "$(dirname "$0")/localization/fixture-core.sh"
PIN_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PIN_CHECK_DIR="$PIN_ROOT/.build/pin-regression"
mkdir -p "$PIN_CHECK_DIR"
xcrun swiftc -I "$localization_bin/Modules" "$localization_bin"/MacOSXCore.build/*.swift.o -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
  "$PIN_ROOT/Sources/MacOSX/Capture/CaptureImageService.swift" \
  "$PIN_ROOT/Sources/MacOSX/Capture/CaptureSampling.swift" \
  "$PIN_ROOT/Sources/MacOSX/Capture/CapturePinRaster.swift" \
  "$PIN_ROOT/tools/pin-regression.swift" \
  -o "$PIN_CHECK_DIR/pin-regression"
"$PIN_CHECK_DIR/pin-regression"
