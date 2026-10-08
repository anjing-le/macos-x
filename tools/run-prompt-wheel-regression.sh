#!/bin/zsh
set -euo pipefail
wheel_repo="$(cd "$(dirname "$0")/.." && pwd)"
wheel_dir="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-prompt-wheel.XXXXXX")"
trap 'rm -rf "$wheel_dir"' EXIT
cd "$wheel_repo"
swift build --disable-keychain --target MacOSXCore
wheel_bin="$(swift build --disable-keychain --show-bin-path)"
xcrun swiftc -I "$wheel_bin/Modules" "$wheel_bin"/MacOSXCore.build/*.swift.o \
  Sources/MacOSX/UI/SketchTheme.swift Sources/MacOSX/UI/SketchIcons.swift \
  Sources/MacOSX/UI/MinimalControls.swift Sources/MacOSX/UI/SettingsBoardView.swift Sources/MacOSX/PhraseWheel/PhraseWheelPanel.swift Sources/MacOSX/PhraseWheel/PhraseWheelModule.swift \
  tools/prompt-wheel-regression.swift -o "$wheel_dir/prompt-wheel-regression"
"$wheel_dir/prompt-wheel-regression" "$wheel_dir"
