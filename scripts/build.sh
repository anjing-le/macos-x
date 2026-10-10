#!/bin/bash
set -euo pipefail

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration=release
output_dir="$root_dir/dist"
version=0.0.60
build_number=62
sign_identity="${MACOSX_SIGN_IDENTITY:-}"
sign_keychain="${MACOSX_SIGN_KEYCHAIN:-}"
local_signing=false
updates_enabled=true
feed_url="${MACOSX_FEED_URL:-https://github.com/anjing-le/macos-x/releases/latest/download/appcast.xml}"

usage() {
    cat <<'USAGE'
Usage: scripts/build.sh [--disable-updates] [--configuration debug|release]
       [--version 0.0.60] [--build-number 62] [--output-dir path]
       [--sign-identity pinned-certificate-SHA1 | "Apple Development: ..." | "Developer ID Application: ..."]
       [--sign-keychain path]
Default: host architecture, OTA enabled; an explicit certificate identity is required.
Set MACOSX_SIGN_IDENTITY or --sign-identity; OTA builds never fall back to ad hoc.
Local signing requires the SHA1 of Resources/code-signing-certificate.cer.
MACOSX_SIGN_KEYCHAIN or --sign-keychain selects an existing signing keychain.
--disable-updates allows local ad hoc signing for development/CI.
Set MACOSX_FEED_URL at build time for an alternate HTTPS appcast.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --disable-updates) updates_enabled=false; shift ;;
        --configuration|--version|--build-number|--output-dir|--sign-identity|--sign-keychain)
            [[ $# -ge 2 && -n "$2" ]] || { echo "Missing value for $1" >&2; exit 1; }
            case "$1" in
                --configuration) configuration="$2" ;;
                --version) version="$2" ;;
                --build-number) build_number="$2" ;;
                --output-dir) output_dir="$2" ;;
                --sign-identity) sign_identity="$2" ;;
                --sign-keychain) sign_keychain="$2" ;;
            esac
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 1 ;;
    esac
done
[[ "$configuration" == release || "$configuration" == debug ]] || { echo "Invalid configuration" >&2; exit 1; }

if [[ "$updates_enabled" == true && ( -z "$sign_identity" || "$sign_identity" == - ) ]]; then
    echo "OTA requires an explicit pinned certificate SHA1 or Apple certificate identity; ad hoc signing is not allowed." >&2
    exit 1
fi
[[ -n "$sign_identity" ]] || sign_identity=-
if [[ "$sign_identity" =~ ^[a-fA-F0-9]{40}$ ]]; then
    local_signing=true
elif [[ "$sign_identity" != - && "$sign_identity" != "Developer ID Application:"* && "$sign_identity" != "Apple Development:"* ]]; then
    echo "Use the pinned local certificate SHA1, an Apple certificate identity, or - only with --disable-updates." >&2
    exit 1
fi
[[ -z "$sign_keychain" || -f "$sign_keychain" ]] || { echo "Signing keychain does not exist" >&2; exit 1; }

# Validate before compiling: an OTA-enabled build requires a real public key.
python3 - "$root_dir/Resources/update-public-key.txt" "$feed_url" "$version" "$build_number" "$updates_enabled" \
    "$root_dir/Resources/code-signing-certificate.cer" "$sign_identity" "$local_signing" <<'PY'
import base64, hashlib, pathlib, re, subprocess, sys, urllib.parse
key_path, feed, version, build, enabled, certificate_path, identity, local = sys.argv[1:]
if local == 'true':
    try:
        certificate = pathlib.Path(certificate_path).read_bytes()
        if not 0 < len(certificate) <= 65536 or hashlib.sha1(certificate).hexdigest().lower() != identity.lower():
            raise ValueError('signing identity must match the pinned certificate SHA1')
        details = subprocess.check_output(['/usr/bin/openssl', 'x509', '-inform', 'DER', '-in', certificate_path,
            '-noout', '-subject', '-issuer', '-email', '-nameopt', 'RFC2253'], text=True).splitlines()
        fields = dict(line.split('=', 1) for line in details if '=' in line)
        if (fields.get('subject', '').strip() != 'CN=macos-x' or fields.get('issuer', '').strip() != 'CN=macos-x'
            or len(details) != 2):
            raise ValueError('pinned local certificate must be self-issued with only CN=macos-x and no email')
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'Invalid pinned local signing certificate: {error}')
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

# Fail before codesign can open repeated unlock dialogs. This is a build-only
# credential; no password is printed or placed in the application/archive.
if [[ "$local_signing" == true ]]; then
    [[ -n "$sign_keychain" ]] || sign_keychain="$HOME/Library/Application Support/macos-x/signing/local-code-signing-restored.keychain-db"
    python3 - "$sign_keychain" <<'KEYCHAIN_PY'
import pathlib, subprocess, sys
expected = pathlib.Path.home() / 'Library/Application Support/macos-x/signing/local-code-signing-restored.keychain-db'
if pathlib.Path(sys.argv[1]).resolve() != expected.resolve():
    raise SystemExit('Local signing requires the existing dedicated signing keychain')
try:
    credential = subprocess.run(['/usr/bin/security', 'find-generic-password', '-s',
        'cc.anjing.macos-x.local-code-signing-keychain', '-a', 'macos-x', '-w',
        str(pathlib.Path.home() / 'Library/Keychains/login.keychain-db')],
        capture_output=True, timeout=10)
    if credential.returncode != 0:
        raise SystemExit('Signing credential unavailable; stopped before codesign. Unlock the login keychain manually.')
    password = credential.stdout.removesuffix(b'\n').decode('utf-8')
    result = subprocess.run(['/usr/bin/security', 'unlock-keychain', '-p', password, str(expected)],
        capture_output=True, timeout=10)
    if result.returncode != 0:
        raise SystemExit('Saved signing credential cannot unlock the dedicated keychain; stopped before codesign. Repair the saved credential without replacing the certificate.')
except subprocess.TimeoutExpired:
    raise SystemExit('Signing keychain authentication timed out; stopped before codesign.')
KEYCHAIN_PY
fi

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
for asset in SketchFont.ttf SketchFont-OFL.txt SketchPaper.png CardArtwork.png GuideCapture.png GuideSwitcher.png GuidePrompts.png SettingsCaptureBoard.png SettingsSwitcherBoard.png SettingsPromptsBoard.png; do
    cp "$root_dir/Resources/$asset" "$app/Contents/Resources/$asset"
done
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
    'LSUIElement': True,
    'NSHighResolutionCapable': True,
    'MacOSXUpdatesEnabled': enabled == 'true',
    'SUEnableAutomaticChecks': enabled == 'true',
    'SUScheduledCheckInterval': 3600,
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
if [[ -n "$sign_keychain" ]]; then
    sign_options+=(--keychain "$sign_keychain")
    app_sign_options+=(--keychain "$sign_keychain")
fi
if [[ "$local_signing" == true ]]; then
    # Match the existing local runtime baseline; no Apple Team ID for library validation.
    sign_options+=(--options 0 --timestamp=none)
    app_sign_options+=(--options 0 --timestamp=none)
elif [[ "$sign_identity" != - ]]; then
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
if [[ "$local_signing" == true ]]; then
    python3 - "$app" "$root_dir/Resources/code-signing-certificate.cer" <<'PY'
import hashlib, pathlib, re, subprocess, sys, tempfile
app, certificate_path = sys.argv[1:]
metadata = subprocess.run(['/usr/bin/codesign', '--display', '--verbose=4', app],
    check=True, text=True, capture_output=True).stderr
flags = re.search(r'\bflags=0x([0-9a-fA-F]+)', metadata)
if flags is None or int(flags.group(1), 16) & 0x10000:
    raise SystemExit('Local signing must retain the non-hardened runtime baseline')
with tempfile.TemporaryDirectory(prefix='macos-x-signature-') as directory:
    prefix = str(pathlib.Path(directory) / 'certificate-')
    subprocess.run(['/usr/bin/codesign', '--display', '--extract-certificates=' + prefix, app],
        check=True, capture_output=True)
    leaf = pathlib.Path(prefix + '0').read_bytes()
    if hashlib.sha256(leaf).digest() != hashlib.sha256(pathlib.Path(certificate_path).read_bytes()).digest():
        raise SystemExit('Built app leaf certificate does not match the pinned local certificate')
PY
fi
/usr/bin/plutil -lint "$app/Contents/Info.plist"

# The executable must load its embedded framework through an app-relative rpath.
/usr/bin/otool -L "$app/Contents/MacOS/MacOSX" | /usr/bin/grep -q '@rpath/Sparkle.framework/'
/usr/bin/otool -l "$app/Contents/MacOS/MacOSX" | /usr/bin/grep -q '@executable_path/../Frameworks'
echo "Built: $app (version $version, build $build_number, OTA=$updates_enabled)"
if [[ "$sign_identity" == - ]]; then
    echo "Local ad hoc signature only; this build is not Developer ID signed or notarized."
elif [[ "$local_signing" == true ]]; then
    echo "Pinned local certificate signature; no Apple account, Developer ID or notarization."
else
    echo "Code signed with $sign_identity; notarization is a separate required distribution step."
fi
