#!/bin/bash
set -euo pipefail
installer_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
installer_python="${DMG_PYTHON:-python3}"
"$installer_python" -c 'import sys; assert sys.version_info >= (3, 10), "DMG packaging needs Python 3.10+; set DMG_PYTHON to its executable"'
installer_tools="$installer_root/.build/installer-tools"
installer_requirements="$installer_root/scripts/installer/requirements.txt"
installer_hash="$(shasum -a 256 "$installer_requirements" | cut -d ' ' -f 1)"
if [[ ! -x "$installer_tools/bin/python" ]]; then "$installer_python" -m venv "$installer_tools"; fi
if [[ ! -f "$installer_tools/requirements.sha256" ]] || [[ "$(cat "$installer_tools/requirements.sha256")" != "$installer_hash" ]]; then
    "$installer_tools/bin/python" -m pip --isolated install --index-url https://pypi.org/simple --disable-pip-version-check --only-binary=:all: --require-hashes -r "$installer_requirements" >&2
    printf '%s\n' "$installer_hash" > "$installer_tools/requirements.sha256"
fi
printf '%s\n' "$installer_tools/bin/python"
