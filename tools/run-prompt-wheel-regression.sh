#!/bin/zsh
set -euo pipefail
wheel_repo="$(cd "$(dirname "$0")/.." && pwd)"
wheel_dir="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-prompt-wheel.XXXXXX")"
trap 'rm -rf "$wheel_dir"' EXIT
cd "$wheel_repo"
swift build --disable-keychain --target MacOSXCore
wheel_bin="$(swift build --disable-keychain --show-bin-path)"
mkdir -p "$wheel_dir/Preview.app/Contents/MacOS" "$wheel_dir/Preview.app/Contents/Resources"
cp Resources/SettingsPromptsBoard.png Resources/SketchPaper.png Resources/SketchFont.ttf "$wheel_dir/Preview.app/Contents/Resources/"
xcrun swiftc -I "$wheel_bin/Modules" "$wheel_bin"/MacOSXCore.build/*.swift.o \
  Sources/MacOSX/UI/SketchTheme.swift Sources/MacOSX/UI/SketchIcons.swift \
  Sources/MacOSX/UI/MinimalControls.swift Sources/MacOSX/UI/SettingsBoardView.swift Sources/MacOSX/Capture/RecordingPresentation.swift Sources/MacOSX/PhraseWheel/PhraseWheelPanel.swift Sources/MacOSX/PhraseWheel/PhraseWheelModule.swift \
  tools/prompt-wheel-regression.swift -o "$wheel_dir/Preview.app/Contents/MacOS/prompt-wheel-regression"
"$wheel_dir/Preview.app/Contents/MacOS/prompt-wheel-regression" "$wheel_dir"
