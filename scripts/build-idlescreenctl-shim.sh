#!/bin/bash
# Builds the Contents/Helpers/idlescreenctl launcher shim for the Developer ID
# distribution. Usage: build-idlescreenctl-shim.sh OUTPUT REFERENCE_BINARY
# The shim is built for the same architectures as REFERENCE_BINARY.

set -euo pipefail

script_root="$(cd "$(dirname "$0")" && pwd)"
project_root="$(cd "$script_root/.." && pwd)"
source_file="$project_root/Products/IdleScreenCtlShim/main.swift"

[[ $# -eq 2 ]] || {
  echo "Usage: $0 OUTPUT REFERENCE_BINARY" >&2
  exit 64
}
output="$1"
reference="$2"
[[ -f "$source_file" ]] || {
  echo "FAIL: missing shim source: $source_file" >&2
  exit 66
}
[[ -f "$reference" && ! -L "$reference" ]] || {
  echo "FAIL: missing reference binary: $reference" >&2
  exit 66
}
[[ ! -e "$output" ]] || {
  echo "FAIL: refusing to replace $output" >&2
  exit 73
}

architectures="$(/usr/bin/lipo -archs "$reference")" || {
  echo "FAIL: could not read architectures of $reference" >&2
  exit 1
}
[[ -n "$architectures" ]] || {
  echo "FAIL: $reference has no architectures" >&2
  exit 1
}

scratch_root="$(/usr/bin/mktemp -d /tmp/idlescreenctl-shim.XXXXXX)"
trap '/bin/rm -rf "${scratch_root:?}"' EXIT

slices=()
for architecture in $architectures; do
  slice="$scratch_root/shim-$architecture"
  /usr/bin/xcrun swiftc -O -target "$architecture-apple-macos15.0" \
    -o "$slice" "$source_file" || {
    echo "FAIL: could not compile the shim for $architecture" >&2
    exit 1
  }
  slices+=("$slice")
done
if [[ ${#slices[@]} -eq 1 ]]; then
  /bin/cp "${slices[0]}" "$output"
else
  /usr/bin/lipo -create "${slices[@]}" -output "$output"
fi
/bin/chmod 755 "$output"
