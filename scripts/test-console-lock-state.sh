#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
probe="$project_root/scripts/read-console-lock-state.sh"
fixture_root="$(mktemp -d /tmp/idlescreen-console-lock-state.XXXXXX)"
trap '/bin/rm -rf "$fixture_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -x "$probe" ]] || fail "missing console lock-state probe at $probe"

make_boolean_fixture() {
  local path="$1"
  local value="$2"
  /usr/bin/plutil -create xml1 "$path"
  /usr/bin/plutil -insert IOConsoleLocked -bool "$value" "$path"
}

make_boolean_fixture "$fixture_root/unlocked.plist" false
make_boolean_fixture "$fixture_root/locked.plist" true
/usr/bin/plutil -create xml1 "$fixture_root/missing.plist"
/usr/bin/plutil -create xml1 "$fixture_root/invalid.plist"
/usr/bin/plutil -insert IOConsoleLocked -string false "$fixture_root/invalid.plist"

[[ "$($probe "$fixture_root/unlocked.plist")" == false ]] ||
  fail "an explicit false IOConsoleLocked value must report unlocked"
[[ "$($probe "$fixture_root/locked.plist")" == true ]] ||
  fail "an explicit true IOConsoleLocked value must report locked"

set +e
missing_output="$($probe "$fixture_root/missing.plist" 2>&1)"
missing_status=$?
invalid_output="$($probe "$fixture_root/invalid.plist" 2>&1)"
invalid_status=$?
set -e

((missing_status == 2)) ||
  fail "a missing IOConsoleLocked value must fail closed with status 2, got $missing_status: $missing_output"
((invalid_status == 2)) ||
  fail "a non-Boolean IOConsoleLocked value must fail closed with status 2, got $invalid_status: $invalid_output"

echo "PASS: console lock-state parsing distinguishes locked, unlocked, and unknown state."
