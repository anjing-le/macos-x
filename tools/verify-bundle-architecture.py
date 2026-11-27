#!/usr/bin/env python3
"""Check main app, both workers and every nested Mach-O before distribution."""
import argparse, json, pathlib, plistlib, subprocess


def architectures(path):
    return set(subprocess.check_output(['/usr/bin/lipo', '-archs', str(path)], text=True).split())


def inspect(app, expected=None):
    app = pathlib.Path(app)
    with (app/'Contents/Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    primary = app/'Contents/MacOS'/info['CFBundleExecutable']
    found = architectures(primary)
    if len(found) != 1 or not found <= {'arm64', 'x86_64'}:
        raise ValueError('Distribute a dedicated arm64 or x86_64 application')
    architecture = next(iter(found))
    if expected is not None and architecture != expected:
        raise ValueError('Application architecture does not match requested build')
    if info.get('MacOSXArchitecture', architecture) != architecture:
        raise ValueError('Declared architecture does not match the actual executable')
    for worker in ['FileActionsWorker', 'FileDocumentWorker']:
        if architectures(app/'Contents/Helpers'/worker) != found:
            raise ValueError('Wrong architecture for bundled worker: '+worker)
    magic = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}
    binaries = []
    for path in app.rglob('*'):
        if not path.is_file() or path.is_symlink(): continue
        with path.open('rb') as stream: header = stream.read(4)
        if header in magic:
            if architecture not in architectures(path):
                raise ValueError('Nested Mach-O cannot run on '+architecture+': '+str(path.relative_to(app)))
            binaries.append(str(path.relative_to(app)))
    return dict(architecture=architecture, version=info['CFBundleShortVersionString'], build=info['CFBundleVersion'],
                minimumSystemVersion=info['LSMinimumSystemVersion'], machOCount=len(binaries), binaries=binaries)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app'); parser.add_argument('--expected', choices=['arm64','x86_64']); parser.add_argument('--print', action='store_true', dest='plain')
    args = parser.parse_args()
    try:
        result = inspect(args.app, args.expected)
        print(result['architecture'] if args.plain else json.dumps(result, sort_keys=True))
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, str(error)+'\n')
