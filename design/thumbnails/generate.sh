#!/bin/bash
# Regenerates Products/IdleScreenApp/Assets.xcassets/SaverThumbnails from IdleScreen's own
# Metal renderer. Renders offscreen through SaverThumbnailCaptureTests, then writes one
# imageset per saver. Needs Xcode and a generated project (xcodegen). The output is checked in,
# so normal builds never run this.
# Usage: design/thumbnails/generate.sh
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
raw="$(mktemp -d /tmp/idlescreen-thumbnails.XXXXXX)"
trap 'rm -rf "$raw"' EXIT
catalog="$repo/Products/IdleScreenApp/Assets.xcassets/SaverThumbnails"

cd "$repo"
TEST_RUNNER_IDLESCREEN_THUMBNAIL_DIR="$raw" xcodebuild test \
  -project IdleScreen.xcodeproj -scheme IdleScreenRenderer \
  -only-testing:IdleScreenRendererTests/SaverThumbnailCaptureTests \
  -destination 'platform=macOS' >"$raw/xcodebuild.log" 2>&1 ||
  { tail -40 "$raw/xcodebuild.log" >&2; exit 1; }

rm -rf "$catalog"
mkdir -p "$catalog"
cat >"$catalog/Contents.json" <<'JSON'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  },
  "properties" : {
    "provides-namespace" : true
  }
}
JSON

for png in "$raw"/*.png; do
  name="$(basename "$png" .png)"
  set_dir="$catalog/$name.imageset"
  mkdir -p "$set_dir"
  cp "$png" "$set_dir/$name@2x.png"
  cat >"$set_dir/Contents.json" <<JSON
{
  "images" : [
    {
      "filename" : "$name@2x.png",
      "idiom" : "universal",
      "scale" : "2x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
  echo "wrote $set_dir"
done
