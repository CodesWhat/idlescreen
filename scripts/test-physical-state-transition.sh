#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
verifier="$project_root/scripts/verify-phase1-state-transition.sh"
capture="$project_root/scripts/capture-phase1-physical-state.sh"
fixture_root="$(mktemp -d /tmp/idlescreen-state-transition-tests.XXXXXX)"
fixture_uid="$(/usr/bin/id -u)"
trap 'rm -rf "$fixture_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

write_snapshot() {
  local root="$1"
  local boot_uuid="$2"
  local display_id="$3"
  local helper_job_available="${4:-false}"
  local helper_pid="${5:-}"
  local helper_executable='/Applications/idlescreen.app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent'

  mkdir -p "$root"
  printf 'capture.txt\t0\n' >"$root/status.tsv"
  printf 'kern.bootsessionuuid: %s\n' "$boot_uuid" >"$root/boot-session.txt"
  cat >"$root/product-identities.txt" <<'EOF'
appPath=/Applications/idlescreen.app
appBundleIdentifier=com.idlescreen.app
appExecutable=IdleScreen
appSigningIdentifier=com.idlescreen.app
appTeamIdentifier=3524374A2S
appCDHash=1111111111111111111111111111111111111111
extensionPath=/Applications/idlescreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex
extensionBundleIdentifier=com.idlescreen.app.screensaver
extensionExecutable=IdleScreenScreenSaver
extensionSigningIdentifier=com.idlescreen.app.screensaver
extensionTeamIdentifier=3524374A2S
extensionCDHash=2222222222222222222222222222222222222222
helperPath=/Applications/idlescreen.app/Contents/Helpers/IdleScreenCameraAgent.app
helperBundleIdentifier=com.idlescreen.camera-agent
helperExecutable=IdleScreenCameraAgent
helperSigningIdentifier=com.idlescreen.camera-agent
helperTeamIdentifier=3524374A2S
helperCDHash=3333333333333333333333333333333333333333
machServiceName=group.com.idlescreen.shared.camera-agent
launchAgentPath=/Applications/idlescreen.app/Contents/Library/LaunchAgents/group.com.idlescreen.shared.camera-agent.plist
launchAgentLabel=group.com.idlescreen.shared.camera-agent
launchAgentBundleProgram=Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent
launchAgentAssociatedBundleIdentifier=com.idlescreen.app
launchAgentMachServiceEnabled=true
launchAgentProcessType=Interactive
EOF
  printf '%s\t%s\t%s\n' \
    app aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    /Applications/idlescreen.app/Contents/MacOS/IdleScreen \
    extension bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    /Applications/idlescreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver \
    camera-helper cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc \
    /Applications/idlescreen.app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent \
    launch-agent dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd \
    /Applications/idlescreen.app/Contents/Library/LaunchAgents/group.com.idlescreen.shared.camera-agent.plist \
    >"$root/product-sha256.txt"
  printf 'providers=com.idlescreen.app.screensaver\nselectedEverywhere=true\n' >"$root/selection.txt"
  printf '+    com.idlescreen.app.screensaver(0.1)\tUUID-A\t2026-07-31 20:00:00 +0000\t/Applications/idlescreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex\n' >"$root/screen-saver-registrations.txt"
  printf '/Applications/idlescreen.app\n' >"$root/physical-copies.txt"
  printf 'displayID\tname\tlogicalResolution\tpixelResolution\tmain\tmirror\n%s\tDisplay\t1920 x 1080\t3840 x 2160\tspdisplays_yes\tspdisplays_off\n' "$display_id" >"$root/online-displays.tsv"
  printf 'displayIdentifier\tmanagedSpaceID\tuuid\tspaceCount\nMain\t1\tspace-a\t2\n' >"$root/current-spaces.tsv"
  printf '2026-07-31 19:00:00 -0400 Notification Display is turned on\n' >"$root/power-history.txt"
  printf 'false\n' >"$root/console-locked.txt"
  printf '101 1 00:10 /System/Library/CoreServices/WallpaperAgent.app/Contents/MacOS/WallpaperAgent\n' >"$root/relevant-processes.txt"
  printf 'pid\tppid\tuid\texecutable\n' >"$root/camera-helper-processes.tsv"

  if [[ "$helper_job_available" == true ]]; then
    {
      printf 'gui/%s/group.com.idlescreen.shared.camera-agent = {\n' "$fixture_uid"
      printf '\tstate = running\n'
      printf '\tprogram = %s\n' "$helper_executable"
      [[ -z "$helper_pid" ]] || printf '\tpid = %s\n' "$helper_pid"
      printf '}\n'
    } >"$root/helper-launchd-job.txt"
    cat >"$root/helper-launchd-observation.txt" <<EOF
domainTarget=gui/$fixture_uid/group.com.idlescreen.shared.camera-agent
configuredLabel=group.com.idlescreen.shared.camera-agent
configuredHelperExecutable=$helper_executable
printExitStatus=0
jobAvailable=true
jobOutputLabelMatch=true
jobOutputProgramMatch=true
observedState=running
observedPID=$helper_pid
EOF
  else
    printf 'Could not find service "group.com.idlescreen.shared.camera-agent" in domain for user gui: %s\n' \
      "$fixture_uid" \
      >"$root/helper-launchd-job.txt"
    cat >"$root/helper-launchd-observation.txt" <<EOF
domainTarget=gui/$fixture_uid/group.com.idlescreen.shared.camera-agent
configuredLabel=group.com.idlescreen.shared.camera-agent
configuredHelperExecutable=$helper_executable
printExitStatus=113
jobAvailable=false
jobOutputLabelMatch=false
jobOutputProgramMatch=false
observedState=
observedPID=
EOF
  fi

  if [[ -n "$helper_pid" ]]; then
    printf '%s\t1\t%s\t%s\n' "$helper_pid" "$fixture_uid" "$helper_executable" \
      >>"$root/camera-helper-processes.tsv"
    printf '%s 1 00:10 %s\n' "$helper_pid" "$helper_executable" \
      >>"$root/relevant-processes.txt"
  fi
}

before="$fixture_root/before"
after="$fixture_root/after"
write_snapshot "$before" boot-a 2
write_snapshot "$after" boot-a 2

[[ -x "$verifier" ]] || fail "missing executable Phase 1 state-transition verifier"
[[ -x "$capture" ]] || fail "missing executable Phase 1 physical-state capture"

# The recorder contract is checked statically so this fixture suite never observes
# or mutates the live machine while proving the evidence fields are wired.
grep -Fq 'product-identities.txt' "$capture" ||
  fail "physical capture does not record exact product identities"
grep -Fq 'appCDHash' "$capture" ||
  fail "physical capture does not bind evidence to code-signing CDHashes"
grep -Fq 'Contents/Helpers/IdleScreenCameraAgent.app' "$capture" ||
  fail "physical capture does not identify the camera helper"
grep -Fq 'Contents/Library/LaunchAgents' "$capture" ||
  fail "physical capture does not identify the LaunchAgent"
grep -Fq 'camera-helper-processes.tsv' "$capture" ||
  fail "physical capture does not record structured camera-helper processes"
grep -Fq '/bin/ps -ww -axo pid=,ppid=,uid=,comm=' "$capture" ||
  fail "physical capture may truncate the exact helper executable path"
grep -Fq 'helper-launchd-observation.txt' "$capture" ||
  fail "physical capture does not record launchd job availability"
grep -Fq '/bin/launchctl print' "$capture" ||
  fail "physical capture does not make a read-only launchd job observation"

"$verifier" "$before" "$after" same same >/dev/null ||
  fail "unchanged boot/display state was rejected"

write_snapshot "$before" boot-a 2 true 301
write_snapshot "$after" boot-a 2 true 902
"$verifier" "$before" "$after" same same >/dev/null ||
  fail "a registered camera helper remaining resident with a new PID was rejected"

sed -i '' 's#/Applications/idlescreen.app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent#/tmp/foreign/IdleScreenCameraAgent#' \
  "$after/helper-launchd-job.txt"
printf 'unrelated-note = %s\n' \
  '/Applications/idlescreen.app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent' \
  >>"$after/helper-launchd-job.txt"
if "$verifier" "$before" "$after" same same >/dev/null 2>&1; then
  fail "an unrelated launchd field was accepted as the helper job program"
fi
write_snapshot "$after" boot-a 2 true 902

sed -i '' 's/observedPID=902/observedPID=999/' "$after/helper-launchd-observation.txt"
if "$verifier" "$before" "$after" same same >/dev/null 2>&1; then
  fail "a helper process not owned by the observed launchd job PID was accepted"
fi
write_snapshot "$after" boot-a 2 true 902

sed -i '' 's/jobAvailable=true/jobAvailable=false/' "$after/helper-launchd-observation.txt"
if "$verifier" "$before" "$after" same same >/dev/null 2>&1; then
  fail "a camera helper without an available launchd job was accepted as idle"
fi
write_snapshot "$after" boot-a 2 true 902

write_snapshot "$before" boot-a 2 true
write_snapshot "$after" boot-a 2 false
if "$verifier" "$before" "$after" same same >/dev/null 2>&1; then
  fail "a camera LaunchAgent job disappearing across the transition was accepted"
fi
write_snapshot "$before" boot-a 2 true 301
write_snapshot "$after" boot-a 2 true 902

sed -i '' 's#/Applications/idlescreen.app/Contents/Helpers#/tmp/foreign/Helpers#' \
  "$after/camera-helper-processes.tsv"
if "$verifier" "$before" "$after" same same >/dev/null 2>&1; then
  fail "a camera helper running outside the canonical app was accepted"
fi
write_snapshot "$after" boot-a 2 true 902

printf '903\t1\t%s\t%s\n' "$fixture_uid" \
  '/Applications/idlescreen.app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent' \
  >>"$after/camera-helper-processes.tsv"
if "$verifier" "$before" "$after" same same >/dev/null 2>&1; then
  fail "multiple camera-helper processes were accepted"
fi
write_snapshot "$after" boot-a 2 true 902

sed -i '' 's/cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee/' \
  "$after/product-sha256.txt"
if "$verifier" "$before" "$after" same same >/dev/null 2>&1; then
  fail "a changed camera-helper executable hash was accepted"
fi
write_snapshot "$after" boot-a 2 true 902

sed -i '' 's/dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd/ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff/' \
  "$after/product-sha256.txt"
if "$verifier" "$before" "$after" same same >/dev/null 2>&1; then
  fail "a changed LaunchAgent hash was accepted"
fi
write_snapshot "$after" boot-a 2 true 902

sed -i '' 's/helperBundleIdentifier=com.idlescreen.camera-agent/helperBundleIdentifier=com.example.foreign/' \
  "$after/product-identities.txt"
if "$verifier" "$before" "$after" same same >/dev/null 2>&1; then
  fail "a snapshot with a foreign camera-helper identity was accepted"
fi
write_snapshot "$after" boot-a 2 true 902

sed -i '' 's/helperTeamIdentifier=3524374A2S/helperTeamIdentifier=FOREIGNTEAM/' \
  "$after/product-identities.txt"
if "$verifier" "$before" "$after" same same >/dev/null 2>&1; then
  fail "a snapshot with a foreign camera-helper signing team was accepted"
fi
write_snapshot "$after" boot-a 2 true 902

sed -i '' 's/UUID-A/UUID-B/' "$after/screen-saver-registrations.txt"
"$verifier" "$before" "$after" same same >/dev/null ||
  fail "a system-owned registration UUID refresh was rejected"

sed -i '' 's/boot-a/boot-b/' "$after/boot-session.txt"
"$verifier" "$before" "$after" changed same >/dev/null ||
  fail "a valid reboot transition was rejected"
if "$verifier" "$before" "$after" same same >/dev/null 2>&1; then
  fail "a changed boot session was accepted as sleep/wake"
fi

sed -i '' 's/boot-b/boot-a/' "$after/boot-session.txt"
sed -i '' $'s/^2\tDisplay/3\tDisplay/' "$after/online-displays.tsv"
"$verifier" "$before" "$after" same changed >/dev/null ||
  fail "a valid display-topology transition was rejected"
if "$verifier" "$before" "$after" same same >/dev/null 2>&1; then
  fail "a changed display topology was accepted as unchanged"
fi

cp "$before/online-displays.tsv" "$after/online-displays.tsv"
sed -i '' 's/space-a/space-b/' "$after/current-spaces.tsv"
"$verifier" "$before" "$after" same same changed >/dev/null ||
  fail "a valid current-Space transition was rejected"
if "$verifier" "$before" "$after" same same same >/dev/null 2>&1; then
  fail "a changed current Space was accepted as unchanged"
fi
cp "$before/current-spaces.tsv" "$after/current-spaces.tsv"

printf '%s\n' \
  '2026-07-31 20:00:00 -0400 Notification Display is turned off' \
  '2026-07-31 20:01:00 -0400 Notification Display is turned on' \
  >>"$after/power-history.txt"
"$verifier" "$before" "$after" same same same display-cycle >/dev/null ||
  fail "a valid display sleep/wake cycle was rejected"
if "$verifier" "$before" "$after" same same same system-cycle >/dev/null 2>&1; then
  fail "display sleep/wake was accepted as system sleep/wake"
fi

cp "$before/power-history.txt" "$after/power-history.txt"
printf '%s\n' \
  '2026-07-31 21:00:00 -0400 Sleep Entering Sleep state due to Idle Sleep' \
  '2026-07-31 21:01:00 -0400 Wake Wake from Normal Sleep' \
  >>"$after/power-history.txt"
"$verifier" "$before" "$after" same same same system-cycle >/dev/null ||
  fail "a valid system sleep/wake cycle was rejected"
cp "$before/power-history.txt" "$after/power-history.txt"

printf '27781 1 00:02 /Applications/idlescreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver\n' >>"$after/relevant-processes.txt"
if "$verifier" "$before" "$after" same same >/dev/null 2>&1; then
  fail "an orphaned screen-saver extension was accepted"
fi

sed -i '' '/IdleScreenScreenSaver/d' "$after/relevant-processes.txt"
printf 'capture.txt\t1\n' >"$after/status.tsv"
if "$verifier" "$before" "$after" same same >/dev/null 2>&1; then
  fail "an incomplete state snapshot was accepted"
fi

echo "PASS: Phase 1 state transitions reject changed invariants and orphan processes."
