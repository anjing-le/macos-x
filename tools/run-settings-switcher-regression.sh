#!/bin/zsh
set -euo pipefail
guide_repo="$(cd "$(dirname "$0")/.." && pwd)"
guide_dir="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-settings.XXXXXX")"
trap 'rm -rf "$guide_dir"' EXIT
cd "$guide_repo"
swift build --disable-keychain --target MacOSXCore
guide_bin="$(swift build --disable-keychain --show-bin-path)"
mkdir -p "$guide_dir/Preview.app/Contents/MacOS" "$guide_dir/Preview.app/Contents/Resources"
cp Resources/Settings*Board.png Resources/Guide*.png Resources/Card*.png Resources/SketchFont.ttf Resources/SketchPaper.png "$guide_dir/Preview.app/Contents/Resources/"
python3 - "$guide_repo" "$guide_dir" <<'PY'
from pathlib import Path
import sys
root, out = map(Path, sys.argv[1:])
s = (root / 'Sources/MacOSX/WindowSwitcher/WindowInventory.swift').read_text()
(out/'SwitcherWindow.swift').write_text(s[:s.index('struct WindowInventorySnapshot')])
g=(root/'Sources/MacOSX/Shared/GlobalInput.swift').read_text()
(out/'ShortcutTypes.swift').write_text(g[:g.index('private enum InputAction')]+g[g.index('extension ShortcutBinding'):])
t=(root/'Sources/MacOSX/UI/ToolboxWindowController.swift').read_text()
(out/'RegistryAndFixture.swift').write_text(t[:t.index('@MainActor\nprivate final class CardGrid')]+(root/'tools/settings-switcher-regression.swift').read_text())
(out/'Preview.app/Contents/Info.plist').write_text('<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>cc.anjing.macos-x.settings.fixture</string><key>CFBundleExecutable</key><string>Preview</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>')
PY
xcrun swiftc -I "$guide_bin/Modules" "$guide_bin"/MacOSXCore.build/*.swift.o \
 Sources/MacOSX/UI/SketchTheme.swift Sources/MacOSX/UI/SketchIcons.swift Sources/MacOSX/UI/ToolCard.swift Sources/MacOSX/UI/MinimalControls.swift Sources/MacOSX/UI/ModuleCatalogView.swift \
 Sources/MacOSX/Shared/ShortcutSettings.swift Sources/MacOSX/Capture/RecordingPresentation.swift Sources/MacOSX/UI/SettingsGuideView.swift Sources/MacOSX/UI/SettingsBoardView.swift Sources/MacOSX/WindowSwitcher/SwitcherPanel.swift \
 Sources/MacOSX/WindowLayout/*.swift \
 "$guide_dir/SwitcherWindow.swift" "$guide_dir/ShortcutTypes.swift" "$guide_dir/RegistryAndFixture.swift" \
 -o "$guide_dir/Preview.app/Contents/MacOS/Preview"
"$guide_dir/Preview.app/Contents/MacOS/Preview"
