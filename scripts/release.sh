#!/bin/bash
set -euo pipefail

if [[ "${1:-}" == "--help" ]]; then
    echo "Usage: scripts/release.sh [MacOSX.app] [output-directory]"
    echo "Prepare a complete update archive, signed appcast and SHA-256 file; do not upload."
    echo "Signing key: login Keychain account macos-x (override MACOSX_SPARKLE_ACCOUNT)."
    exit 0
fi

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${1:-$root_dir/dist/MacOSX.app}"
release_dir="${2:-$root_dir/dist/releases}"
keychain_account="${MACOSX_SPARKLE_ACCOUNT:-macos-x}"
[[ $# -le 2 ]] || { echo "Usage: scripts/release.sh [MacOSX.app] [output-directory]" >&2; exit 1; }
[[ -d "$app" && -f "$app/Contents/Info.plist" ]] || { echo "Build MacOSX.app first" >&2; exit 1; }

/usr/bin/codesign --verify --deep --strict "$app"
# Read release metadata and enforce that this is an update-enabled application.
version="$(python3 - "$app/Contents/Info.plist" "$root_dir/Resources/update-public-key.txt" <<'PY'
import pathlib, plistlib, re, sys, urllib.parse
with open(sys.argv[1], 'rb') as source:
    info = plistlib.load(source)
key = pathlib.Path(sys.argv[2]).read_text().strip()
if info.get('MacOSXUpdatesEnabled') is not True or info.get('SUPublicEDKey') != key:
    raise SystemExit('Release requires an OTA-enabled app containing the repository public key')
if (info.get('SUVerifyUpdateBeforeExtraction') is not True
    or info.get('SURequireSignedFeed') is not True
    or info.get('SUSignedFeedFailureExpirationInterval') != 0
    or info.get('SUAllowsAutomaticUpdates') is not False):
    raise SystemExit('Release does not enforce signed updates and user-confirmed installation')
version, build = info['CFBundleShortVersionString'], info['CFBundleVersion']
if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version) or not re.fullmatch(r'[1-9][0-9]*', build):
    raise SystemExit('Invalid release version or build number')
url = urllib.parse.urlparse(info.get('SUFeedURL', ''))
if url.scheme != 'https' or not url.hostname or url.username or url.password:
    raise SystemExit('Invalid HTTPS appcast URL')
print(version)
PY
)"
archive_name="macos-x-$version.zip"
download_prefix="https://github.com/anjing-le/macos-x/releases/download/v$version/"
tools_dir="$root_dir/.build/artifacts/sparkle/Sparkle/bin"
[[ -x "$tools_dir/sign_update" ]] || { echo "Sparkle signing tool missing; run swift package --disable-keychain resolve" >&2; exit 1; }
mkdir -p "$release_dir"
release_dir="$(cd "$release_dir" && pwd)"
archive="$release_dir/$archive_name"
[[ ! -e "$archive" ]] || { echo "Release archive already exists: $archive. Use a new version or output directory." >&2; exit 1; }

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
# Sparkle retrieves the private key from login Keychain; it never enters arguments.
signature="$("$tools_dir/sign_update" --account "$keychain_account" -p "$archive")"
swift "$root_dir/scripts/verify-update.swift" "$archive" "$signature" "$root_dir/Resources/update-public-key.txt"

# A single stable update item is sufficient. Sparkle's official tool owns the
# feed signature format; this XML writer only describes the signed archive.
python3 - "$app" "$archive" "$download_prefix$archive_name" "$signature" "$release_dir/appcast.xml" <<'PY'
import base64, datetime, email.utils, pathlib, plistlib, re, subprocess, sys
import xml.etree.ElementTree as ET
app, archive, download_url, signature, feed_path = sys.argv[1:]
with open(pathlib.Path(app) / 'Contents/Info.plist', 'rb') as source:
    info = plistlib.load(source)
if len(base64.b64decode(signature, validate=True)) != 64:
    raise SystemExit('Invalid archive Ed25519 signature')
minimum_os = info.get('LSMinimumSystemVersion', '')
if not re.fullmatch(r'[0-9]+(?:\.[0-9]+){0,2}', minimum_os):
    raise SystemExit('Invalid app minimum macOS version')
minimum_os = '.'.join((minimum_os.split('.') + ['0', '0'])[:3])
executable = pathlib.Path(app) / 'Contents/MacOS' / info['CFBundleExecutable']
architectures = subprocess.check_output(['/usr/bin/lipo', '-archs', str(executable)], text=True).split()
if set(architectures) not in ({'arm64'}, {'arm64', 'x86_64'}):
    raise SystemExit('Release supports Apple Silicon or universal apps; other architecture feeds need explicit planning')
namespace_url = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', namespace_url)
namespace = '{' + namespace_url + '}'
rss = ET.Element('rss', {'version': '2.0'})
channel = ET.SubElement(rss, 'channel')
ET.SubElement(channel, 'title').text = 'macos-x'
ET.SubElement(channel, 'link').text = 'https://github.com/anjing-le/macos-x'
ET.SubElement(channel, 'description').text = 'macos-x stable updates'
item = ET.SubElement(channel, 'item')
ET.SubElement(item, 'title').text = 'macos-x ' + info['CFBundleShortVersionString']
ET.SubElement(item, namespace + 'version').text = info['CFBundleVersion']
ET.SubElement(item, namespace + 'shortVersionString').text = info['CFBundleShortVersionString']
ET.SubElement(item, namespace + 'minimumSystemVersion').text = minimum_os
if architectures == ['arm64']:
    ET.SubElement(item, namespace + 'hardwareRequirements').text = 'arm64'
ET.SubElement(item, 'pubDate').text = email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc), usegmt=True)
ET.SubElement(item, 'enclosure', {
    'url': download_url,
    'length': str(pathlib.Path(archive).stat().st_size),
    'type': 'application/octet-stream',
    namespace + 'edSignature': signature,
})
tree = ET.ElementTree(rss)
ET.indent(tree, space='  ')
tree.write(feed_path, encoding='utf-8', xml_declaration=True)
PY
"$tools_dir/sign_update" --account "$keychain_account" "$release_dir/appcast.xml"
"$tools_dir/sign_update" --account "$keychain_account" --verify "$release_dir/appcast.xml"
(cd "$release_dir" && /usr/bin/shasum -a 256 "$archive_name" > "$archive_name.sha256")
echo "Prepared and signature-verified: $archive"
echo "Appcast: $release_dir/appcast.xml"
echo "Nothing uploaded. Publish both files as assets of GitHub release v$version after review."
echo "Ed25519 archive signing is not Apple Developer ID signing or notarization."
