#!/bin/zsh
set -euo pipefail
menu_repo="$(cd "$(dirname "$0")/.." && pwd)"
menu_temp="$(mktemp -d "${TMPDIR:-/tmp/}native-menu-bar.XXXXXX")"
trap 'rm -rf "$menu_temp"' EXIT
cd "$menu_repo"
swift build --disable-keychain --target MenuBarVisibilityBridge
menu_bin="$(swift build --disable-keychain --show-bin-path)"
cat Sources/MacOSX/MenuBarShelf/MenuBarNativeShelf.swift tools/native-menu-bar-regression.swift > "$menu_temp/NativeShelfAndFixture.swift"
xcrun swiftc -parse-as-library -Xcc "-fmodule-map-file=$menu_bin/MenuBarVisibilityBridge.build/module.modulemap" \
 -I Sources/MenuBarVisibilityBridge/include "$menu_bin"/MenuBarVisibilityBridge.build/*.o \
 Sources/MacOSX/MenuBarShelf/MenuBarVisibility.swift \
 Sources/MacOSX/MenuBarShelf/MenuBarInventory.swift \
 Sources/MacOSX/MenuBarShelf/MenuBarBoundaryGrouping.swift \
 "$menu_temp/NativeShelfAndFixture.swift" \
 -o "$menu_temp/regression"
"$menu_temp/regression"
python3 - <<'PY'
from pathlib import Path
root = Path('Sources/MacOSX/MenuBarShelf')
source = (root / 'MenuBarNativeShelf.swift').read_text()
for forbidden in ('CGEvent.tapCreate', 'CGEvent(mouseEventSource:', '.post(tap:', 'AXUIElementPerformAction', 'SCStream(', 'SCScreenshotManager', 'doubleClickInterval', 'CGWarpMouseCursorPosition'):
    assert forbidden not in source, forbidden
module = (root / 'MenuBarShelfModule.swift').read_text()
for forbidden in ('MenuBarDrawer(', '.openMenu(', '.onActivate', '.replay('):
    assert forbidden not in module, forbidden
assert 'self?.observe(event); return event' in source
print('PASS runtime wiring: native events pass through; proxy capture/replay is disconnected')
PY
