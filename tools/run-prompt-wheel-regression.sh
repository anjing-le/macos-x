#!/bin/zsh
set -euo pipefail
wheel_repo="$(cd "$(dirname "$0")/.." && pwd)"
wheel_dir="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-prompt-wheel.XXXXXX")"
trap 'rm -rf "$wheel_dir"' EXIT
cd "$wheel_repo"
swift build --disable-keychain --target MacOSXCore
wheel_bin="$(swift build --disable-keychain --show-bin-path)"
mkdir -p "$wheel_dir/Preview.app/Contents/MacOS" "$wheel_dir/Preview.app/Contents/Resources"
cp -R Resources/en.lproj Resources/zh-Hans.lproj "$wheel_dir/Preview.app/Contents/Resources/"
cp Resources/SettingsPromptsBoard.png Resources/SketchPaper.png Resources/SketchFont.ttf "$wheel_dir/Preview.app/Contents/Resources/"
python3 - "$wheel_repo" "$wheel_dir" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
source = (root / 'Sources/MacOSX/Shared/GlobalInput.swift').read_text()
(out / 'ShortcutTypes.swift').write_text(source[:source.index('private enum InputAction')] + source[source.index('extension ShortcutBinding'):])
texts=[(root / name).read_text() for name in ['Sources/MacOSX/PhraseWheel/PhraseWheelModule.swift','tools/prompt-management-regression.swift','tools/prompt-polish-regression.swift','tools/prompt-wheel-regression.swift']]
if __import__('os').environ.get('MACOSX_TEST_LANGUAGE') == 'en':
    sys.path.insert(0,str(root/'tools/localization'))
    import extract
    texts=[texts[0]]+[extract.process(t,'fixture',apply=True) for t in texts[1:]]
(out / 'PromptModuleAndFixture.swift').write_text('\n'.join(texts))

PY
xcrun swiftc -I "$wheel_bin/Modules" "$wheel_bin"/MacOSXCore.build/*.swift.o \
  Sources/MacOSX/UI/SketchTheme.swift Sources/MacOSX/UI/SketchIcons.swift \
  Sources/MacOSX/UI/MinimalControls.swift Sources/MacOSX/UI/SettingsBoardView.swift Sources/MacOSX/Shared/ShortcutSettings.swift "$wheel_dir/ShortcutTypes.swift" Sources/MacOSX/Capture/RecordingPresentation.swift Sources/MacOSX/PhraseWheel/PromptDrag.swift Sources/MacOSX/PhraseWheel/PhraseWheelPanel.swift \
  tools/prompt-preview-regression.swift "$wheel_dir/PromptModuleAndFixture.swift" -o "$wheel_dir/Preview.app/Contents/MacOS/prompt-wheel-regression"
"$wheel_dir/Preview.app/Contents/MacOS/prompt-wheel-regression" "$wheel_dir"
