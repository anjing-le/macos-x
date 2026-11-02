# Shared localization dependency for isolated native regression executables.
if [[ -n "${ZSH_VERSION:-}" ]]; then
  localization_script="${(%):-%x}"
else
  localization_script="${BASH_SOURCE[0]}"
fi
localization_repo="$(cd "$(dirname "$localization_script")/../.." && pwd)"
swift build --package-path "$localization_repo" --disable-keychain --target MacOSXCore >/dev/null
localization_bin="$(swift build --package-path "$localization_repo" --disable-keychain --show-bin-path)"
