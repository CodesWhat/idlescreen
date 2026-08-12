#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
verifier="$project_root/scripts/verify-host-lifecycle-matrix-evidence.sh"
fixture_root="$(mktemp -d /tmp/idlescreen-host-matrix-evidence-tests.XXXXXX)"
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
    "2026-08-01 08:01:${start_second}.000 I  IdleScreenScreenSaver[$pid:55c] [com.idlescreen.screensaver:Extension] Extension initialized pid=$pid compatible=true" \
    "2026-08-01 08:01:${start_second}.050 I  IdleScreenScreenSaver[$pid:55c] [com.idlescreen.screensaver:ViewController] Loading view width=1920.000000 height=1080.000000 preview=false" \
    "2026-08-01 08:01:${start_second}.075 I  IdleScreenScreenSaver[$pid:55c] [com.idlescreen.screensaver:View] Global host activity state=inconsistent source=start-animation changed=true cameraDemand=false" \
    "2026-08-01 08:01:${start_second}.100 I  IdleScreenScreenSaver[$pid:55c] [com.idlescreen.screensaver:View] Animation started preview=false instance=view-$pid display=2" \
    "2026-08-01 08:01:${stop_second}.000 I  IdleScreenScreenSaver[$pid:55c] [com.idlescreen.screensaver:View] Animation stopped preview=false instance=view-$pid display=2" \
    >"$path"
}

run_verifier() {
  local directory="$1"
  local expected_cycles="$2"

  set +e
  verifier_output="$("$verifier" "$directory" "$expected_cycles" 5 2>&1)"
  verifier_status=$?
  set -e
}

[[ -x "$verifier" ]] || fail "missing executable matrix-evidence verifier"

complete="$fixture_root/complete"
mkdir -p "$complete"
write_cycle "$complete/cycle-01.log" 2042 01 07
write_cycle "$complete/cycle-02.log" 3042 11 18
run_verifier "$complete" 2
[[ "$verifier_status" -eq 0 ]] || fail "two complete, distinct cycles were rejected"
grep -Fq 'completed 2 independently retained physical host cycles' <<<"$verifier_output" ||
  fail "complete evidence did not report the proven cycle count"
grep -Fq 'instance=view-2042' <<<"$verifier_output" ||
  fail "complete evidence did not report the correlated saver instance"
grep -Fq 'hostActivityRecords=1' <<<"$verifier_output" ||
  fail "complete evidence did not report correlated host-activity records"
grep -Fq 'changed=true' <<<"$verifier_output" ||
  fail "complete evidence did not report the correlated host-activity change flag"
grep -Fq 'cameraDemand=false' <<<"$verifier_output" ||
  fail "complete evidence did not report the correlated camera-demand flag"
if grep -Fq 'trusted=' <<<"$verifier_output"; then
  fail "complete evidence retained the retired trusted host-activity field"
fi

run_verifier "$complete" 3
[[ "$verifier_status" -eq 1 ]] || fail "a missing required cycle must be incomplete"
grep -Fq 'INCOMPLETE:' <<<"$verifier_output" ||
  fail "a missing required cycle must be labeled incomplete"

duplicate="$fixture_root/duplicate"
mkdir -p "$duplicate"
cp "$complete/cycle-01.log" "$duplicate/cycle-01.log"
cp "$complete/cycle-01.log" "$duplicate/cycle-02.log"
run_verifier "$duplicate" 2
[[ "$verifier_status" -eq 2 ]] || fail "duplicated cycle evidence must be fatal"
grep -Fqi 'duplicate' <<<"$verifier_output" ||
  fail "duplicated evidence must explain the identity failure"

incomplete="$fixture_root/incomplete"
mkdir -p "$incomplete"
cp "$complete/cycle-01.log" "$incomplete/cycle-01.log"
sed '/Animation stopped/d' "$complete/cycle-02.log" >"$incomplete/cycle-02.log"
run_verifier "$incomplete" 2
[[ "$verifier_status" -eq 1 ]] || fail "a cycle missing invalidation must be incomplete"

cross_pid_activity="$fixture_root/cross-pid-activity"
mkdir -p "$cross_pid_activity"
cp "$complete/cycle-01.log" "$cross_pid_activity/cycle-01.log"
sed '/Global host activity/s/IdleScreenScreenSaver\[3042:/IdleScreenScreenSaver[9090:/' \
  "$complete/cycle-02.log" >"$cross_pid_activity/cycle-02.log"
run_verifier "$cross_pid_activity" 2
[[ "$verifier_status" -eq 1 ]] ||
  fail "a cycle with host activity from another saver PID must be incomplete"

retired_activity="$fixture_root/retired-activity"
mkdir -p "$retired_activity"
cp "$complete/cycle-01.log" "$retired_activity/cycle-01.log"
sed 's/cameraDemand=false/trusted=false/' \
  "$complete/cycle-02.log" >"$retired_activity/cycle-02.log"
run_verifier "$retired_activity" 2
[[ "$verifier_status" -eq 2 ]] ||
  fail "a cycle using retired trusted=false host activity must be fatal"

echo "PASS: matrix evidence requires contiguous, distinct, completed physical host cycles."
