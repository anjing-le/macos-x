#!/bin/bash
set -euo pipefail
file_actions_root="$(cd "$(dirname "$0")/.." && pwd)"
command -v cargo >/dev/null || { echo "Rust 1.88+ is required to build the pinned local document engine." >&2; exit 1; }
file_actions_target_args=()
if [[ $# -gt 0 ]]; then
    [[ $# == 2 && "$1" == --target ]] || { echo 'Usage: build-file-document-worker.sh [--target aarch64-apple-darwin|x86_64-apple-darwin]' >&2; exit 1; }
    case "$2" in aarch64-apple-darwin|x86_64-apple-darwin) ;; *) echo 'Unsupported document worker target' >&2; exit 1 ;; esac
    file_actions_target_args=(--target "$2")
fi
if [[ ${#file_actions_target_args[@]} == 0 ]]; then
    MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --locked --release --manifest-path "$file_actions_root/vendor/file-actions/Cargo.toml"
else
    MACOSX_DEPLOYMENT_TARGET=14.0 cargo build --locked --release "${file_actions_target_args[@]}" --manifest-path "$file_actions_root/vendor/file-actions/Cargo.toml"
fi
python3 - "$file_actions_root" <<'PY'
import json,pathlib,subprocess,sys
root=pathlib.Path(sys.argv[1]);manifest=root/'vendor/file-actions/Cargo.toml'
meta=json.loads(subprocess.check_output(['cargo','metadata','--locked','--format-version','1','--manifest-path',str(manifest)],text=True))
notices=[]
for package in sorted(meta['packages'],key=lambda p:p['name']):
    if package['name']=='file-document-worker':continue
    folder=pathlib.Path(package['manifest_path']).parent
    notices.append(package['name']+' '+package['version']+' ('+str(package.get('license') or 'see included license')+')\n'+str(package.get('repository') or 'https://crates.io/crates/'+package['name']))
    files=sorted(p for p in folder.iterdir() if p.is_file() and p.name.upper().startswith(('LICENSE','COPYING','NOTICE')))
    for p in files:notices.append(p.read_text(errors='replace'))
    if not files:raise SystemExit('License text missing: '+package['name'])
(root/'vendor/file-actions/target/THIRD_PARTY_NOTICES.txt').write_text('\n\n'.join(notices))
PY
