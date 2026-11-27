#!/usr/bin/env bash
# Install an exact XcodeGen release from its GitHub release asset instead of the
# moving Homebrew bottle. Usage: install-xcodegen.sh <version> <sha256> [dest]
# dest defaults to $RUNNER_TEMP/xcodegen-<version>. When GITHUB_PATH is set the
# bin directory is appended to it. The binary must report exactly <version>.
set -euo pipefail

version="${1:?usage: install-xcodegen.sh <version> <sha256> [dest]}"
sha256="${2:?usage: install-xcodegen.sh <version> <sha256> [dest]}"
dest="${3:-${RUNNER_TEMP:?RUNNER_TEMP or an explicit dest is required}/xcodegen-$version}"

[[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || { echo "::error::sha256 must be 64 lowercase hex digits" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

curl --fail --silent --show-error --location --retry 3 \
  --output "$work/xcodegen.zip" \
  "https://github.com/yonaskolb/XcodeGen/releases/download/$version/xcodegen.zip"
(cd "$work" && echo "$sha256  xcodegen.zip" | shasum -a 256 -c -)

mkdir -p "$work/unpacked"
unzip -q "$work/xcodegen.zip" -d "$work/unpacked"
rm -rf "$dest"
mkdir -p "$dest"
cp -R "$work/unpacked/xcodegen/." "$dest/"

observed="$("$dest/bin/xcodegen" --version)"
[[ "$observed" == "Version: $version" ]] || {
  echo "::error::installed XcodeGen reports '$observed', expected 'Version: $version'" >&2
  exit 1
}

if [[ -n "${GITHUB_PATH:-}" ]]; then
  echo "$dest/bin" >>"$GITHUB_PATH"
fi
echo "Installed XcodeGen $version at $dest"
