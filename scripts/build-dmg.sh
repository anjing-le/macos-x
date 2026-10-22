#!/bin/bash
set -euo pipefail
installer_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ $# == 2 ]] || { echo 'Usage: scripts/build-dmg.sh MacOSX.app output-directory' >&2; exit 1; }
installer_app="$(cd "$1" && pwd)"
[[ "$(basename "$installer_app")" == MacOSX.app ]] || { echo 'Expected MacOSX.app' >&2; exit 1; }
/usr/bin/codesign --verify --deep --strict "$installer_app"
installer_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$installer_app/Contents/Info.plist")"
[[ "$installer_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo 'Unexpected app version' >&2; exit 1; }
mkdir -p "$2"
installer_output="$(cd "$2" && pwd)"
installer_image="$installer_output/macos-x-$installer_version.dmg"
[[ ! -e "$installer_image" ]] || { echo 'DMG already exists; choose a fresh output directory.' >&2; exit 1; }
installer_work="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-installer.XXXXXX")"
trap 'rm -rf "$installer_work"' EXIT
installer_python="$("$installer_root/scripts/installer/prepare-tools.sh")"
xcrun swiftc -parse-as-library "$installer_root/Sources/MacOSX/UI/SketchTheme.swift" "$installer_root/scripts/installer/render.swift" -o "$installer_work/render"
"$installer_work/render" "$installer_root/Resources" "$installer_root/scripts/installer/layout.json" "$installer_work/artwork"
"$installer_python" -m dmgbuild -s "$installer_root/scripts/installer/settings.py" -D "app=$installer_app" -D "artwork=$installer_work/artwork" -D "layout=$installer_root/scripts/installer/layout.json" "macos-x 安装" "$installer_work/package.dmg"
/usr/bin/hdiutil verify "$installer_work/package.dmg" >/dev/null
mv "$installer_work/package.dmg" "$installer_image"
(cd "$installer_output" && /usr/bin/shasum -a 256 "$(basename "$installer_image")" > "$(basename "$installer_image").sha256")
echo "Prepared DMG: $installer_image"
