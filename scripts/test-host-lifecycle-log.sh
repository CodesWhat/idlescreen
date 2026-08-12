#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
verifier="$project_root/scripts/verify-host-lifecycle-log.sh"
cycle_verifier="$project_root/scripts/verify-host-lifecycle-cycle-log.sh"
multidisplay_verifier="$project_root/scripts/verify-multidisplay-lifecycle-log.sh"
fixture_root="$(mktemp -d /tmp/idlescreen-host-log-tests.XXXXXX)"
trap 'rm -rf "$fixture_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

run_verifier() {
  local fixture="$1"
  local expected_preview="$2"
  set +e
  "$verifier" "$fixture" "$expected_preview" >/dev/null 2>&1
  local status=$?
  set -e
  return "$status"
}

[[ -x "$verifier" ]] || fail "missing executable host lifecycle log verifier"
[[ -x "$cycle_verifier" ]] || fail "missing executable completed-cycle log verifier"
[[ -x "$multidisplay_verifier" ]] || fail "missing executable multi-display lifecycle log verifier"

success_log="$fixture_root/success.log"
printf '%s\n' \
  'IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:Extension] Extension initialized pid=2042 compatible=true' \
  'IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:ViewController] Loading view width=1920.000000 height=1080.000000 preview=false' \
  'IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Global host activity state=inactive source=start-animation changed=false cameraDemand=false' \
  'IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Animation started preview=false instance=view-2042 display=2' \
  >"$success_log"

run_verifier "$success_log" false || fail "complete full-screen lifecycle was rejected"

missing_host_activity_log="$fixture_root/missing-host-activity.log"
sed '/Global host activity/d' "$success_log" >"$missing_host_activity_log"
if run_verifier "$missing_host_activity_log" false; then
  fail "a lifecycle without correlated global host-activity evidence was accepted"
else
  [[ "$?" -eq 1 ]] || fail "missing host-activity evidence must be incomplete, not fatal"
fi

cross_pid_host_activity_log="$fixture_root/cross-pid-host-activity.log"
sed '/Global host activity/s/IdleScreenScreenSaver\[2042:/IdleScreenScreenSaver[9090:/' \
  "$success_log" >"$cross_pid_host_activity_log"
if run_verifier "$cross_pid_host_activity_log" false; then
  fail "host-activity evidence from a different saver PID was accepted"
else
  [[ "$?" -eq 1 ]] || fail "a missing same-PID host-activity record must be incomplete"
fi

stale_instance_activity_log="$fixture_root/stale-instance-activity.log"
{
  sed '$d' "$success_log"
  printf '%s\n' \
    'IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Animation started preview=false instance=older-view display=2' \
    'IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Animation started preview=false instance=current-view display=2'
} >"$stale_instance_activity_log"
if run_verifier "$stale_instance_activity_log" false; then
  fail "host activity belonging to an earlier saver instance was reused"
else
  [[ "$?" -eq 1 ]] || fail "missing activity for the selected saver instance must be incomplete"
fi

camera_demand_log="$fixture_root/camera-demand.log"
sed 's/cameraDemand=false/cameraDemand=true/' "$success_log" >"$camera_demand_log"
run_verifier "$camera_demand_log" false ||
  fail "the current cameraDemand=true host-activity schema was rejected"

retired_host_activity_log="$fixture_root/retired-host-activity.log"
sed 's/cameraDemand=false/trusted=false/' "$success_log" >"$retired_host_activity_log"
if run_verifier "$retired_host_activity_log" false; then
  fail "the retired trusted=false host-activity schema was accepted"
else
  [[ "$?" -eq 2 ]] || fail "retired host-activity evidence must be fatal"
fi

malformed_host_activity_log="$fixture_root/malformed-host-activity.log"
sed 's/state=inactive/state=authoritative-full-screen/' \
  "$success_log" >"$malformed_host_activity_log"
if run_verifier "$malformed_host_activity_log" false; then
  fail "an unknown global host-activity state was accepted"
else
  [[ "$?" -eq 2 ]] || fail "malformed host-activity evidence must be fatal"
fi

missing_instance_log="$fixture_root/missing-instance.log"
sed 's/ instance=view-2042 display=2//' "$success_log" >"$missing_instance_log"
if run_verifier "$missing_instance_log" false; then
  fail "host-activity evidence without an exact lifecycle instance was accepted"
else
  [[ "$?" -eq 2 ]] || fail "an unidentifiable lifecycle instance must be fatal"
fi

for diagnostic_state in \
  unavailable inactive running-foreground running-background inconsistent; do
  state_log="$fixture_root/state-$diagnostic_state.log"
  sed "s/state=inactive/state=$diagnostic_state/" "$success_log" >"$state_log"
  run_verifier "$state_log" false ||
    fail "non-authoritative diagnostic state $diagnostic_state was incorrectly rejected"
done

if run_verifier "$success_log" true; then
  fail "full-screen lifecycle was accepted as a preview lifecycle"
else
  [[ "$?" -eq 1 ]] || fail "preview mismatch must be incomplete, not fatal"
fi

incomplete_log="$fixture_root/incomplete.log"
printf '%s\n' \
  'IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:Extension] Extension initialized pid=2042 compatible=true' \
  'IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:ViewController] Loading view width=1920.000000 height=1080.000000 preview=false' \
  >"$incomplete_log"

if run_verifier "$incomplete_log" false; then
  fail "lifecycle without animation start was accepted"
else
  [[ "$?" -eq 1 ]] || fail "missing lifecycle evidence must be incomplete, not fatal"
fi

xctest_spoof_log="$fixture_root/xctest-spoof.log"
printf '%s\n' \
  'xctest[2042:55c] [com.idlescreen.screensaver:Extension] Extension initialized pid=2042 compatible=true' \
  'xctest[2042:55c] [com.idlescreen.screensaver:ViewController] Loading view width=1920.000000 height=1080.000000 preview=false' \
  'xctest[2042:55c] [com.idlescreen.screensaver:View] Animation started preview=false' \
  >"$xctest_spoof_log"

if run_verifier "$xctest_spoof_log" false; then
  fail "unit-test lifecycle logs were accepted as a physical extension run"
else
  [[ "$?" -eq 1 ]] || fail "unit-test lifecycle logs must be incomplete, not fatal"
fi

fatal_log="$fixture_root/fatal.log"
printf '%s\n' \
  'IdleScreenScreenSaver [com.idlescreen.screensaver:Extension] Extension initialized pid=2042 compatible=true' \
  "WallpaperAgent readyController error: ViewBridge Code=14 NSInvalidArgumentException 'representedView: unrecognized selector'" \
  >"$fatal_log"

if run_verifier "$fatal_log" false; then
  fail "ViewBridge selector failure was accepted"
else
  [[ "$?" -eq 2 ]] || fail "known host failure must be fatal"
fi

module_resolution_log="$fixture_root/module-resolution.log"
printf '%s\n' \
  '2026-07-31 20:47:37.698 Df WallpaperAgent[77296:55c] [com.apple.ScreenSaver] Failed to find screen saver module at /Users/test/Applications/idlescreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex' \
  '2026-07-31 20:47:37.699 E  WallpaperAgent[77296:55c] [com.apple.ScreenSaver] Failed to translate LiveContentKey for third-party screen saver' \
  '2026-07-31 20:47:37.700 Df WallpaperAgent[77296:55c] [com.apple.ScreenSaver] contentSettingsFailedToTranslate provider=com.apple.wallpaper.choice.aerials' \
  >"$module_resolution_log"

if run_verifier "$module_resolution_log" false; then
  fail "WallpaperAgent module-resolution fallback was accepted"
else
  [[ "$?" -eq 2 ]] || fail "module-resolution fallback must be fatal"
fi

legacy_renderer_log="$fixture_root/legacy-renderer.log"
printf '%s\n' \
  '2026-07-31 20:47:37.698 Df legacyScreenSaver[28048:55c] [com.idlescreen.screensaver:View] Animation started preview=false' \
  >"$legacy_renderer_log"

if run_verifier "$legacy_renderer_log" false; then
  fail "legacy screen-saver renderer was accepted as the modern extension"
else
  [[ "$?" -eq 2 ]] || fail "legacy renderer evidence must be fatal"
fi

completed_cycle_log="$fixture_root/completed-cycle.log"
printf '%s\n' \
  'IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:Extension] Extension initialized pid=2042 compatible=true' \
  'IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:ViewController] Loading view width=1920.000000 height=1080.000000 preview=false' \
  'IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Global host activity state=running-background source=start-animation changed=true cameraDemand=false' \
  'IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Animation started preview=false instance=view-2042 display=2' \
  'IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Animation stopped preview=false instance=view-2042 display=2' \
  >"$completed_cycle_log"

"$cycle_verifier" "$completed_cycle_log" false >/dev/null 2>&1 ||
  fail "a lifecycle with start and stop evidence was rejected as incomplete"

cross_instance_stop_log="$fixture_root/cross-instance-stop.log"
sed '/Animation stopped/s/instance=view-2042/instance=other-view/' \
  "$completed_cycle_log" >"$cross_instance_stop_log"
if "$cycle_verifier" "$cross_instance_stop_log" false >/dev/null 2>&1; then
  fail "invalidation from another saver instance was accepted"
else
  [[ "$?" -eq 1 ]] || fail "a missing same-instance invalidation must be incomplete"
fi

prefix_instance_stop_log="$fixture_root/prefix-instance-stop.log"
sed '/Animation stopped/s/instance=view-2042/instance=view-20420/' \
  "$completed_cycle_log" >"$prefix_instance_stop_log"
if "$cycle_verifier" "$prefix_instance_stop_log" false >/dev/null 2>&1; then
  fail "a saver-instance prefix collision was accepted as exact invalidation"
else
  [[ "$?" -eq 1 ]] || fail "a saver-instance prefix collision must be incomplete"
fi

if "$cycle_verifier" "$success_log" false >/dev/null 2>&1; then
  fail "a lifecycle without invalidation evidence was accepted as a completed cycle"
else
  [[ "$?" -eq 1 ]] || fail "missing invalidation evidence must be incomplete, not fatal"
fi

stale_stop_log="$fixture_root/stale-stop.log"
printf '%s\n' \
  'IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Animation stopped preview=false instance=view-2042 display=2' \
  'IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:Extension] Extension initialized pid=2042 compatible=true' \
  'IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:ViewController] Loading view width=1920.000000 height=1080.000000 preview=false' \
  'IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Global host activity state=inactive source=start-animation changed=false cameraDemand=false' \
  'IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Animation started preview=false instance=view-2042 display=2' \
  >"$stale_stop_log"

if "$cycle_verifier" "$stale_stop_log" false >/dev/null 2>&1; then
  fail "stale invalidation evidence before animation start was accepted"
else
  [[ "$?" -eq 1 ]] || fail "stale invalidation evidence must be incomplete, not fatal"
fi

short_cycle_log="$fixture_root/short-cycle.log"
printf '%s\n' \
  '2026-07-31 20:01:53.000 Df IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:Extension] Extension initialized pid=2042 compatible=true' \
  '2026-07-31 20:01:53.050 Df IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:ViewController] Loading view width=1920.000000 height=1080.000000 preview=false' \
  '2026-07-31 20:01:53.075 Df IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Global host activity state=unavailable source=start-animation changed=false cameraDemand=false' \
  '2026-07-31 20:01:53.100 Df IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Animation started preview=false instance=view-2042 display=2' \
  '2026-07-31 20:01:54.000 Df IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Animation stopped preview=false instance=view-2042 display=2' \
  >"$short_cycle_log"

if "$cycle_verifier" "$short_cycle_log" false 3 >/dev/null 2>&1; then
  fail "an instant start/stop was accepted as a sustained lifecycle"
else
  [[ "$?" -eq 2 ]] || fail "a lifecycle shorter than the required duration must be fatal"
fi

sustained_cycle_log="$fixture_root/sustained-cycle.log"
printf '%s\n' \
  '2026-07-31 20:01:53.000 Df IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:Extension] Extension initialized pid=2042 compatible=true' \
  '2026-07-31 20:01:53.050 Df IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:ViewController] Loading view width=1920.000000 height=1080.000000 preview=false' \
  '2026-07-31 20:01:53.075 Df IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Global host activity state=inconsistent source=start-animation changed=true cameraDemand=false' \
  '2026-07-31 20:01:53.100 Df IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Animation started preview=false instance=view-2042 display=2' \
  '2026-07-31 20:01:59.000 Df IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Animation stopped preview=false instance=view-2042 display=2' \
  >"$sustained_cycle_log"

"$cycle_verifier" "$sustained_cycle_log" false 3 >/dev/null 2>&1 ||
  fail "a lifecycle longer than the required duration was rejected"

clean_process_exit_log="$fixture_root/clean-process-exit.log"
printf '%s\n' \
  '2026-08-01 07:37:42.849 I  IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:Extension] Extension initialized pid=2042 compatible=true' \
  '2026-08-01 07:37:42.855 I  IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:ViewController] Loading view width=1920.000000 height=1080.000000 preview=false' \
  '2026-08-01 07:37:42.860 I  IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Global host activity state=running-foreground source=start-animation changed=true cameraDemand=false' \
  '2026-08-01 07:37:42.873 I  IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Animation started preview=false instance=view-a display=2' \
  '2026-08-01 07:37:42.875 I  IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Global host activity state=running-foreground source=start-animation changed=false cameraDemand=false' \
  '2026-08-01 07:37:42.878 I  IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Animation started preview=false instance=view-b display=3' \
  '2026-08-01 07:37:54.761 I  launchservicesd[393:77c] [com.apple.launchservices:cas] ADDING: App:"idlescreen (Wallpaper)" pid:2042 exitStatus=0' \
  >"$clean_process_exit_log"

"$cycle_verifier" "$clean_process_exit_log" false 5 >/dev/null 2>&1 ||
  fail "Tahoe clean extension-process invalidation was rejected without a stopAnimation callback"
IDLESCREEN_MINIMUM_DISPLAY_SUSTAIN_SECONDS=5 \
  "$multidisplay_verifier" "$clean_process_exit_log" false 2 3 >/dev/null 2>&1 ||
  fail "one clean extension exit was rejected as teardown evidence for its two independent hosted views"

nonzero_process_exit_log="$fixture_root/nonzero-process-exit.log"
sed 's/exitStatus=0/exitStatus=9/' "$clean_process_exit_log" >"$nonzero_process_exit_log"
if "$cycle_verifier" "$nonzero_process_exit_log" false 5 >/dev/null 2>&1; then
  fail "a nonzero extension-process exit was accepted as clean invalidation"
else
  [[ "$?" -eq 2 ]] || fail "a nonzero extension-process exit must be fatal"
fi

cross_process_log="$fixture_root/cross-process.log"
printf '%s\n' \
  '2026-07-31 20:01:53.000 Df IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:Extension] Extension initialized pid=2042 compatible=true' \
  '2026-07-31 20:01:53.050 Df IdleScreenScreenSaver[4096:77c] [com.idlescreen.screensaver:ViewController] Loading view width=1920.000000 height=1080.000000 preview=false' \
  '2026-07-31 20:01:53.075 Df IdleScreenScreenSaver[4096:77c] [com.idlescreen.screensaver:View] Global host activity state=inactive source=start-animation changed=false cameraDemand=false' \
  '2026-07-31 20:01:53.100 Df IdleScreenScreenSaver[4096:77c] [com.idlescreen.screensaver:View] Animation started preview=false instance=view-4096 display=2' \
  '2026-07-31 20:01:59.000 Df IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Animation stopped preview=false instance=view-2042 display=2' \
  >"$cross_process_log"

if "$cycle_verifier" "$cross_process_log" false 3 >/dev/null 2>&1; then
  fail "lifecycle evidence assembled from different extension PIDs was accepted"
else
  [[ "$?" -eq 1 ]] || fail "cross-process lifecycle evidence must be incomplete, not fatal"
fi

multidisplay_log="$fixture_root/multidisplay.log"
printf '%s\n' \
  '2026-07-31 20:01:53.000 Df IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:Extension] Extension initialized pid=2042 compatible=true' \
  '2026-07-31 20:01:53.050 Df IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:ViewController] Loading view width=1920.000000 height=1080.000000 preview=false' \
  '2026-07-31 20:01:53.075 Df IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Global host activity state=running-background source=start-animation changed=true cameraDemand=false' \
  '2026-07-31 20:01:53.100 Df IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Animation started preview=false instance=view-a display=2' \
  '2026-07-31 20:01:53.150 Df IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Global host activity state=running-background source=start-animation changed=false cameraDemand=false' \
  '2026-07-31 20:01:53.200 Df IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Animation started preview=false instance=view-b display=3' \
  '2026-07-31 20:01:59.000 Df IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Animation stopped preview=false instance=view-a display=2' \
  '2026-07-31 20:01:59.100 Df IdleScreenScreenSaver[2042:55c] [com.idlescreen.screensaver:View] Animation stopped preview=false instance=view-b display=3' \
  '2026-07-31 20:02:00.000 Df xctest[9090:88c] [com.idlescreen.screensaver:View] Animation started preview=false instance=test-view display=2' \
  >"$multidisplay_log"

"$multidisplay_verifier" "$multidisplay_log" false 2 3 >/dev/null 2>&1 ||
  fail "complete independent lifecycle evidence for both displays was rejected"

IDLESCREEN_MINIMUM_DISPLAY_SUSTAIN_SECONDS=5 \
  "$multidisplay_verifier" "$multidisplay_log" false 2 3 >/dev/null 2>&1 ||
  fail "sustained independent lifecycle evidence for both displays was rejected"
if IDLESCREEN_MINIMUM_DISPLAY_SUSTAIN_SECONDS=7 \
  "$multidisplay_verifier" "$multidisplay_log" false 2 3 >/dev/null 2>&1; then
  fail "short per-display lifecycles were accepted as sustained"
else
  [[ "$?" -eq 2 ]] || fail "short per-display duration must be fatal"
fi

if "$multidisplay_verifier" "$multidisplay_log" false 2 3 4 >/dev/null 2>&1; then
  fail "missing lifecycle evidence for a requested display was accepted"
else
  [[ "$?" -eq 1 ]] || fail "a missing display lifecycle must be incomplete, not fatal"
fi

same_instance_log="$fixture_root/same-instance-multidisplay.log"
sed 's/instance=view-b/instance=view-a/g' "$multidisplay_log" >"$same_instance_log"
if "$multidisplay_verifier" "$same_instance_log" false 2 3 >/dev/null 2>&1; then
  fail "one hosted view instance was accepted as two independent displays"
else
  [[ "$?" -eq 2 ]] || fail "a reused display-view identity must be fatal"
fi

echo "PASS: host lifecycle logs distinguish complete, incomplete, and fatal runs."
