#!/bin/bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
app="${1:-$root_dir/dist/MacOSX.app}"
release_dir="${2:-$root_dir/dist/releases}"
keychain_account="${MACOSX_SPARKLE_ACCOUNT:-macos-x}"
[[ $# -le 2 ]] || { echo "Usage: scripts/release.sh [MacOSX.app] [output-directory]" >&2; exit 1; }
[[ -d "$app" && -f "$app/Contents/Info.plist" ]] || { echo "Build MacOSX.app first" >&2; exit 1; }

/usr/bin/codesign --verify --deep --strict "$app"
# Read release metadata and enforce that this is an update-enabled application.
metadata="$(python3 - "$app/Contents/Info.plist" "$root_dir/Resources/update-public-key.txt" <<'PY'
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
print(build)
PY
)"
version="$(echo "$metadata" | sed -n '1p')"
build_number="$(echo "$metadata" | sed -n '2p')"
archive_name="macos-x-$version.zip"
download_prefix="https://github.com/anjing-le/macos-x/releases/download/v$version/"
tools_dir="$root_dir/.build/artifacts/sparkle/Sparkle/bin"
[[ -x "$tools_dir/generate_appcast" ]] || { echo "Sparkle tools missing; run swift package --disable-keychain resolve" >&2; exit 1; }
mkdir -p "$release_dir"
release_dir="$(cd "$release_dir" && pwd)"
archive="$release_dir/$archive_name"
[[ ! -e "$archive" ]] || { echo "Release archive already exists: $archive. Use a new version or output directory." >&2; exit 1; }

/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$archive"
# Sparkle retrieves the private key from login Keychain; it never enters arguments.
"$tools_dir/generate_appcast" --account "$keychain_account" \
    --download-url-prefix "$download_prefix" --versions "$build_number" \
    --maximum-deltas 0 -o "$release_dir/appcast.xml" "$release_dir"
"$tools_dir/sign_update" --account "$keychain_account" --verify "$release_dir/appcast.xml"

signature="$(python3 - "$release_dir/appcast.xml" "$archive" "$download_prefix$archive_name" "$build_number" <<'PY'
import os, sys, xml.etree.ElementTree as ET
feed, archive, expected_url, expected_build = sys.argv[1:]
namespace = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
matches = [item for item in ET.parse(feed).getroot().findall('./channel/item')
           if item.findtext(namespace + 'version') == expected_build]
if len(matches) != 1:
    raise SystemExit('Generated appcast does not contain exactly one matching build')
enclosure = matches[0].find('enclosure')
if enclosure is None or enclosure.get('url') != expected_url or enclosure.get('length') != str(os.path.getsize(archive)):
    raise SystemExit('Generated appcast URL or archive length is incorrect')
signature = enclosure.get(namespace + 'edSignature')
if not signature:
    raise SystemExit('Unsigned update rejected')
print(signature)
PY
)"
swift "$root_dir/scripts/verify-update.swift" "$archive" "$signature" "$root_dir/Resources/update-public-key.txt"
(cd "$release_dir" && /usr/bin/shasum -a 256 "$archive_name" > "$archive_name.sha256")
echo "Prepared and signature-verified: $archive"
echo "Appcast: $release_dir/appcast.xml"
echo "Nothing uploaded. Publish both files as assets of GitHub release v$version after review."
echo "Ed25519 archive signing is not Apple Developer ID signing or notarization."
