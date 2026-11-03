#!/bin/bash
# Regenerates website/dist/assets/shots/*.webp from IdleScreen's own Metal renderer.
# Renders offscreen through SiteCaptureTests (Tests/IdleScreenRendererTests), then
# converts the PNGs to lossless WebP. Needs Xcode, a generated project (xcodegen)
# and cwebp (`brew install webp`).
# Usage: website/scripts/capture-site-images.sh
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
raw="$(mktemp -d /tmp/idlescreen-site-capture.XXXXXX)"
trap 'rm -rf "$raw"' EXIT
out="$repo/website/dist/assets/shots"
mkdir -p "$out"
rm -f "$out"/*.webp

cd "$repo"
TEST_RUNNER_IDLESCREEN_SITE_CAPTURE_DIR="$raw" xcodebuild test \
  -project IdleScreen.xcodeproj -scheme IdleScreenRenderer \
  -only-testing:IdleScreenRendererTests/SiteCaptureTests \
  -destination 'platform=macOS' >"$raw/xcodebuild.log" 2>&1 ||
  { tail -40 "$raw/xcodebuild.log" >&2; exit 1; }

for png in "$raw"/*.png; do
  name="$(basename "$png" .png)"
  cwebp -quiet -lossless -z 9 "$png" -o "$out/$name.webp"
  echo "wrote $out/$name.webp"
done
