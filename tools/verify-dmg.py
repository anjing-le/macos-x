#!/usr/bin/env python3
"""Inspect real mounted media and copy into a disposable Applications folder."""
import hashlib
import json
import os
import plistlib
import subprocess
import sys
import tempfile
from pathlib import Path
from ds_store import DSStore
from mac_alias import Alias

image, original = (Path(arg).resolve() for arg in sys.argv[1:3])
root = Path(__file__).resolve().parents[1]
layout = json.loads((root / 'scripts/installer/layout.json').read_text())
subprocess.run(['/usr/bin/hdiutil', 'verify', str(image)], check=True, stdout=subprocess.DEVNULL)
checksum = image.with_name(image.name + '.sha256').read_text().split()[0]
assert checksum == hashlib.sha256(image.read_bytes()).hexdigest()

def fingerprint(app):
    result = {}
    for parent, dirs, files in os.walk(app, followlinks=False):
        for name in dirs + files:
            path = Path(parent) / name
            relative = str(path.relative_to(app))
            if path.is_symlink():
                result[relative] = ('link', os.readlink(path))
            elif path.is_file():
                result[relative] = ('file', hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_mode & 0o777)
    return result

expected = fingerprint(original)
expected_info = plistlib.loads((original / 'Contents/Info.plist').read_bytes())
with tempfile.TemporaryDirectory(prefix='macos-x-dmg-check-') as temporary:
    temp = Path(temporary)
    mount = temp / 'mount'
    mount.mkdir()
    for iteration in range(2):
        mounted = False
        try:
            subprocess.run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', str(mount), str(image)], check=True, stdout=subprocess.DEVNULL)
            mounted = True
            assert sorted(p.name for p in mount.iterdir() if not p.name.startswith('.')) == ['Applications', 'MacOSX.app']
            assert (mount / 'Applications').is_symlink() and os.readlink(mount / 'Applications') == '/Applications'
            assert (mount / '.metadata_never_index').is_file()
            media = plistlib.loads(subprocess.check_output(['/usr/sbin/diskutil', 'info', '-plist', str(mount)]))
            assert os.statvfs(mount).f_flag & os.ST_RDONLY
            assert media.get('FilesystemType') == 'apfs'
            with DSStore.open(str(mount / '.DS_Store'), 'r') as metadata:
                assert metadata['MacOSX.app']['Iloc'] == tuple(layout['app'])
                assert metadata['Applications']['Iloc'] == tuple(layout['applications'])
                window, view = metadata['.']['bwsp'], metadata['.']['icvp']
                assert window['WindowBounds'] == '{{%s, %s}, {%s, %s}}' % (*layout['windowOrigin'], layout['width'], layout['height'])
                assert not any(window[key] for key in ['ShowToolbar', 'ShowStatusBar', 'ShowPathbar', 'ShowSidebar', 'ShowTabView'])
                assert view['iconSize'] == layout['iconSize'] and view['arrangeBy'] == 'none'
                assert view['backgroundType'] == 2
                background = Alias.from_bytes(view['backgroundImageAlias']).target.filename
                assert background == '.background.tiff' and (mount / background).is_file()
                assert (mount / background).stat().st_size > 0
            application = mount / 'MacOSX.app'
            assert fingerprint(application) == expected
            assert plistlib.loads((application / 'Contents/Info.plist').read_bytes()) == expected_info
            subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(application)], check=True)
            copied = temp / ('copy-%s.noindex' % iteration) / 'Applications/MacOSX.app'
            copied.parent.mkdir(parents=True)
            subprocess.run(['/usr/bin/ditto', str(application), str(copied)], check=True)
            assert fingerprint(copied) == expected
            subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(copied)], check=True)
            if subprocess.run(['/bin/sh', '-c', 'touch "$1"', 'check-read-only', str(mount / '.write-probe')], capture_output=True).returncode == 0:
                raise AssertionError('Installer volume was writable')
        finally:
            if mounted:
                subprocess.run(['/usr/bin/hdiutil', 'detach', str(mount)], check=True, stdout=subprocess.DEVNULL)
print(json.dumps({'version': expected_info['CFBundleShortVersionString'], 'build': expected_info['CFBundleVersion'], 'repeatMounts': 2, 'readOnly': True, 'nativeFinderPositions': True, 'backgroundAliasResolves': True, 'applicationBytesAndSignaturePreserved': True, 'temporaryInstallCopiesVerified': True, 'actualApplicationsUntouched': True}, ensure_ascii=False))
