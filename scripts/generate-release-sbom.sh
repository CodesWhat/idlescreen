#!/bin/bash

set -euo pipefail

if [[ $# -ne 2 || "$1" != /* || "$2" != /* ]]; then
  echo "Usage: $0 /absolute/candidate/manifest /absolute/nonexistent/output.spdx.json" >&2
  exit 64
fi

script_root="$(cd "$(dirname "$0")" && pwd)"
manifest="$1"
output="$2"
fixture_mode="${IDLESCREEN_SBOM_FIXTURE_MODE:-NO}"
verifier_override="${IDLESCREEN_SBOM_CANDIDATE_VERIFIER:-}"

if [[ "$fixture_mode" == YES ]]; then
  [[ -n "$verifier_override" && -x "$verifier_override" ]] || {
    echo "FAIL: fixture mode requires an executable candidate verifier." >&2
    exit 64
  }
  verifier="$verifier_override"
else
  [[ "$fixture_mode" == NO && -z "$verifier_override" ]] || {
    echo "FAIL: verifier overrides require explicit fixture mode." >&2
    exit 64
  }
  verifier="$script_root/verify-r1-release-candidate.sh"
fi

[[ -f "$manifest" && ! -L "$manifest" && ! -e "$output" && ! -L "$output" ]] || {
  echo "FAIL: manifest must be a file and output must not exist." >&2
  exit 66
}

dmg_relative="$(/usr/bin/awk -F= '$1 == "dmg_relative_path" { print $2 }' "$manifest")"
manifest_root="$(/bin/realpath "$(/usr/bin/dirname "$manifest")")"
dmg="$manifest_root/$dmg_relative"
"$verifier" "$dmg" "$manifest" >/dev/null
"$script_root/generate-release-sbom.py" "$manifest" "$output"
