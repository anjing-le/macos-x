#!/usr/bin/env python3
"""Verify two real signed app bundles share the production update identity.

This proves code identity compatibility, not a TCC grant or successful OTA.
"""
import pathlib
import plistlib
import re
import subprocess
import sys


def inspect(app):
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    result = subprocess.run(['codesign', '--display', '--verbose=4', '--requirements', '-', str(app)],
                            capture_output=True, text=True, check=True)
    text = result.stdout + result.stderr
    requirement = re.search(r'^designated => (.+)$', text, re.MULTILINE)
    if requirement is None or 'cdhash' in requirement.group(1) or 'Signature=adhoc' in text:
        raise ValueError(f'{app}: identity is missing or bound to a single build')
    with (app / 'Contents/Info.plist').open('rb') as file:
        info = plistlib.load(file)
    if info.get('CFBundleIdentifier') != 'cc.anjing.macos-x':
        raise ValueError(f'{app}: unexpected application identifier')
    return requirement.group(1), info


def main():
    if len(sys.argv) != 3:
        raise ValueError('Usage: verify-update-identity.py previous.app candidate.app')
    previous, candidate = (pathlib.Path(value) for value in sys.argv[1:])
    old_requirement, old = inspect(previous)
    new_requirement, new = inspect(candidate)
    # Checking both actual binaries is stronger than comparing requirement text.
    for app, requirement in [(candidate, old_requirement), (previous, new_requirement)]:
        subprocess.run(['codesign', '--verify', '--strict', '--test-requirement', '=' + requirement,
                        str(app)], check=True)
    for key in ['CFBundleIdentifier', 'CFBundleExecutable', 'SUPublicEDKey', 'SUFeedURL']:
        if not old.get(key) or old[key] != new.get(key):
            raise ValueError(f'Update identity/configuration changed: {key}')
    if int(new['CFBundleVersion']) <= int(old['CFBundleVersion']):
        raise ValueError('Candidate build must be newer than the previous release')
    print('PASS: mutual signing requirements, production identifier, OTA key/feed and increasing build')
    print('TCC authorization and permission retention across OTA still require real app verification.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
