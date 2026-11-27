#!/bin/zsh
set -euo pipefail
feed_root="$(cd "$(dirname "$0")/.." && pwd)"
feed_temp="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-feed-architecture.XXXXXX")"
trap 'rm -rf "$feed_temp"' EXIT
cd "$feed_root"
swift build --disable-keychain --target MacOSXCore
feed_bin="$(swift build --disable-keychain --show-bin-path)"
feed_framework="$feed_root/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64"
xcrun swiftc -parse-as-library -I "$feed_bin/Modules" "$feed_bin"/MacOSXCore.build/*.swift.o \
  -F "$feed_framework" -framework Sparkle -Xlinker -rpath -Xlinker "$feed_framework" \
  Sources/MacOSX/UI/SketchTheme.swift Sources/MacOSX/UI/SketchIcons.swift Sources/MacOSX/UI/MinimalControls.swift \
  Sources/MacOSX/Updates/*.swift tools/update-architecture-feed-regression.swift -o "$feed_temp/FeedFixture"
"$feed_temp/FeedFixture" "$feed_temp"
