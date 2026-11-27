#!/bin/bash
# Usage: install-xcodegen.sh <version> <sha256-of-xcodegen.zip> <destination-dir>
# Downloads the pinned XcodeGen release, verifies its SHA-256, and extracts it
# into the destination. Prints the path of the xcodegen binary on stdout.
set -euo pipefail

[[ $# -eq 3 ]] || { echo "Usage: $0 <version> <sha256> <destination-dir>" >&2; exit 2; }
version="$1" expected_sha="$2" destination="$3"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "FAIL: bad XcodeGen version: $version" >&2; exit 2; }
[[ "$expected_sha" =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL: expected a lowercase SHA-256" >&2; exit 2; }
[[ -d "$destination" ]] || { echo "FAIL: destination is not a directory: $destination" >&2; exit 2; }

archive="$destination/xcodegen-$version.zip"
/usr/bin/curl -fsSL -o "$archive" \
  "https://github.com/yonaskolb/XcodeGen/releases/download/$version/xcodegen.zip"
actual_sha="$(/usr/bin/shasum -a 256 "$archive" | /usr/bin/awk '{ print $1 }')"
[[ "$actual_sha" == "$expected_sha" ]] || {
  echo "FAIL: XcodeGen $version archive SHA-256 mismatch (got $actual_sha)" >&2
  exit 1
}
/usr/bin/unzip -q "$archive" -d "$destination/xcodegen-$version"
binary="$destination/xcodegen-$version/xcodegen/bin/xcodegen"
[[ -x "$binary" ]] || { echo "FAIL: archive has no xcodegen binary" >&2; exit 1; }
[[ "$("$binary" --version)" == "Version: $version" ]] || {
  echo "FAIL: installed XcodeGen is not $version" >&2
  exit 1
}
echo "$binary"
