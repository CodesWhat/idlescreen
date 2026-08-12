#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/before-snapshot /absolute/after-snapshot same|changed same|changed|ignore [same|changed|ignore-spaces] [display-cycle|system-cycle|ignore-power]" >&2
  exit 64
}

[[ $# -ge 4 && $# -le 6 ]] || usage

before="$1"
after="$2"
boot_expectation="$3"
display_expectation="$4"
space_expectation="${5:-ignore}"
power_expectation="${6:-ignore}"

[[ "$before" = /* && "$after" = /* ]] || usage
[[ "$boot_expectation" == same || "$boot_expectation" == changed ]] || usage
[[ "$display_expectation" == same || "$display_expectation" == changed || "$display_expectation" == ignore ]] || usage
[[ "$space_expectation" == same || "$space_expectation" == changed || "$space_expectation" == ignore ]] || usage
[[ "$power_expectation" == display-cycle || "$power_expectation" == system-cycle || "$power_expectation" == ignore ]] || usage

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

required_files=(
  status.tsv
  boot-session.txt
  product-identities.txt
  product-sha256.txt
  selection.txt
  screen-saver-registrations.txt
  physical-copies.txt
  online-displays.tsv
  current-spaces.tsv
  power-history.txt
  console-locked.txt
  relevant-processes.txt
  camera-helper-processes.tsv
  helper-launchd-observation.txt
  helper-launchd-job.txt
)

expected_helper_executable='/Applications/idlescreen.app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent'
expected_launch_agent='/Applications/idlescreen.app/Contents/Library/LaunchAgents/group.com.idlescreen.shared.camera-agent.plist'
expected_mach_service='group.com.idlescreen.shared.camera-agent'

identity_value() {
  local root="$1"
  local key="$2"

  /usr/bin/awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' \
    "$root/product-identities.txt"
}

observation_value() {
  local root="$1"
  local key="$2"

  /usr/bin/awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' \
    "$root/helper-launchd-observation.txt"
}

raw_launchd_job_has_label() {
  local root="$1"
  local target

  target="gui/$(/usr/bin/id -u)/$expected_mach_service"

  /usr/bin/awk -v target="$target" '
    NR == 1 && $0 == target " = {" { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$root/helper-launchd-job.txt"
}

raw_launchd_job_has_program() {
  local root="$1"
  local bundle_program='Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent'

  /usr/bin/awk -F ' = ' \
    -v absolute_program="$expected_helper_executable" \
    -v bundle_program="$bundle_program" '
      {
        key = $1
        sub(/^[[:space:]]*/, "", key)
        if ((key == "program" && $2 == absolute_program) ||
            (key == "bundle program" && $2 == bundle_program)) {
          found = 1
        }
      }
      END { exit(found ? 0 : 1) }
    ' "$root/helper-launchd-job.txt"
}

validate_product_identities() {
  local root="$1"
  local role="$2"
  local expected_lines=(
    'appPath=/Applications/idlescreen.app'
    'appBundleIdentifier=com.idlescreen.app'
    'appExecutable=IdleScreen'
    'appSigningIdentifier=com.idlescreen.app'
    'appTeamIdentifier=3524374A2S'
    'extensionPath=/Applications/idlescreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex'
    'extensionBundleIdentifier=com.idlescreen.app.screensaver'
    'extensionExecutable=IdleScreenScreenSaver'
    'extensionSigningIdentifier=com.idlescreen.app.screensaver'
    'extensionTeamIdentifier=3524374A2S'
    'helperPath=/Applications/idlescreen.app/Contents/Helpers/IdleScreenCameraAgent.app'
    'helperBundleIdentifier=com.idlescreen.camera-agent'
    'helperExecutable=IdleScreenCameraAgent'
    'helperSigningIdentifier=com.idlescreen.camera-agent'
    'helperTeamIdentifier=3524374A2S'
    "machServiceName=$expected_mach_service"
    "launchAgentPath=$expected_launch_agent"
    "launchAgentLabel=$expected_mach_service"
    'launchAgentBundleProgram=Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent'
    'launchAgentAssociatedBundleIdentifier=com.idlescreen.app'
    'launchAgentMachServiceEnabled=true'
    'launchAgentProcessType=Interactive'
  )
  local expected_line
  local product_role
  local cdhash

  [[ "$(/usr/bin/awk 'END { print NR + 0 }' "$root/product-identities.txt")" -eq 25 ]] ||
    fail "$role snapshot product identity manifest contains unexpected or missing fields"
  for expected_line in "${expected_lines[@]}"; do
    /usr/bin/grep -Fxq "$expected_line" "$root/product-identities.txt" ||
      fail "$role snapshot does not prove product identity: $expected_line"
  done
  for product_role in app extension helper; do
    cdhash="$(identity_value "$root" "${product_role}CDHash")"
    [[ "$cdhash" =~ ^[[:xdigit:]]{40,64}$ ]] ||
      fail "$role snapshot has a missing or malformed $product_role code-signing CDHash"
  done
}

validate_product_hashes() {
  local root="$1"
  local role="$2"
  local expected_paths=(
    "app|/Applications/idlescreen.app/Contents/MacOS/IdleScreen"
    "extension|/Applications/idlescreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver"
    "camera-helper|$expected_helper_executable"
    "launch-agent|$expected_launch_agent"
  )
  local expected

  [[ "$(/usr/bin/awk 'END { print NR + 0 }' "$root/product-sha256.txt")" -eq 4 ]] ||
    fail "$role snapshot must contain exactly four product hashes"
  /usr/bin/awk -F '\t' '
    NF != 3 { exit 1 }
    $2 !~ /^[[:xdigit:]]{64}$/ { exit 1 }
  ' "$root/product-sha256.txt" || fail "$role snapshot contains a malformed product hash"
  for expected in "${expected_paths[@]}"; do
    local expected_role="${expected%%|*}"
    local expected_path="${expected#*|}"
    /usr/bin/awk -F '\t' -v role="$expected_role" -v path="$expected_path" \
      '$1 == role && $3 == path { found = 1 } END { exit(found ? 0 : 1) }' \
      "$root/product-sha256.txt" ||
      fail "$role snapshot lacks the exact $expected_role hash target"
  done
}

validate_helper_runtime() {
  local root="$1"
  local role="$2"
  local job_available
  local helper_process_count
  local helper_process_pid
  local observed_pid
  local observed_state

  [[ "$(/usr/bin/awk 'END { print NR + 0 }' "$root/helper-launchd-observation.txt")" -eq 9 ]] ||
    fail "$role snapshot launchd observation contains unexpected or missing fields"

  [[ "$(observation_value "$root" domainTarget)" == "gui/$(/usr/bin/id -u)/$expected_mach_service" ]] ||
    fail "$role snapshot launchd observation targets the wrong per-user job"
  [[ "$(observation_value "$root" configuredLabel)" == "$expected_mach_service" ]] ||
    fail "$role snapshot launchd observation has the wrong configured label"
  [[ "$(observation_value "$root" configuredHelperExecutable)" == "$expected_helper_executable" ]] ||
    fail "$role snapshot launchd observation has the wrong helper executable"

  job_available="$(observation_value "$root" jobAvailable)"
  observed_state="$(observation_value "$root" observedState)"
  observed_pid="$(observation_value "$root" observedPID)"
  [[ "$job_available" == true || "$job_available" == false ]] ||
    fail "$role snapshot has an invalid launchd job-availability value"
  if [[ "$job_available" == true ]]; then
    [[ "$(observation_value "$root" printExitStatus)" == 0 ]] ||
      fail "$role snapshot claims an available launchd job after a failed observation"
    [[ "$(observation_value "$root" jobOutputLabelMatch)" == true ]] ||
      fail "$role snapshot launchd job does not match the configured label"
    [[ "$(observation_value "$root" jobOutputProgramMatch)" == true ]] ||
      fail "$role snapshot launchd job does not match the embedded helper"
    raw_launchd_job_has_label "$root" ||
      fail "$role snapshot raw launchd job lacks the configured label"
    if ! raw_launchd_job_has_program "$root"; then
      fail "$role snapshot raw launchd job lacks the embedded helper program"
    fi
    [[ -n "$observed_state" ]] ||
      fail "$role snapshot available launchd job has no observed state"
    [[ -z "$observed_pid" || "$observed_pid" =~ ^[0-9]+$ ]] ||
      fail "$role snapshot launchd job has a malformed observed PID"
  else
    [[ "$(observation_value "$root" printExitStatus)" =~ ^[1-9][0-9]*$ ]] ||
      fail "$role snapshot claims an unavailable launchd job after a successful observation"
    [[ -z "$observed_state" && -z "$observed_pid" ]] ||
      fail "$role snapshot unavailable launchd job carries stale runtime state"
  fi

  /usr/bin/grep -Fxq $'pid\tppid\tuid\texecutable' "$root/camera-helper-processes.tsv" ||
    fail "$role snapshot camera-helper process manifest lacks its exact header"
  /usr/bin/awk -F '\t' -v expected="$expected_helper_executable" '
    NR == 1 { next }
    NF != 4 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ || $3 !~ /^[0-9]+$/ || $4 != expected {
      exit 1
    }
  ' "$root/camera-helper-processes.tsv" ||
    fail "$role snapshot contains a foreign or malformed camera-helper process"
  helper_process_count="$(/usr/bin/awk 'NR > 1 { count += 1 } END { print count + 0 }' \
    "$root/camera-helper-processes.tsv")"
  helper_process_pid="$(/usr/bin/awk -F '\t' 'NR == 2 { print $1; exit }' \
    "$root/camera-helper-processes.tsv")"
  [[ "$helper_process_count" -le 1 ]] ||
    fail "$role snapshot contains multiple camera-helper processes"
  if [[ "$helper_process_count" -eq 1 && "$job_available" != true ]]; then
    fail "$role snapshot contains an orphaned camera-helper process"
  fi
  if [[ "$helper_process_count" -eq 1 && "$observed_pid" != "$helper_process_pid" ]]; then
    fail "$role snapshot camera-helper PID does not match the observed launchd job"
  fi
  if [[ "$helper_process_count" -eq 0 && -n "$observed_pid" ]]; then
    fail "$role snapshot launchd job PID has no matching camera-helper process"
  fi

  local relevant_helper_count
  relevant_helper_count="$(
    /usr/bin/grep -Fc IdleScreenCameraAgent "$root/relevant-processes.txt" || true
  )"
  [[ "$relevant_helper_count" -eq "$helper_process_count" ]] ||
    fail "$role snapshot relevant-process manifest disagrees with the structured helper manifest"
  /usr/bin/awk -v expected="$expected_helper_executable" '
    /IdleScreenCameraAgent/ && index($0, expected) == 0 { exit 1 }
  ' "$root/relevant-processes.txt" ||
    fail "$role snapshot contains a camera helper outside the canonical app"
}

validate_snapshot() {
  local root="$1"
  local role="$2"
  local required_file

  [[ -d "$root" ]] || fail "$role snapshot is not a directory: $root"
  for required_file in "${required_files[@]}"; do
    [[ -f "$root/$required_file" ]] || fail "$role snapshot is missing $required_file"
  done

  if awk -F '\t' 'NF != 2 || $2 != "0" { exit 1 }' "$root/status.tsv"; then
    :
  else
    fail "$role snapshot contains an unsuccessful capture command"
  fi

  grep -Fxq 'selectedEverywhere=true' "$root/selection.txt" ||
    fail "$role snapshot does not prove the saver is selected everywhere"

  local registration_count
  registration_count="$(grep -Fc 'com.idlescreen.app.screensaver' "$root/screen-saver-registrations.txt")"
  [[ "$registration_count" -eq 1 ]] ||
    fail "$role snapshot has $registration_count idlescreen extension registrations instead of one"
  grep -Fq '/Applications/idlescreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex' "$root/screen-saver-registrations.txt" ||
    fail "$role snapshot is not registered to the canonical extension"

  [[ "$(grep -Fxc '/Applications/idlescreen.app' "$root/physical-copies.txt")" -eq 1 ]] ||
    fail "$role snapshot does not contain exactly one canonical app copy"

  [[ "$(tr -d '[:space:]' <"$root/console-locked.txt")" == false ]] ||
    fail "$role snapshot was captured while the console was locked"

  validate_product_identities "$root" "$role"
  validate_product_hashes "$root" "$role"
  validate_helper_runtime "$root" "$role"
}

boot_uuid() {
  awk -F ': ' '/kern.bootsessionuuid/ { print $2; exit }' "$1/boot-session.txt" | tr -d '[:space:]'
}

idlescreen_registrations() {
  awk -F '\t' '
    /com\.idlescreen\.app\.screensaver/ {
      identity = $1
      path = $NF
      sub(/^[+[:space:]]+/, "", identity)
      sub(/[[:space:]]+$/, "", identity)
      sub(/^[[:space:]]+/, "", path)
      sub(/[[:space:]]+$/, "", path)
      print identity "\t" path
    }
  ' "$1/screen-saver-registrations.txt" | sort
}

normalized_displays() {
  tail -n +2 "$1/online-displays.tsv" | sed '/^[[:space:]]*$/d' | sort
}

normalized_spaces() {
  tail -n +2 "$1/current-spaces.tsv" | sed '/^[[:space:]]*$/d' | sort
}

new_power_history() {
  grep -Fvx -f "$1/power-history.txt" "$2/power-history.txt" || true
}

validate_snapshot "$before" before
validate_snapshot "$after" after

cmp -s "$before/product-sha256.txt" "$after/product-sha256.txt" ||
  fail "installed app, extension, camera-helper, or LaunchAgent hashes changed across the transition"
cmp -s "$before/product-identities.txt" "$after/product-identities.txt" ||
  fail "installed product identities changed across the transition"
[[ "$(observation_value "$before" jobAvailable)" == "$(observation_value "$after" jobAvailable)" ]] ||
  fail "camera LaunchAgent job availability changed across the transition"
cmp -s "$before/selection.txt" "$after/selection.txt" ||
  fail "screen-saver selection changed across the transition"
[[ "$(idlescreen_registrations "$before")" == "$(idlescreen_registrations "$after")" ]] ||
  fail "idlescreen registration changed across the transition"
cmp -s "$before/physical-copies.txt" "$after/physical-copies.txt" ||
  fail "the physical idlescreen app-copy set changed across the transition"

before_boot="$(boot_uuid "$before")"
after_boot="$(boot_uuid "$after")"
[[ -n "$before_boot" && -n "$after_boot" ]] || fail "a boot-session UUID is missing"
if [[ "$boot_expectation" == same ]]; then
  [[ "$before_boot" == "$after_boot" ]] || fail "boot session changed unexpectedly"
else
  [[ "$before_boot" != "$after_boot" ]] || fail "reboot did not change the boot-session UUID"
fi

before_displays="$(normalized_displays "$before")"
after_displays="$(normalized_displays "$after")"
[[ -n "$before_displays" && -n "$after_displays" ]] || fail "an online-display manifest is empty"
if [[ "$display_expectation" == same ]]; then
  [[ "$before_displays" == "$after_displays" ]] || fail "online display topology changed unexpectedly"
elif [[ "$display_expectation" == changed ]]; then
  [[ "$before_displays" != "$after_displays" ]] || fail "online display topology did not change"
fi

before_spaces="$(normalized_spaces "$before")"
after_spaces="$(normalized_spaces "$after")"
[[ -n "$before_spaces" && -n "$after_spaces" ]] || fail "a current-Space manifest is empty"
if [[ "$space_expectation" == same ]]; then
  [[ "$before_spaces" == "$after_spaces" ]] || fail "current Space changed unexpectedly"
elif [[ "$space_expectation" == changed ]]; then
  [[ "$before_spaces" != "$after_spaces" ]] || fail "current Space did not change"
fi

power_transition_records="$(new_power_history "$before" "$after")"
if [[ "$power_expectation" == display-cycle ]]; then
  awk '
    /Display is turned off/ { display_off = 1 }
    display_off && /Display is turned on/ { display_cycle = 1 }
    END { exit(display_cycle ? 0 : 1) }
  ' <<<"$power_transition_records" ||
    fail "new power history does not contain an ordered display off/on cycle"
elif [[ "$power_expectation" == system-cycle ]]; then
  awk '
    /Entering Sleep/ || /Sleep.*due to/ { system_sleep = 1 }
    system_sleep && /Wake from/ { system_cycle = 1 }
    END { exit(system_cycle ? 0 : 1) }
  ' <<<"$power_transition_records" ||
    fail "new power history does not contain an ordered system sleep/wake cycle"
fi

if grep -Eq 'ScreenSaverEngine|IdleScreenScreenSaver|legacyScreenSaver|IdlescreenHelper' "$after/relevant-processes.txt"; then
  fail "screen-saver or legacy-helper processes remain after the transition"
fi

echo "PASS: Phase 1 physical state transition preserved the app/extension/helper/LaunchAgent topology, registration, selection, and cleanup invariants."
echo "PASS: boot session is $boot_expectation; online display topology is $display_expectation; current Space is $space_expectation; power transition is $power_expectation."
