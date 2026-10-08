#!/bin/zsh
set -euo pipefail
menu_repo="$(cd "$(dirname "$0")/.." && pwd)"
menu_dir="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-menu-bar.XXXXXX")"
trap 'rm -rf "$menu_dir"' EXIT
xcrun swiftc "$menu_repo/Sources/MacOSX/Shared/MenuBarController.swift" \
 "$menu_repo/tools/menu-bar-regression.swift" -o "$menu_dir/menu-bar-regression"
"$menu_dir/menu-bar-regression"
