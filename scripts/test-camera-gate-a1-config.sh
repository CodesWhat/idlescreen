#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
preflight="$project_root/scripts/verify-camera-gate-a1-config.py"
fixture_root="$(mktemp -d /tmp/idlescreen-camera-gate-config.XXXXXX)"
trap '/bin/rm -rf "$fixture_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_snapshot() {
  "$preflight" snapshot "$1" "$2"
}

expect_rejected() {
  set +e
  "$@" >/dev/null 2>&1
  local status=$?
  set -e
  ((status == 1)) || fail "expected evidence rejection, got status $status: $*"
}

[[ -x "$preflight" ]] || fail "missing executable configuration preflight"
/usr/bin/env PYTHONPYCACHEPREFIX="$fixture_root/pycache" \
  /usr/bin/python3 -m py_compile "$preflight"

camera_config="$fixture_root/camera.json"
hybrid_config="$fixture_root/hybrid.json"
generative_config="$fixture_root/generative.json"
unsupported_config="$fixture_root/unsupported.json"
missing_source_config="$fixture_root/missing-source.json"
malformed_config="$fixture_root/malformed.json"
printf '{"schemaVersion":1,"source":"camera"}\n' >"$camera_config"
printf '{"schemaVersion":1,"source":"hybrid"}\n' >"$hybrid_config"
printf '{"schemaVersion":1,"source":"generative"}\n' >"$generative_config"
printf '{"schemaVersion":2,"source":"camera"}\n' >"$unsupported_config"
printf '{"schemaVersion":1}\n' >"$missing_source_config"
printf '{not-json}\n' >"$malformed_config"

camera_snapshot="$fixture_root/camera.snapshot"
hybrid_snapshot="$fixture_root/hybrid.snapshot"
camera_before="$(/usr/bin/stat -f '%d:%i:%z:%m' "$camera_config")"
run_snapshot "$camera_config" "$camera_snapshot" || fail "camera config was rejected"
camera_after="$(/usr/bin/stat -f '%d:%i:%z:%m' "$camera_config")"
[[ "$camera_after" == "$camera_before" ]] || fail "snapshot preflight mutated the configuration"
run_snapshot "$hybrid_config" "$hybrid_snapshot" || fail "hybrid config was rejected"
"$preflight" recheck "$camera_config" "$camera_snapshot" || fail "unchanged config failed recheck"
expect_rejected run_snapshot "$generative_config" "$fixture_root/generative.snapshot"
expect_rejected run_snapshot "$unsupported_config" "$fixture_root/unsupported.snapshot"
expect_rejected run_snapshot "$missing_source_config" "$fixture_root/missing-source.snapshot"
expect_rejected run_snapshot "$malformed_config" "$fixture_root/malformed.snapshot"

symlink_config="$fixture_root/symlink.json"
/bin/ln -s "$camera_config" "$symlink_config"
expect_rejected run_snapshot "$symlink_config" "$fixture_root/symlink.snapshot"

printf '{"schemaVersion":1,"source":"hybrid"}\n' >"$camera_config"
expect_rejected "$preflight" recheck "$camera_config" "$camera_snapshot"

echo "PASS: camera-gate configuration snapshot and immutable recheck fixtures passed."
