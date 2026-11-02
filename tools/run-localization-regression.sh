#!/bin/zsh
set -euo pipefail
source "$(dirname "$0")/localization/fixture-core.sh"
localization_tmp="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-localization.XXXXXX")"
trap 'rm -rf "$localization_tmp"' EXIT
mkdir -p "$localization_tmp/Preview.app/Contents/MacOS" "$localization_tmp/Preview.app/Contents/Resources"
cp "$localization_repo/Resources/SketchFont.ttf" "$localization_tmp/Preview.app/Contents/Resources/"
python3 - "$localization_repo" "$localization_tmp" <<'PYTHON'
from pathlib import Path
import sys
root,out=map(Path,sys.argv[1:])
(out/'RecordingAudioOptions.swift').write_text((root/'Sources/MacOSX/Capture/RecordingAudio.swift').read_text().split('/// One fixed-size')[0])
PYTHON
xcrun swiftc -I "$localization_bin/Modules" "$localization_bin"/MacOSXCore.build/*.swift.o \
 "$localization_repo/Sources/MacOSX/UI/SketchTheme.swift" \
 "$localization_repo/Sources/MacOSX/UI/MinimalControls.swift" \
 "$localization_tmp/RecordingAudioOptions.swift" \
 "$localization_repo/Sources/MacOSX/Capture/RecordingStartBar.swift" \
 "$localization_repo/tools/localization/recording-regression.swift" \
 -o "$localization_tmp/Preview.app/Contents/MacOS/Preview"
MACOSX_TEST_LANGUAGE=en "$localization_tmp/Preview.app/Contents/MacOS/Preview"
MACOSX_TEST_LANGUAGE=zh "$localization_tmp/Preview.app/Contents/MacOS/Preview"
