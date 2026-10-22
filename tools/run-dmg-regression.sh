#!/bin/zsh
set -euo pipefail
installer_root="$(cd "$(dirname "$0")/.." && pwd)"
[[ $# == 1 ]] || { echo 'Usage: tools/run-dmg-regression.sh MacOSX.app' >&2; exit 1; }
installer_app="$(cd "$1" && pwd)"
installer_test="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-dmg-regression.XXXXXX")"
trap 'rm -rf "$installer_test"' EXIT
"$installer_root/scripts/build-dmg.sh" "$installer_app" "$installer_test"
installer_python="$("$installer_root/scripts/installer/prepare-tools.sh")"
installer_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$installer_app/Contents/Info.plist")"
"$installer_python" "$installer_root/tools/verify-dmg.py" "$installer_test/macos-x-$installer_version.dmg" "$installer_app"
