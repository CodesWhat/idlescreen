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

# Build into a staging catalog and swap it in only after it checks out, so a capture that
# produced nothing (or too little) never touches the checked-in catalog.
staging="$(mktemp -d "$(dirname "$catalog")/.SaverThumbnails.XXXXXX")"
trap 'rm -rf "$raw" "$staging"' EXIT

# One thumbnail per creative pattern except autoCycle, whose tile is a mosaic of those same
# thumbnails (SaverTileArt.mosaicPatterns), so it needs no image of its own.
patterns="$(sed -n '/^public enum IdleScreenCreativePattern/,/^}/p' \
  "$repo/Sources/IdleScreenCore/CreativeConfiguration.swift" |
  sed -nE 's/^[[:space:]]+case ([A-Za-z]+)$/\1/p' | grep -vx 'autoCycle' || true)"
expected="$(printf '%s\n' "$patterns" | grep -c . || true)"
actual="$(find "$raw" -maxdepth 1 -name '*.png' | wc -l | tr -d ' ')"
if [ "$expected" -eq 0 ] || [ "$actual" -ne "$expected" ]; then
  echo "capture produced $actual PNGs, expected $expected; checked-in catalog left untouched" >&2
  tail -40 "$raw/xcodebuild.log" >&2
  exit 1
fi
for name in $patterns; do
  [ -f "$raw/$name.png" ] || {
    echo "missing capture for $name; checked-in catalog left untouched" >&2
    exit 1
  }
done

cat >"$staging/Contents.json" <<'JSON'
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

for name in $patterns; do
  set_dir="$staging/$name.imageset"
  mkdir -p "$set_dir"
  cp "$raw/$name.png" "$set_dir/$name@2x.png"
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
done

# Swap: move the old catalog aside, move the new one in, then drop the old. Both are on the same
# volume, so the renames are atomic; if the second fails the old catalog is restored.
backup="$staging.old"
if [ -e "$catalog" ]; then mv "$catalog" "$backup"; fi
if ! mv "$staging" "$catalog"; then
  if [ -e "$backup" ]; then mv "$backup" "$catalog"; fi
  echo "swap failed; checked-in catalog restored" >&2
  exit 1
fi
rm -rf "$backup"
echo "wrote $expected imagesets to $catalog"
