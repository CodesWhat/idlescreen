#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
saver_source="$project_root/docs/assets/idlescreen-saver.svg"
saver_catalog="$project_root/Products/IdleScreenScreenSaver/Assets.xcassets/thumbnail.imageset"
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

render "$saver_source" 107 65 "$asset_tmp/thumbnail.png"
render "$saver_source" 214 130 "$asset_tmp/thumbnail@2x.png"

if [[ "$mode" == --check ]]; then
  for name in thumbnail.png thumbnail@2x.png; do
    /usr/bin/cmp -s "$asset_tmp/$name" "$saver_catalog/$name" || {
      echo "generated screen saver thumbnail is stale: $name" >&2
      exit 1
    }
  done
  echo "PASS: generated brand assets match their tracked sources."
  exit 0
fi

/bin/cp "$asset_tmp/thumbnail.png" "$saver_catalog/thumbnail.png"
/bin/cp "$asset_tmp/thumbnail@2x.png" "$saver_catalog/thumbnail@2x.png"

echo "Generated screen saver thumbnails. The app icon and logo come from design/icon/export.py."
