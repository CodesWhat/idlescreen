#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
icon_source="$project_root/docs/assets/idlescreen-icon.svg"
saver_source="$project_root/docs/assets/idlescreen-saver.svg"
icon_catalog="$project_root/IdleScreenApp/Assets.xcassets/AppIcon.appiconset"
saver_catalog="$project_root/IdleScreenScreenSaver/Assets.xcassets/thumbnail.imageset"
mode="${1:-generate}"

[[ "$mode" == generate || "$mode" == --check ]] || {
  echo "usage: $0 [--check]" >&2
  exit 2
}

command -v magick >/dev/null 2>&1 || {
  echo "ImageMagick is required: brew install imagemagick" >&2
  exit 1
}

asset_tmp="$(mktemp -d /private/tmp/idlescreen-brand.XXXXXX)"
trap '/bin/rm -rf "$asset_tmp"' EXIT

render() {
  local source="$1"
  local width="$2"
  local height="$3"
  local destination="$4"

  magick -background none "$source" \
    -resize "${width}x${height}!" \
    -strip \
    -define png:exclude-chunks=date,time \
    "PNG32:$destination"
}

for size in 16 32 64 128 256 512 1024; do
  render "$icon_source" "$size" "$size" "$asset_tmp/AppIcon-$size.png"
done
render "$saver_source" 107 65 "$asset_tmp/thumbnail.png"
render "$saver_source" 214 130 "$asset_tmp/thumbnail@2x.png"

if [[ "$mode" == --check ]]; then
  for size in 16 32 64 128 256 512 1024; do
    /usr/bin/cmp -s \
      "$asset_tmp/AppIcon-$size.png" \
      "$icon_catalog/AppIcon-$size.png" || {
        echo "generated app icon is stale: AppIcon-$size.png" >&2
        exit 1
      }
  done
  for name in thumbnail.png thumbnail@2x.png; do
    /usr/bin/cmp -s "$asset_tmp/$name" "$saver_catalog/$name" || {
      echo "generated screen saver thumbnail is stale: $name" >&2
      exit 1
    }
  done
  echo "PASS: generated brand assets match their tracked SVG sources."
  exit 0
fi

for size in 16 32 64 128 256 512 1024; do
  /bin/cp "$asset_tmp/AppIcon-$size.png" "$icon_catalog/AppIcon-$size.png"
done
/bin/cp "$asset_tmp/thumbnail.png" "$saver_catalog/thumbnail.png"
/bin/cp "$asset_tmp/thumbnail@2x.png" "$saver_catalog/thumbnail@2x.png"

echo "Generated app icons and screen saver thumbnails."
