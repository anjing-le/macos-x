#!/bin/zsh
set -euo pipefail
source "$(dirname "$0")/localization/fixture-core.sh"
menu_repo="$(cd "$(dirname "$0")/.." && pwd)"
menu_dir="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-menu-bar.XXXXXX")"
trap 'rm -rf "$menu_dir"' EXIT
xcrun swiftc -I "$localization_bin/Modules" "$localization_bin"/MacOSXCore.build/*.swift.o "$menu_repo/Sources/MacOSX/Shared/MenuBarController.swift" \
 "$menu_repo/tools/menu-bar-regression.swift" -o "$menu_dir/menu-bar-regression"
"$menu_dir/menu-bar-regression"
