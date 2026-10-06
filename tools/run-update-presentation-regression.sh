#!/bin/zsh
set -euo pipefail
update_repo="$(cd "$(dirname "$0")/.." && pwd)"
update_check_dir="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-update-presentation.XXXXXX")"
trap 'rm -rf "$update_check_dir"' EXIT
python3 - "$update_repo" "$update_check_dir" <<'PY'
from pathlib import Path
import sys
source, destination = map(Path, sys.argv[1:])
text = (source / 'Sources/MacOSX/Updates/UpdateUserDriver.swift').read_text()
(destination / 'UpdateUserDriver.swift').write_text(text.replace('import Sparkle\n', ''))
PY
xcrun swiftc "$update_check_dir/UpdateUserDriver.swift" "$update_repo/tools/update-presentation-regression.swift" -o "$update_check_dir/regression"
"$update_check_dir/regression"
