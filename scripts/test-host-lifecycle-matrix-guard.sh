#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
matrix_runner="$project_root/scripts/test-host-lifecycle-matrix.sh"
missing_app="/tmp/idlescreen-missing-matrix-guard.app"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_matrix() {
  local cycles="$1"
  local continuous_opt_in="$2"

  set +e
  matrix_output="$({
    IDLESCREEN_ALLOW_PHYSICAL_TESTS=YES \
    IDLESCREEN_ALLOW_CONTINUOUS_PHYSICAL_CYCLES="$continuous_opt_in" \
      "$matrix_runner" "$missing_app" "$cycles" 1 1
  } 2>&1)"
  matrix_status=$?
  set -e
}

run_matrix 2 NO
[[ "$matrix_status" -eq 65 ]] ||
  fail "multiple cycles without continuous opt-in must be refused with status 65"
grep -Fq 'IDLESCREEN_ALLOW_CONTINUOUS_PHYSICAL_CYCLES=YES' <<<"$matrix_output" ||
  fail "multiple-cycle refusal must name the separate continuous-run opt-in"

run_matrix 1 NO
! grep -Fq 'IDLESCREEN_ALLOW_CONTINUOUS_PHYSICAL_CYCLES=YES' <<<"$matrix_output" ||
  fail "one physical cycle must not require continuous-run authorization"
grep -Fq 'missing embedded extension Info.plist' <<<"$matrix_output" ||
  fail "one cycle should pass the continuous guard and reach normal preflight"

run_matrix 2 YES
! grep -Fq 'IDLESCREEN_ALLOW_CONTINUOUS_PHYSICAL_CYCLES=YES' <<<"$matrix_output" ||
  fail "an explicitly authorized continuous run must pass the continuous guard"
grep -Fq 'missing embedded extension Info.plist' <<<"$matrix_output" ||
  fail "an explicitly authorized continuous run should reach normal preflight"

echo "PASS: repeated focus-changing host cycles require a separate continuous-run opt-in."
