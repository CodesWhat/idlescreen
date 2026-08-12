#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 [/absolute/path/to/IdleScreen.xcarchive [/absolute/path/to/recorded-manifest.txt]]" >&2
  exit 64
}

[[ $# -le 2 ]] || usage

if (( $# > 0 )) &&
   [[ -n "${IDLESCREEN_PROVENANCE_FIXTURE_MODE+x}" ||
      -n "${IDLESCREEN_PROVENANCE_CODESIGN+x}" ||
      -n "${IDLESCREEN_PROVENANCE_SECURITY+x}" ]]; then
  echo "FAIL: real C3 artifact verification refuses provenance fixture mode and command overrides." >&2
  exit 64
fi

project_root="$(cd "$(dirname "$0")/.." && pwd)"
verifier="$project_root/scripts/verify-release-archive-provenance.sh"
fixture_gate="$project_root/scripts/test-release-archive-provenance-fixtures.sh"

require_release_manifest() {
  local manifest="$1"
  local release_mode_count
  local verification_mode_count

  release_mode_count="$(/usr/bin/grep -Fxc 'verification_mode=release' "$manifest" || true)"
  verification_mode_count="$(/usr/bin/grep -Ec '^verification_mode=' "$manifest" || true)"
  [[ "$release_mode_count" == 1 && "$verification_mode_count" == 1 ]] || {
    echo "FAIL: trusted C3 evidence requires exactly one verification_mode=release." >&2
    return 1
  }
}

[[ -x "$verifier" ]] || {
  echo "FAIL: missing C3 archive verifier: $verifier" >&2
  exit 66
}
[[ -x "$fixture_gate" ]] || {
  echo "FAIL: missing C3 archive verifier fixtures: $fixture_gate" >&2
  exit 66
}

# C3 extends the complete camera-free C2 foundation. Neither this aggregate nor
# either C3 verifier command builds an application product or changes live state.
"$project_root/scripts/test-camera-gate-c2.sh"
"$fixture_gate"

if [[ $# -eq 0 ]]; then
  echo "BLOCKED: C3 needs one supplied, provisioned Release .xcarchive." >&2
  echo "Build it without installation or launch using:" >&2
  echo "  ./scripts/build-camera-gate-c3-release.sh /absolute/path/outside-repository/c3-release-candidate" >&2
  echo "If signing material is unavailable, the builder exits BLOCKED and preserves its log." >&2
  echo "Only with explicit developer-account/Keychain mutation authorization, rerun it as:" >&2
  echo "  IDLESCREEN_ALLOW_SIGNING_CREDENTIAL_UPDATES=YES ./scripts/build-camera-gate-c3-release.sh /absolute/path/outside-repository/c3-release-candidate" >&2
  exit 66
fi

archive_path="$1"
[[ "$archive_path" = /* && "$archive_path" == *.xcarchive ]] || usage
[[ -d "$archive_path" && ! -L "$archive_path" ]] || {
  echo "FAIL: supplied C3 archive is missing or is a symlink: $archive_path" >&2
  exit 66
}
archive_path="$(/bin/realpath "$archive_path")"

manifest_path="${2:-$archive_path.provenance.txt}"
[[ "$manifest_path" = /* ]] || usage
manifest_parent="$(/usr/bin/dirname "$manifest_path")"
manifest_leaf="$(/usr/bin/basename "$manifest_path")"
[[ -d "$manifest_parent" && ! -L "$manifest_parent" &&
   -n "$manifest_leaf" && "$manifest_leaf" != . && "$manifest_leaf" != .. ]] || usage
manifest_parent="$(/bin/realpath "$manifest_parent")"
manifest_path="$manifest_parent/$manifest_leaf"
[[ ! "$manifest_path" == "$archive_path"/* ]] || {
  echo "FAIL: the provenance manifest must remain outside the immutable archive." >&2
  exit 64
}

if [[ -e "$manifest_path" || -L "$manifest_path" ]]; then
  [[ -f "$manifest_path" && ! -L "$manifest_path" ]] || {
    echo "FAIL: recorded C3 manifest must be a regular, non-symlink file: $manifest_path" >&2
    exit 66
  }
  require_release_manifest "$manifest_path"
  replay_root="$(mktemp -d /tmp/idlescreen-c3-manifest-replay.XXXXXX)"
  trap '/bin/rm -rf "$replay_root"' EXIT
  replay_manifest="$replay_root/provenance.txt"
  "$verifier" "$archive_path" "$replay_manifest"
  require_release_manifest "$replay_manifest"
  /usr/bin/cmp -s "$manifest_path" "$replay_manifest" || {
    /usr/bin/diff -u "$manifest_path" "$replay_manifest" >&2 || true
    echo "FAIL: supplied archive no longer reproduces the recorded C3 manifest." >&2
    exit 1
  }
  echo "PASS: supplied archive exactly reproduces its recorded C3 provenance manifest."
else
  "$verifier" "$archive_path" "$manifest_path"
  require_release_manifest "$manifest_path"
  echo "PASS: recorded immutable C3 provenance manifest: $manifest_path"
fi

echo "PASS: C3 signed Release archive provenance is complete and replayable."
echo "PASS: no product was installed, registered, launched, focused, or granted camera access."
