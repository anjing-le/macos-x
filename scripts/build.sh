#!/bin/bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration=release
output_dir="$root_dir/dist"
version=0.0.4
build_number=6
sign_identity="${MACOSX_SIGN_IDENTITY:--}"
updates_enabled=true
feed_url="${MACOSX_FEED_URL:-https://github.com/anjing-le/macos-x/releases/latest/download/appcast.xml}"

usage() {
    cat <<'USAGE'
Usage: scripts/build.sh [--disable-updates] [--configuration debug|release]
       [--version 0.0.4] [--build-number 6] [--output-dir path]
       [--sign-identity "Developer ID Application: ..."]
Default: host architecture, OTA enabled, local ad hoc signing.
Set MACOSX_FEED_URL at build time for an alternate HTTPS appcast.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --disable-updates) updates_enabled=false; shift ;;
        --configuration|--version|--build-number|--output-dir|--sign-identity)
            [[ $# -ge 2 && -n "$2" ]] || { echo "Missing value for $1" >&2; exit 1; }
            case "$1" in
                --configuration) configuration="$2" ;;
                --version) version="$2" ;;
                --build-number) build_number="$2" ;;
                --output-dir) output_dir="$2" ;;
                --sign-identity) sign_identity="$2" ;;
            esac
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done
[[ "$configuration" == release || "$configuration" == debug ]] || { echo "Invalid configuration" >&2; exit 1; }

# Validate before compiling: an OTA-enabled build requires a real public key.
python3 - "$root_dir/Resources/update-public-key.txt" "$feed_url" "$version" "$build_number" "$updates_enabled" <<'PY'
import base64, pathlib, re, sys, urllib.parse
key_path, feed, version, build, enabled = sys.argv[1:]
if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version):
    raise SystemExit('Version must be major.minor.patch')
if not re.fullmatch(r'[1-9][0-9]*', build):
    raise SystemExit('Build number must be a positive integer; increase it for every update')
if enabled == 'true':
    url = urllib.parse.urlparse(feed)
    if url.scheme != 'https' or not url.hostname or url.username or url.password:
        raise SystemExit('OTA feed must be an HTTPS URL without embedded credentials')
    try:
        key = pathlib.Path(key_path).read_text().strip()
        if len(base64.b64decode(key, validate=True)) != 32:
            raise ValueError('public key must be 32 bytes')
    except (OSError, ValueError) as error:
        raise SystemExit(f'OTA public key missing or invalid: {error}. Use --disable-updates only for development/CI.')
PY

cd "$root_dir"
# Public Sparkle artifacts do not require HTTP credentials from login Keychain.
swift build --disable-keychain -c "$configuration" --product MacOSX
bin_dir="$(swift build --disable-keychain -c "$configuration" --show-bin-path)"
sparkle="$root_dir/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -x "$bin_dir/MacOSX" && -d "$sparkle" ]] || { echo "Executable or Sparkle framework missing" >&2; exit 1; }

mkdir -p "$output_dir"
output_dir="$(cd "$output_dir" && pwd)"
app="$output_dir/MacOSX.app"
python3 - "$app" <<'PY'
import pathlib, shutil, sys
app = pathlib.Path(sys.argv[1])
if app.name != 'MacOSX.app':
    raise SystemExit('Refusing to replace an unexpected build path')
if app.is_symlink():
    app.unlink()
elif app.exists():
    shutil.rmtree(app)
PY
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources"
cp "$bin_dir/MacOSX" "$app/Contents/MacOS/MacOSX"
cp "$root_dir/Resources/Sparkle-LICENSE.txt" "$app/Contents/Resources/Sparkle-LICENSE.txt"
cp "$root_dir/Resources/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
# ditto preserves framework symlinks and executable permissions.
/usr/bin/ditto "$sparkle" "$app/Contents/Frameworks/Sparkle.framework"

python3 - "$app/Contents/Info.plist" "$root_dir/Resources/update-public-key.txt" "$feed_url" "$version" "$build_number" "$updates_enabled" <<'PY'
import pathlib, plistlib, sys
destination, key_path, feed, version, build, enabled = sys.argv[1:]
info = {
    'CFBundleName': 'macos-x',
    'CFBundleDisplayName': 'macos-x',
    'CFBundleIdentifier': 'cc.anjing.macos-x',
    'CFBundleExecutable': 'MacOSX',
    'CFBundlePackageType': 'APPL',
    'CFBundleIconFile': 'AppIcon.icns',
    'CFBundleShortVersionString': version,
    'CFBundleVersion': build,
    'LSMinimumSystemVersion': '14.0',
    'LSUIElement': False,
    'NSHighResolutionCapable': True,
    'MacOSXUpdatesEnabled': enabled == 'true',
    'SUEnableAutomaticChecks': enabled == 'true',
    'SUAutomaticallyUpdate': False,
    'SUAllowsAutomaticUpdates': False,
    'SUEnableSystemProfiling': False,
    'SUShowReleaseNotes': False,
    'SUVerifyUpdateBeforeExtraction': True,
    'SURequireSignedFeed': True,
    'SUSignedFeedFailureExpirationInterval': 0,
}
if enabled == 'true':
    info['SUFeedURL'] = feed
    info['SUPublicEDKey'] = pathlib.Path(key_path).read_text().strip()
with open(destination, 'wb') as output:
    plistlib.dump(info, output)
PY

# Sign nested components from the inside out. Preserve Sparkle helper entitlements.
sign_options=(--force --sign "$sign_identity" --preserve-metadata=identifier,entitlements)
app_sign_options=(--force --sign "$sign_identity" --identifier cc.anjing.macos-x)
if [[ "$sign_identity" != - ]]; then
    [[ "$sign_identity" == "Developer ID Application:"* || "$sign_identity" == "Apple Development:"* ]] || {
        echo "Use a Developer ID Application or Apple Development identity, or - for ad hoc" >&2; exit 1;
    }
    sign_options+=(--options runtime --timestamp)
    app_sign_options+=(--options runtime --timestamp)
fi
framework="$app/Contents/Frameworks/Sparkle.framework"
for component in "$framework"/Versions/Current/XPCServices/*.xpc \
                 "$framework/Versions/Current/Updater.app" \
                 "$framework/Versions/Current/Autoupdate" "$framework"; do
    /usr/bin/codesign "${sign_options[@]}" "$component"
done
/usr/bin/codesign "${app_sign_options[@]}" "$app"
/usr/bin/codesign --verify --deep --strict "$app"
/usr/bin/plutil -lint "$app/Contents/Info.plist"

# The executable must load its embedded framework through an app-relative rpath.
/usr/bin/otool -L "$app/Contents/MacOS/MacOSX" | /usr/bin/grep -q '@rpath/Sparkle.framework/'
/usr/bin/otool -l "$app/Contents/MacOS/MacOSX" | /usr/bin/grep -q '@executable_path/../Frameworks'
echo "Built: $app (version $version, build $build_number, OTA=$updates_enabled)"
if [[ "$sign_identity" == - ]]; then
    echo "Local ad hoc signature only; this build is not Developer ID signed or notarized."
else
    echo "Code signed with $sign_identity; notarization is a separate required distribution step."
fi
