#!/bin/bash
set -euo pipefail
pair_root="$(cd "$(dirname "$0")/.." && pwd)"
pair_initial=false
if [[ "${1:-}" == --initial-intel-release ]]; then pair_initial=true; shift; fi
[[ $# == 3 ]] || { echo 'Usage: release-pair.sh [--initial-intel-release] arm64.app intel.app output-directory' >&2; exit 1; }
pair_arm="$1"; pair_intel="$2"; pair_output="$3"
[[ -n "${MACOSX_PREVIOUS_ARM_APP:-}" ]] || { echo 'Set MACOSX_PREVIOUS_ARM_APP to the actual previous signed ARM release' >&2; exit 1; }
if [[ "$pair_initial" != true ]]; then
    [[ -n "${MACOSX_PREVIOUS_INTEL_APP:-}" ]] || { echo 'Set MACOSX_PREVIOUS_INTEL_APP, or explicitly bootstrap the first Intel release' >&2; exit 1; }
fi
[[ ! -e "$pair_output" ]] || { echo 'Choose a fresh paired output directory' >&2; exit 1; }
python3 "$pair_root/tools/verify-bundle-architecture.py" "$pair_arm" --expected arm64
python3 "$pair_root/tools/verify-bundle-architecture.py" "$pair_intel" --expected x86_64
python3 - "$pair_arm" "$pair_intel" <<'PY'
import pathlib,plistlib,sys
infos=[plistlib.loads((pathlib.Path(x)/'Contents/Info.plist').read_bytes()) for x in sys.argv[1:]]
for key in ['CFBundleIdentifier','CFBundleShortVersionString','CFBundleVersion','LSMinimumSystemVersion','SUPublicEDKey']:
    assert infos[0].get(key) and infos[0][key]==infos[1].get(key), 'Paired apps differ: '+key
PY
MACOSX_PREVIOUS_APP="$MACOSX_PREVIOUS_ARM_APP" "$pair_root/scripts/release.sh" "$pair_arm" "$pair_output/arm64"
if [[ "$pair_initial" == true ]]; then
    MACOSX_PREVIOUS_APP="$MACOSX_PREVIOUS_ARM_APP" "$pair_root/scripts/release.sh" --initial-intel-release "$pair_intel" "$pair_output/x86_64"
else
    MACOSX_PREVIOUS_APP="$MACOSX_PREVIOUS_INTEL_APP" "$pair_root/scripts/release.sh" "$pair_intel" "$pair_output/x86_64"
fi
python3 - "$pair_output" <<'PY'
import pathlib,shutil,sys
out=pathlib.Path(sys.argv[1])
for arch in ['arm64','x86_64']:
    for file in (out/arch).iterdir():
        assert file.is_file() and not (out/file.name).exists()
        shutil.copy2(file,out/file.name)
PY
python3 "$pair_root/tools/write-download-manifest.py" "$pair_arm" "$pair_intel" "$pair_output"
echo "Prepared both native architectures and separately signed feeds: $pair_output"
