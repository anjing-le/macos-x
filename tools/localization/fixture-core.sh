# Shared localization dependency for isolated native regression executables.
localization_repo="$(cd "$(dirname "$0")/.." && pwd)"
swift build --package-path "$localization_repo" --disable-keychain --target MacOSXCore >/dev/null
localization_bin="$(swift build --package-path "$localization_repo" --disable-keychain --show-bin-path)"
