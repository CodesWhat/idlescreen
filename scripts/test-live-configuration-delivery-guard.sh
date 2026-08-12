#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
runner="$project_root/scripts/test-live-configuration-delivery.sh"
missing_app="/tmp/idlescreen-missing-live-configuration-delivery.app"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_runner() {
  local physical_opt_in="$1"

  set +e
  runner_output="$({
    IDLESCREEN_ALLOW_PHYSICAL_TESTS="$physical_opt_in" \
      "$runner" "$missing_app" 1
  } 2>&1)"
  runner_status=$?
  set -e
}

[[ -x "$runner" ]] || fail "missing executable live configuration-delivery runner"

grep -Fq 'restore_original_configuration_best_effort' "$runner" ||
  fail "live configuration delivery must provide best-effort configuration restoration"
grep -Fq 'restoration_required=YES' "$runner" ||
  fail "live configuration delivery must arm restoration before the temporary edit"
grep -Fq 'restoration_required=NO' "$runner" ||
  fail "live configuration delivery must disarm restoration only after verification"
grep -Fq 'process_is_exact_executable "$process_identifier" "$app_binary"' "$runner" ||
  fail "failure cleanup must not terminate a reused or unrelated PID"
echo "PASS: live configuration delivery retains a best-effort failure restoration path."

run_runner NO
[[ "$runner_status" -eq 65 ]] ||
  fail "live configuration delivery without physical opt-in must be refused with status 65"
grep -Fq 'IDLESCREEN_ALLOW_PHYSICAL_TESTS=YES' <<<"$runner_output" ||
  fail "physical-test refusal must name the required opt-in"

run_runner YES
[[ "$runner_status" -eq 1 ]] ||
  fail "an authorized run with a missing app should reach normal product preflight"
grep -Fq 'missing app bundle' <<<"$runner_output" ||
  fail "an authorized run should fail on the missing product, not the authorization guard"

echo "PASS: live configuration delivery requires explicit physical-test authorization."
