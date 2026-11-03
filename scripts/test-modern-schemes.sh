#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
requested_root="${1:-}"
cleanup_root=NO

if [[ -z "$requested_root" ]]; then
  result_root="$(mktemp -d /tmp/idlescreen-modern-schemes.XXXXXX)"
  cleanup_root=YES
else
  [[ "$requested_root" = /* && ! -e "$requested_root" ]] || {
    echo "Usage: $0 [/absolute/nonexistent/result/directory]" >&2
    exit 64
  }
  result_root="$requested_root"
  /bin/mkdir -p "$result_root"
fi

cleanup() {
  if [[ "$cleanup_root" == YES ]]; then
    /bin/rm -rf "${result_root:?}"
  fi
}
trap cleanup EXIT

schemes=(
  IdleScreenAgent
  IdleScreenCore
  IdleScreenDisplay
  IdleScreenRenderer
  IdleScreenPerformance
  IdleScreenCamera
  IdleScreenCameraAgent
  IdleScreenSyntheticGateTests
  IdleScreenSystem
  IdleScreenScreenSaver
  IdleScreenAppCamera
)

# Stall watchdog: a scheme whose log and DerivedData stop changing for
# IDLESCREEN_TEST_STALL_SECONDS (default 300, 0 disables) is killed and fails.
stall_seconds="${IDLESCREEN_TEST_STALL_SECONDS:-300}"
case "$stall_seconds" in '' | *[!0-9]*) stall_seconds=300 ;; esac
# Overridable so the guards can be exercised with stubs.
xcodebuild_bin="${IDLESCREEN_XCODEBUILD:-xcodebuild}"
xcresulttool_bin="${IDLESCREEN_XCRESULTTOOL:-xcrun xcresulttool}"

descendants() {
  local child
  for child in $(pgrep -P "$1" 2>/dev/null); do
    echo "$child"
    descendants "$child"
  done
}

activity_signature() {
  local log="$1" derived="$2"
  echo "$(stat -f %z "$log" 2>/dev/null || echo 0)/$(du -sk "$derived" 2>/dev/null | awk '{ print $1 }')"
}

watch_for_stall() {
  local target_pid="$1" log="$2" derived="$3" flag="$4"
  local last current idle=0 victim victims
  last="$(activity_signature "$log" "$derived")"
  while kill -0 "$target_pid" 2>/dev/null; do
    sleep 2
    current="$(activity_signature "$log" "$derived")"
    if [[ "$current" != "$last" ]]; then
      last="$current"
      idle=0
      continue
    fi
    idle=$((idle + 2))
    if [[ "$idle" -ge "$stall_seconds" ]]; then
      : >"$flag"
      echo "no test output or build activity for ${idle}s, stopping the run" >>"$log"
      victims="$(descendants "$target_pid") $target_pid"
      for victim in $victims; do
        kill -TERM "$victim" 2>/dev/null || true
      done
      sleep 5
      # Re-collect: a child spawned after the first sweep, or one the dying
      # parent's exit orphaned, is not in the first list.
      victims="$victims $(descendants "$target_pid")"
      for victim in $victims; do
        kill -KILL "$victim" 2>/dev/null || true
      done
      return 0
    fi
  done
}

# Prints the number of tests the xcresult reports, or 0 when it cannot say.
result_test_count() {
  # shellcheck disable=SC2086  # the tool may be a multi-word command
  $xcresulttool_bin get test-results summary --path "$1" 2>/dev/null |
    /usr/bin/python3 -I -c '
import json, sys
try:
    print(int(json.load(sys.stdin).get("totalTestCount", 0)))
except Exception:
    print(0)
'
}

run_scheme() {
  local scheme="$1" result_bundle="$2" derived="$3"
  local log status=0 xcodebuild_pid watchdog_pid="" flag problems=()
  log="$(mktemp "$result_root/$scheme.log.XXXXXX")"
  flag="$log.stalled"
  mkdir -p "$derived"

  "$xcodebuild_bin" test -quiet \
    -project "$project_root/IdleScreen.xcodeproj" \
    -scheme "$scheme" \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived" \
    -resultBundlePath "$result_bundle" \
    CODE_SIGNING_ALLOWED=NO \
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES >"$log" 2>&1 &
  xcodebuild_pid=$!
  # Stream the log while the run is alive so progress is visible.
  tail -f "$log" &
  local tail_pid=$!
  if [[ "$stall_seconds" -gt 0 ]]; then
    watch_for_stall "$xcodebuild_pid" "$log" "$derived" "$flag" &
    watchdog_pid=$!
  fi
  wait "$xcodebuild_pid" || status=$?
  if [[ -n "$watchdog_pid" ]]; then
    # A stalled run must let the watchdog finish its KILL sweep, or a child
    # that ignored TERM outlives the script.
    [[ -e "$flag" ]] || kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
  fi
  sleep 1
  kill "$tail_pid" 2>/dev/null || true
  wait "$tail_pid" 2>/dev/null || true

  [[ "$status" -eq 0 ]] || problems+=("xcodebuild exited $status")
  [[ ! -e "$flag" ]] || problems+=("run stalled for ${stall_seconds}s with no output")
  if grep -Eq '\*\* (TEST|BUILD) FAILED \*\*|Test Case .* failed|^✘ |with [1-9][0-9]* failures?|Testing failed:' "$log"; then
    problems+=("failure markers found in xcodebuild output")
  fi
  if [[ "$(result_test_count "$result_bundle")" -le 0 ]]; then
    problems+=("xcresult reports 0 tests run")
  fi

  if [[ ${#problems[@]} -gt 0 ]]; then
    echo "FAIL: $scheme: ${problems[*]}" >&2
    xcrun xcresulttool get test-results summary --path "$result_bundle" || true
    xcrun xcresulttool get test-results tests --path "$result_bundle" || true
    return 1
  fi
}

for scheme in "${schemes[@]}"; do
  result_bundle="$result_root/$scheme.xcresult"
  echo "Running $scheme"
  run_scheme "$scheme" "$result_bundle" "$result_root/DerivedData/$scheme" || exit 1
done

echo "PASS: ${#schemes[@]} modern Xcode schemes passed."
