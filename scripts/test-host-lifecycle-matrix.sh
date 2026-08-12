#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/path/to/IdleScreen.app [cycles] [start-timeout-seconds] [invalidation-timeout-seconds]" >&2
  exit 64
}

[[ $# -ge 1 && $# -le 4 ]] || usage

app_path="$1"
cycles="${2:-1}"
start_timeout_seconds="${3:-45}"
invalidation_timeout_seconds="${4:-180}"

[[ "$app_path" = /* ]] || usage
[[ "$cycles" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$start_timeout_seconds" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$invalidation_timeout_seconds" =~ ^[1-9][0-9]*$ ]] || usage

if [[ "${IDLESCREEN_ALLOW_PHYSICAL_TESTS:-NO}" != YES ]]; then
  echo "REFUSED: set IDLESCREEN_ALLOW_PHYSICAL_TESTS=YES only after explicitly authorizing repeated focus-changing physical screen-saver runs." >&2
  exit 65
fi

if ((cycles > 1)) && [[ "${IDLESCREEN_ALLOW_CONTINUOUS_PHYSICAL_CYCLES:-NO}" != YES ]]; then
  echo "REFUSED: run one physical cycle at a time, or set IDLESCREEN_ALLOW_CONTINUOUS_PHYSICAL_CYCLES=YES only after explicitly authorizing an uninterrupted multi-cycle run." >&2
  exit 65
fi

project_root="$(cd "$(dirname "$0")/.." && pwd)"
single_cycle_runner="$project_root/scripts/test-host-lifecycle.sh"
matrix_evidence_verifier="$project_root/scripts/verify-host-lifecycle-matrix-evidence.sh"
extension_path="$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex"
extension_info="$extension_path/Contents/Info.plist"
artifact_root="$(mktemp -d /tmp/idlescreen-host-matrix.XXXXXX)"

fail() {
  echo "FAIL: $*" >&2
  echo "Evidence: $artifact_root" >&2
  exit 1
}

[[ -x "$single_cycle_runner" ]] || fail "missing physical host lifecycle runner"
[[ -x "$matrix_evidence_verifier" ]] || fail "missing physical host matrix evidence verifier"
[[ -f "$extension_info" ]] || fail "missing embedded extension Info.plist"

extension_id="$(plutil -extract CFBundleIdentifier raw "$extension_info")"
extension_executable="$(plutil -extract CFBundleExecutable raw "$extension_info")"
extension_process="$extension_path/Contents/MacOS/$extension_executable"

selected_extension_path() {
  /usr/bin/pluginkit -m -v -p com.apple.screensaver | awk -F '\t' -v identity="$extension_id(" '
    index($1, identity) {
      path = $NF
      sub(/^[[:space:]]+/, "", path)
      sub(/[[:space:]]+$/, "", path)
      print path
      exit
    }
  '
}

registered_extension_paths() {
  /usr/bin/pluginkit -m -A -D -v -p com.apple.screensaver | awk -F '\t' -v identity="$extension_id(" '
    index($1, identity) {
      path = $NF
      sub(/^[[:space:]]+/, "", path)
      sub(/[[:space:]]+$/, "", path)
      print path
    }
  ' | sort
}

extension_process_is_running() {
  /bin/ps ax -o comm= | grep -Fxq "$extension_process"
}

original_selected_path="$(selected_extension_path)"
original_registered_paths="$(registered_extension_paths)"

[[ -n "$original_selected_path" ]] || fail "$extension_id is not selected"
[[ "$original_selected_path" == "$extension_path" ]] ||
  [[ "$(/bin/realpath "$original_selected_path")" == "$(/bin/realpath "$extension_path")" ]] ||
  fail "selected extension is $original_selected_path instead of $extension_path"

echo "INFO: running $cycles explicit physical host cycle(s)."
echo "INFO: each cycle requires a normal unlock after animation appears."

for ((cycle = 1; cycle <= cycles; cycle += 1)); do
  printf -v cycle_name 'cycle-%02d' "$cycle"
  cycle_output="$artifact_root/$cycle_name.out"

  echo "INFO: starting $cycle_name of $cycles."
  set +e
  "$single_cycle_runner" \
    "$app_path" \
    "$start_timeout_seconds" \
    "$invalidation_timeout_seconds" \
    2>&1 | tee "$cycle_output"
  runner_status=${PIPESTATUS[0]}
  set -e

  [[ "$runner_status" -eq 0 ]] || fail "$cycle_name did not complete"

  cycle_evidence="$(awk -F 'Evidence: ' '/^Evidence: / { print $2 }' "$cycle_output" | tail -1)"
  [[ -f "$cycle_evidence/host.log" ]] || fail "$cycle_name did not retain a host log"
  cp "$cycle_evidence/host.log" "$artifact_root/$cycle_name.log"

  [[ "$(selected_extension_path)" == "$original_selected_path" ]] ||
    fail "$cycle_name changed the selected screen saver registration"
  [[ "$(registered_extension_paths)" == "$original_registered_paths" ]] ||
    fail "$cycle_name changed the physical screen saver registration set"
  ! pgrep -x ScreenSaverEngine >/dev/null ||
    fail "$cycle_name left ScreenSaverEngine running after invalidation"
  ! extension_process_is_running ||
    fail "$cycle_name left the modern screen-saver extension running after invalidation"

  echo "PASS: $cycle_name completed without stale registration or an active host process."
done

matrix_verification="$artifact_root/matrix-verification.txt"
if ! "$matrix_evidence_verifier" "$artifact_root" "$cycles" 5 >"$matrix_verification" 2>&1; then
  cat "$matrix_verification" >&2
  fail "aggregate physical host matrix evidence did not verify"
fi
cat "$matrix_verification"

echo "PASS: $extension_id completed $cycles physical activation/invalidation cycle(s)."
echo "PASS: selection and registration state remained unchanged."
echo "Evidence: $artifact_root"
