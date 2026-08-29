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
snapshot_parent=""

cleanup() {
  local status=$?
  local cleanup_status=0
  trap - EXIT
  if [[ -n "$snapshot_parent" ]]; then
    /bin/rm -rf "${snapshot_parent:?}" || cleanup_status=$?
  fi
  if [[ "$status" -eq 0 && "$cleanup_status" -ne 0 ]]; then
    status="$cleanup_status"
  fi
  exit "$status"
}
trap cleanup EXIT

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

manifest_root="$(/bin/realpath "$(/usr/bin/dirname "$manifest")")"
manifest_name="$(/usr/bin/basename "$manifest")"
snapshot_parent="$(mktemp -d /tmp/idlescreen-release-sbom.XXXXXX)"
snapshot_root="$snapshot_parent/candidate"
/usr/bin/ditto --clone "$manifest_root" "$snapshot_root"
snapshot_symlinks="$snapshot_parent/symlinks"
/usr/bin/find -s "$snapshot_root" -type l -print0 >"$snapshot_symlinks"
while IFS= read -r -d '' snapshot_link; do
  resolved_link="$(/bin/realpath "$snapshot_link" 2>/dev/null)" || {
    echo "FAIL: candidate snapshot contains a broken symlink." >&2
    exit 66
  }
  case "$resolved_link" in
    "$snapshot_root" | "$snapshot_root"/*) ;;
    *)
      echo "FAIL: candidate snapshot contains an escaping symlink." >&2
      exit 66
      ;;
  esac
done <"$snapshot_symlinks"
snapshot_manifest="$snapshot_root/$manifest_name"
[[ -f "$snapshot_manifest" && ! -L "$snapshot_manifest" ]] || {
  echo "FAIL: candidate snapshot does not contain the manifest." >&2
  exit 66
}
dmg_relative="$(/usr/bin/awk -F= '$1 == "dmg_relative_path" { print $2 }' "$snapshot_manifest")"
snapshot_dmg="$snapshot_root/$dmg_relative"
"$verifier" "$snapshot_dmg" "$snapshot_manifest" >/dev/null
"$script_root/generate-release-sbom.py" "$snapshot_manifest" "$output"
