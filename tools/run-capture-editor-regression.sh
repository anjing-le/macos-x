#!/bin/zsh
set -euo pipefail
editor_repo="$(cd "$(dirname "$0")/.." && pwd)"
editor_dir="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-editor.XXXXXX")"
trap 'rm -rf "$editor_dir"' EXIT
cd "$editor_repo"
swift build --disable-keychain --target MacOSXCore
editor_bin="$(swift build --disable-keychain --show-bin-path)"
cat Sources/MacOSX/Capture/CapturePins.swift tools/capture-editor-regression.swift > "$editor_dir/editor-and-pin-regression.swift"
xcrun swiftc -I "$editor_bin/Modules" "$editor_bin"/MacOSXCore.build/*.swift.o \
 Sources/MacOSX/UI/SketchTheme.swift Sources/MacOSX/UI/SketchIcons.swift Sources/MacOSX/UI/MinimalControls.swift \
 Sources/MacOSX/Capture/CaptureSampling.swift Sources/MacOSX/Capture/CaptureImageService.swift \
 Sources/MacOSX/Capture/CaptureAnnotations.swift Sources/MacOSX/Capture/CaptureToolbar.swift \
 Sources/MacOSX/Capture/CaptureTextRecognition.swift Sources/MacOSX/Capture/CaptureEditor.swift \
 Sources/MacOSX/Capture/CapturePinRaster.swift Sources/MacOSX/Capture/CapturePinHighlight.swift \
 "$editor_dir/editor-and-pin-regression.swift" -o "$editor_dir/capture-editor-regression"
"$editor_dir/capture-editor-regression"
