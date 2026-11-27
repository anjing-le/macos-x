#!/usr/bin/env python3
"""Verify two real signed app bundles share the production update identity.

This proves code identity compatibility, not a TCC grant or successful OTA.
"""
import argparse
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


def allows_initial_intel_feed(old_feed, new_feed, old_arch, new_arch, explicit):
    prefix = 'https://github.com/anjing-le/macos-x/releases/latest/download/'
    return (explicit and set(old_arch) == {'arm64'} and set(new_arch) == {'x86_64'}
            and old_feed == prefix+'appcast.xml' and new_feed == prefix+'appcast-intel.xml')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('previous', type=pathlib.Path)
    parser.add_argument('candidate', type=pathlib.Path)
    parser.add_argument('--initial-intel-release', action='store_true')
    args = parser.parse_args()
    previous, candidate = args.previous, args.candidate
    old_requirement, old = inspect(previous)
    new_requirement, new = inspect(candidate)
    # Checking both actual binaries is stronger than comparing requirement text.
    for app, requirement in [(candidate, old_requirement), (previous, new_requirement)]:
        subprocess.run(['codesign', '--verify', '--strict', '--test-requirement', '=' + requirement,
                        str(app)], check=True)
    for key in ['CFBundleIdentifier', 'CFBundleExecutable', 'SUPublicEDKey']:
        if not old.get(key) or old[key] != new.get(key):
            raise ValueError(f'Update identity/configuration changed: {key}')
    initial_intel = False
    if old.get('SUFeedURL') != new.get('SUFeedURL'):
        old_arch = set(subprocess.check_output(['lipo', '-archs', str(previous/'Contents/MacOS'/old['CFBundleExecutable'])], text=True).split())
        new_arch = set(subprocess.check_output(['lipo', '-archs', str(candidate/'Contents/MacOS'/new['CFBundleExecutable'])], text=True).split())
        initial_intel = allows_initial_intel_feed(old.get('SUFeedURL'), new.get('SUFeedURL'), old_arch, new_arch, args.initial_intel_release)
        if not initial_intel:
            raise ValueError('Update feed changed without an explicit first-Intel bootstrap')
    elif not old.get('SUFeedURL'):
        raise ValueError('Missing previous update feed')
    elif args.initial_intel_release:
        raise ValueError('First-Intel exception is only valid for the initial ARM-to-Intel channel setup')
    if int(new['CFBundleVersion']) <= int(old['CFBundleVersion']):
        raise ValueError('Candidate build must be newer than the previous release')
    print('PASS: mutual signing requirements, production identifier, OTA key and increasing build')
    print('First Intel channel bootstrap only; no previous Intel upgrade or runtime is implied.' if initial_intel else 'PASS: update feed unchanged')
    print('TCC authorization and permission retention across OTA still require real app verification.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
