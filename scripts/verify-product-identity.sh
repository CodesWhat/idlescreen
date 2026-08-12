#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/path/to/idlescreen.app /absolute/path/to/product-sha256.txt" >&2
  exit 64
}

[[ $# -eq 2 ]] || usage

app_path="$1"
evidence_path="$2"

[[ "$app_path" = /* && "$evidence_path" = /* ]] || usage

incomplete() {
  echo "INCOMPLETE: $*" >&2
  exit 1
}

fatal() {
  echo "FAIL: $*" >&2
  exit 2
}

companion_binary="$app_path/Contents/MacOS/IdleScreen"
extension_binary="$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver"

[[ -f "$evidence_path" ]] || incomplete "product identity evidence does not exist: $evidence_path"
[[ -f "$companion_binary" ]] || fatal "missing companion product binary: $companion_binary"
[[ -f "$extension_binary" ]] || fatal "missing embedded extension product binary: $extension_binary"

evidence_companion_hash=""
evidence_extension_hash=""
evidence_line_count=0

while IFS= read -r evidence_line || [[ -n "$evidence_line" ]]; do
  evidence_line_count=$((evidence_line_count + 1))
  if [[ "$evidence_line" =~ ^([0-9a-fA-F]{64})[[:space:]]+(.+)$ ]]; then
    evidence_hash="$(printf '%s' "${BASH_REMATCH[1]}" | tr '[:upper:]' '[:lower:]')"
    evidence_binary="${BASH_REMATCH[2]}"
  else
    fatal "malformed product identity evidence on line $evidence_line_count"
  fi

  case "$evidence_binary" in
    */Contents/MacOS/IdleScreen)
      [[ -z "$evidence_companion_hash" ]] ||
        fatal "malformed product identity evidence: duplicate companion entry"
      evidence_companion_hash="$evidence_hash"
      ;;
    */Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver)
      [[ -z "$evidence_extension_hash" ]] ||
        fatal "malformed product identity evidence: duplicate embedded extension entry"
      evidence_extension_hash="$evidence_hash"
      ;;
    *)
      fatal "malformed product identity evidence: unexpected binary path on line $evidence_line_count"
      ;;
  esac
done <"$evidence_path"

[[ "$evidence_line_count" -eq 2 ]] ||
  fatal "malformed product identity evidence: expected exactly two binary entries"
[[ -n "$evidence_companion_hash" ]] ||
  fatal "malformed product identity evidence: companion entry is missing"
[[ -n "$evidence_extension_hash" ]] ||
  fatal "malformed product identity evidence: embedded extension entry is missing"

actual_companion_hash="$(/usr/bin/shasum -a 256 "$companion_binary" | awk '{ print $1 }')"
actual_extension_hash="$(/usr/bin/shasum -a 256 "$extension_binary" | awk '{ print $1 }')"

[[ "$actual_companion_hash" == "$evidence_companion_hash" ]] ||
  fatal "companion product binary does not match the recorded SHA-256 identity"
[[ "$actual_extension_hash" == "$evidence_extension_hash" ]] ||
  fatal "embedded extension product binary does not match the recorded SHA-256 identity"

echo "PASS: companion and embedded extension exactly match the recorded SHA-256 product identity."
