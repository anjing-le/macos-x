#!/bin/zsh
set -euo pipefail
latency_repo="$(cd "$(dirname "$0")/.." && pwd)"
latency_dir="$(mktemp -d "${TMPDIR:-/tmp/}macos-x-capture-latency.XXXXXX")"
trap 'rm -rf "$latency_dir"' EXIT
# Real, on-demand acquisition only. Existing permission is required; the probe
# never requests authorization, opens windows, saves pixels or touches clipboard.
xcrun swiftc -O \
  "$latency_repo/Sources/MacOSX/Capture/CaptureImageService.swift" \
  "$latency_repo/Sources/MacOSX/Capture/CaptureSampling.swift" \
  "$latency_repo/tools/capture-latency-probe.swift" \
  -o "$latency_dir/capture-latency-probe"
"$latency_dir/capture-latency-probe"
