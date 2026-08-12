#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
recorder="$project_root/scripts/record-host-lifecycle-matrix-cycle.sh"
fixture_root="$(mktemp -d /tmp/idlescreen-host-matrix-recorder-tests.XXXXXX)"
trap 'rm -rf "$fixture_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

write_cycle() {
  local path="$1"
  local pid="$2"
  local start_second="$3"
  local stop_second="$4"

  printf '%s\n' \
    "2026-08-01 08:02:${start_second}.000 I  IdleScreenScreenSaver[$pid:55c] [com.idlescreen.screensaver:Extension] Extension initialized pid=$pid compatible=true" \
    "2026-08-01 08:02:${start_second}.050 I  IdleScreenScreenSaver[$pid:55c] [com.idlescreen.screensaver:ViewController] Loading view width=1920.000000 height=1080.000000 preview=false" \
    "2026-08-01 08:02:${start_second}.075 I  IdleScreenScreenSaver[$pid:55c] [com.idlescreen.screensaver:View] Global host activity state=running-background source=start-animation changed=true cameraDemand=false" \
    "2026-08-01 08:02:${start_second}.100 I  IdleScreenScreenSaver[$pid:55c] [com.idlescreen.screensaver:View] Animation started preview=false instance=view-$pid display=2" \
    "2026-08-01 08:02:${stop_second}.000 I  IdleScreenScreenSaver[$pid:55c] [com.idlescreen.screensaver:View] Animation stopped preview=false instance=view-$pid display=2" \
    >"$path"
}

run_recorder() {
  local session="$1"
  local source_log="$2"
  local target="$3"

  set +e
  recorder_output="$("$recorder" "$session" "$source_log" "$target" 5 2>&1)"
  recorder_status=$?
  set -e
}

[[ -x "$recorder" ]] || fail "missing executable one-cycle evidence recorder"

cycle_a="$fixture_root/source-a.log"
cycle_b="$fixture_root/source-b.log"
write_cycle "$cycle_a" 2042 01 07
write_cycle "$cycle_b" 3042 11 18

session="$fixture_root/session"
run_recorder "$session" "$cycle_a" 2
[[ "$recorder_status" -eq 0 ]] || fail "first valid cycle was not recorded"
[[ -f "$session/cycle-01.log" ]] || fail "first cycle did not receive a contiguous name"
grep -Fq 'INCOMPLETE: recorded 1 of 2' <<<"$recorder_output" ||
  fail "partial session did not report its exact progress"

run_recorder "$session" "$cycle_b" 2
[[ "$recorder_status" -eq 0 ]] || fail "second valid cycle did not complete the session"
[[ -f "$session/cycle-02.log" ]] || fail "second cycle did not receive a contiguous name"
grep -Fq 'PASS: recorded and verified all 2 physical host cycles' <<<"$recorder_output" ||
  fail "complete session did not report aggregate success"
grep -Fq 'instance=view-3042' "$session/matrix-verification.txt" ||
  fail "retained matrix verification does not identify the exact saver instance"
grep -Fq 'hostActivityRecords=1' "$session/matrix-verification.txt" ||
  fail "retained matrix verification does not count correlated host-activity records"
grep -Fq 'changed=true' "$session/matrix-verification.txt" ||
  fail "retained matrix verification does not record the host-activity change flag"
grep -Fq 'cameraDemand=false' "$session/matrix-verification.txt" ||
  fail "retained matrix verification does not record the camera-demand flag"
if grep -Fq 'trusted=' "$session/matrix-verification.txt"; then
  fail "retained matrix verification contains the retired trusted field"
fi

duplicate_session="$fixture_root/duplicate-session"
run_recorder "$duplicate_session" "$cycle_a" 2
[[ "$recorder_status" -eq 0 ]] || fail "duplicate fixture preflight could not record its first cycle"
run_recorder "$duplicate_session" "$cycle_a" 2
[[ "$recorder_status" -eq 2 ]] || fail "a duplicate cycle must be rejected as fatal evidence"
[[ ! -e "$duplicate_session/cycle-02.log" ]] || fail "a rejected duplicate was retained"

incomplete_source="$fixture_root/incomplete.log"
sed '/Animation stopped/d' "$cycle_b" >"$incomplete_source"
incomplete_session="$fixture_root/incomplete-session"
run_recorder "$incomplete_session" "$incomplete_source" 2
[[ "$recorder_status" -eq 1 ]] || fail "a source log without invalidation must be incomplete"
[[ ! -e "$incomplete_session/cycle-01.log" ]] || fail "incomplete source evidence was retained"

missing_activity_source="$fixture_root/missing-activity.log"
sed '/Global host activity/d' "$cycle_b" >"$missing_activity_source"
missing_activity_session="$fixture_root/missing-activity-session"
run_recorder "$missing_activity_session" "$missing_activity_source" 2
[[ "$recorder_status" -eq 1 ]] ||
  fail "a source log without correlated host activity must be incomplete"
[[ ! -e "$missing_activity_session/cycle-01.log" ]] ||
  fail "source evidence without host activity was retained"

retired_activity_source="$fixture_root/retired-activity.log"
sed 's/cameraDemand=false/trusted=false/' "$cycle_b" >"$retired_activity_source"
retired_activity_session="$fixture_root/retired-activity-session"
run_recorder "$retired_activity_session" "$retired_activity_source" 2
[[ "$recorder_status" -eq 2 ]] ||
  fail "a source log using retired trusted host activity must be fatal"
[[ ! -e "$retired_activity_session/cycle-01.log" ]] ||
  fail "retired trusted=false host-activity evidence was retained"

echo "PASS: separately authorized host cycles accumulate safely into one verified session."
