#!/bin/zsh
set -euo pipefail
layout_root="$(cd "$(dirname "$0")/.." && pwd)"
layout_dir="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-layout.XXXXXX")"
trap 'rm -rf "$layout_dir"' EXIT
cd "$layout_root"
swift build --disable-keychain --target MacOSXCore
layout_bin="$(swift build --disable-keychain --show-bin-path)"
xcrun swiftc -I "$layout_bin/Modules" "$layout_bin"/MacOSXCore.build/*.swift.o \
 Sources/MacOSX/UI/SketchTheme.swift Sources/MacOSX/UI/MinimalControls.swift \
 Sources/MacOSX/WindowLayout/*.swift \
 tools/window-layout-regression.swift -o "$layout_dir/check"
"$layout_dir/check"
