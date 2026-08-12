#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/path/to/idlescreen.app /absolute/evidence-root snapshot-label" >&2
  exit 64
}

[[ $# -eq 3 ]] || usage

app_path="$1"
evidence_root="$2"
snapshot_label="$3"

[[ "$app_path" = /* && "$evidence_root" = /* ]] || usage
[[ "$snapshot_label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || usage
[[ "$evidence_root" != / ]] || usage

project_root="$(cd "$(dirname "$0")/.." && pwd)"
extension_path="$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex"
helper_path="$app_path/Contents/Helpers/IdleScreenCameraAgent.app"
app_info="$app_path/Contents/Info.plist"
extension_info="$extension_path/Contents/Info.plist"
helper_info="$helper_path/Contents/Info.plist"
snapshot_root="$evidence_root/$snapshot_label"
status_path="$snapshot_root/status.tsv"

[[ -f "$app_info" ]] || {
  echo "FAIL: missing app Info.plist at $app_info" >&2
  exit 2
}
[[ -f "$extension_info" ]] || {
  echo "FAIL: missing extension Info.plist at $extension_info" >&2
  exit 2
}
[[ -f "$helper_info" ]] || {
  echo "FAIL: missing camera-helper Info.plist at $helper_info" >&2
  exit 2
}
[[ ! -e "$snapshot_root" ]] || {
  echo "FAIL: refusing to overwrite existing snapshot $snapshot_root" >&2
  exit 2
}

mkdir -p "$snapshot_root"
: >"$status_path"

record_command() {
  local output_name="$1"
  shift
  local command_status

  set +e
  "$@" >"$snapshot_root/$output_name" 2>&1
  command_status=$?
  set -e
  printf '%s\t%s\n' "$output_name" "$command_status" >>"$status_path"
  return 0
}

write_online_displays() {
  printf 'displayID\tname\tlogicalResolution\tpixelResolution\tmain\tmirror\n'
  /usr/bin/plutil \
    -extract SPDisplaysDataType.0.spdisplays_ndrvs json \
    -o - \
    "$snapshot_root/display-topology.json" |
    /usr/bin/jq -r '
      .[]
      | select(.spdisplays_online == "spdisplays_yes")
      | [
          ._spdisplays_displayID,
          ._name,
          .spdisplays_resolution,
          .spdisplays_pixelresolution,
          .spdisplays_main,
          .spdisplays_mirror
        ]
      | map(. // "")
      | @tsv
    '
}

write_space_configuration() {
  /usr/bin/defaults export com.apple.spaces - 2>/dev/null
}

write_current_spaces() {
  printf 'displayIdentifier\tmanagedSpaceID\tuuid\tspaceCount\n'
  /usr/bin/plutil \
    -extract 'SpacesDisplayConfiguration.Management Data.Monitors' json \
    -o - \
    "$snapshot_root/space-configuration.plist" |
    /usr/bin/jq -r '
      .[]
      | select(has("Current Space"))
      | [
          .["Display Identifier"],
          .["Current Space"].ManagedSpaceID,
          .["Current Space"].uuid,
          ((.Spaces // []) | length)
        ]
      | map(. // "")
      | @tsv
    '
}

write_power_history() {
  /usr/bin/pmset -g log |
    /usr/bin/awk '
      /Display is turned (on|off)/ ||
      /Entering Sleep/ ||
      /Wake from/ ||
      /DarkWake/ ||
      /Sleep.*due to/ ||
      /Wake Requests/ ||
      /Total Sleep\/Wakes/ {
        print
      }
    ' |
    /usr/bin/tail -1000
}

write_console_lock_state() {
  "$project_root/scripts/read-console-lock-state.sh"
}

signed_value() {
  local product_path="$1"
  local key="$2"

  /usr/bin/codesign -dv --verbose=4 "$product_path" 2>&1 |
    /usr/bin/awk -F= -v key="$key" '!found && $1 == key { print $2; found = 1 }'
}

write_product_identities() {
  printf 'appPath=%s\n' "$(/bin/realpath "$app_path")"
  printf 'appBundleIdentifier=%s\n' "$app_id"
  printf 'appExecutable=%s\n' "$app_executable_name"
  printf 'appSigningIdentifier=%s\n' "$app_signing_identifier"
  printf 'appTeamIdentifier=%s\n' "$app_team_identifier"
  printf 'appCDHash=%s\n' "$app_cdhash"
  printf 'extensionPath=%s\n' "$(/bin/realpath "$extension_path")"
  printf 'extensionBundleIdentifier=%s\n' "$extension_id"
  printf 'extensionExecutable=%s\n' "$extension_executable_name"
  printf 'extensionSigningIdentifier=%s\n' "$extension_signing_identifier"
  printf 'extensionTeamIdentifier=%s\n' "$extension_team_identifier"
  printf 'extensionCDHash=%s\n' "$extension_cdhash"
  printf 'helperPath=%s\n' "$(/bin/realpath "$helper_path")"
  printf 'helperBundleIdentifier=%s\n' "$helper_id"
  printf 'helperExecutable=%s\n' "$helper_executable_name"
  printf 'helperSigningIdentifier=%s\n' "$helper_signing_identifier"
  printf 'helperTeamIdentifier=%s\n' "$helper_team_identifier"
  printf 'helperCDHash=%s\n' "$helper_cdhash"
  printf 'machServiceName=%s\n' "$mach_service_name"
  printf 'launchAgentPath=%s\n' "$(/bin/realpath "$launch_agent_path")"
  printf 'launchAgentLabel=%s\n' "$launch_agent_label"
  printf 'launchAgentBundleProgram=%s\n' "$launch_agent_bundle_program"
  printf 'launchAgentAssociatedBundleIdentifier=%s\n' "$launch_agent_associated_bundle_identifier"
  printf 'launchAgentMachServiceEnabled=%s\n' "$launch_agent_mach_service_enabled"
  printf 'launchAgentProcessType=%s\n' "$launch_agent_process_type"
}

write_hash_record() {
  local role="$1"
  local path="$2"
  local digest

  digest="$(/usr/bin/shasum -a 256 "$path" | /usr/bin/awk '{ print $1; exit }')"
  [[ "$digest" =~ ^[[:xdigit:]]{64}$ ]] || return 1
  printf '%s\t%s\t%s\n' "$role" "$digest" "$(/bin/realpath "$path")"
}

write_product_hashes() {
  write_hash_record app "$app_executable"
  write_hash_record extension "$extension_executable"
  write_hash_record camera-helper "$helper_executable"
  write_hash_record launch-agent "$launch_agent_path"
}

write_helper_launchd_observation() {
  local domain_target="gui/$console_uid/$mach_service_name"
  local print_status
  local job_available=false
  local label_match=false
  local program_match=false
  local observed_state
  local observed_pid

  set +e
  /bin/launchctl print "$domain_target" >"$snapshot_root/helper-launchd-job.txt" 2>&1
  print_status=$?
  set -e

  if [[ "$print_status" -eq 0 ]]; then
    job_available=true
  fi
  if /usr/bin/awk -v target="$domain_target" '
    NR == 1 && $0 == target " = {" { found = 1 }
    END { exit(found ? 0 : 1) }
  ' "$snapshot_root/helper-launchd-job.txt"; then
    label_match=true
  fi
  if /usr/bin/awk -F ' = ' \
    -v absolute_program="$helper_executable" \
    -v bundle_program="$launch_agent_bundle_program" '
      {
        key = $1
        sub(/^[[:space:]]*/, "", key)
        if ((key == "program" && $2 == absolute_program) ||
            (key == "bundle program" && $2 == bundle_program)) {
          found = 1
        }
      }
      END { exit(found ? 0 : 1) }
    ' "$snapshot_root/helper-launchd-job.txt"; then
    program_match=true
  fi
  observed_state="$(/usr/bin/awk -F ' = ' '
    /^[[:space:]]*state = / { print $2; exit }
  ' "$snapshot_root/helper-launchd-job.txt")"
  observed_pid="$(/usr/bin/awk -F ' = ' '
    /^[[:space:]]*pid = / { print $2; exit }
  ' "$snapshot_root/helper-launchd-job.txt")"

  printf 'domainTarget=%s\n' "$domain_target"
  printf 'configuredLabel=%s\n' "$mach_service_name"
  printf 'configuredHelperExecutable=%s\n' "$helper_executable"
  printf 'printExitStatus=%s\n' "$print_status"
  printf 'jobAvailable=%s\n' "$job_available"
  printf 'jobOutputLabelMatch=%s\n' "$label_match"
  printf 'jobOutputProgramMatch=%s\n' "$program_match"
  printf 'observedState=%s\n' "$observed_state"
  printf 'observedPID=%s\n' "$observed_pid"
}

write_camera_helper_processes() {
  printf 'pid\tppid\tuid\texecutable\n'
  /bin/ps -ww -axo pid=,ppid=,uid=,comm= |
    /usr/bin/awk '/IdleScreenCameraAgent/ {
      printf "%s\t%s\t%s\t%s\n", $1, $2, $3, $4
    }'
}

app_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$app_info")"
extension_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$extension_info")"
helper_id="$(/usr/bin/plutil -extract CFBundleIdentifier raw "$helper_info")"
app_executable_name="$(/usr/bin/plutil -extract CFBundleExecutable raw "$app_info")"
extension_executable_name="$(/usr/bin/plutil -extract CFBundleExecutable raw "$extension_info")"
helper_executable_name="$(/usr/bin/plutil -extract CFBundleExecutable raw "$helper_info")"
mach_service_name="$(/usr/bin/plutil -extract IdleScreenCameraAgentMachServiceName raw "$app_info")"
launch_agent_path="$app_path/Contents/Library/LaunchAgents/$mach_service_name.plist"
app_executable="$app_path/Contents/MacOS/$app_executable_name"
extension_executable="$extension_path/Contents/MacOS/$extension_executable_name"
helper_executable="$helper_path/Contents/MacOS/$helper_executable_name"
console_uid="$(/usr/bin/id -u)"

[[ -f "$launch_agent_path" ]] || {
  echo "FAIL: missing camera LaunchAgent at $launch_agent_path" >&2
  exit 2
}
[[ -x "$app_executable" && -x "$extension_executable" && -x "$helper_executable" ]] || {
  echo "FAIL: one or more expected product executables are missing" >&2
  exit 2
}

launch_agent_label="$(/usr/bin/plutil -extract Label raw "$launch_agent_path")"
launch_agent_bundle_program="$(/usr/bin/plutil -extract BundleProgram raw "$launch_agent_path")"
launch_agent_associated_bundle_identifier="$(
  /usr/bin/plutil -extract AssociatedBundleIdentifiers raw "$launch_agent_path"
)"
launch_agent_mach_service_enabled="$(
  /usr/libexec/PlistBuddy -c "Print :MachServices:$mach_service_name" "$launch_agent_path"
)"
launch_agent_process_type="$(/usr/bin/plutil -extract ProcessType raw "$launch_agent_path")"
app_signing_identifier="$(signed_value "$app_path" Identifier)"
app_team_identifier="$(signed_value "$app_path" TeamIdentifier)"
app_cdhash="$(signed_value "$app_path" CDHash)"
extension_signing_identifier="$(signed_value "$extension_path" Identifier)"
extension_team_identifier="$(signed_value "$extension_path" TeamIdentifier)"
extension_cdhash="$(signed_value "$extension_path" CDHash)"
helper_signing_identifier="$(signed_value "$helper_path" Identifier)"
helper_team_identifier="$(signed_value "$helper_path" TeamIdentifier)"
helper_cdhash="$(signed_value "$helper_path" CDHash)"

[[ "$launch_agent_label" == "$mach_service_name" ]] || {
  echo "FAIL: camera LaunchAgent label does not match the configured Mach service" >&2
  exit 2
}
[[ "$launch_agent_bundle_program" == 'Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent' ]] || {
  echo "FAIL: camera LaunchAgent BundleProgram is not the embedded helper" >&2
  exit 2
}
[[ "$launch_agent_associated_bundle_identifier" == "$app_id" ]] || {
  echo "FAIL: camera LaunchAgent is not associated with the containing app" >&2
  exit 2
}
[[ "$launch_agent_mach_service_enabled" == true ]] || {
  echo "FAIL: camera LaunchAgent does not enable its configured Mach service" >&2
  exit 2
}
[[ "$launch_agent_process_type" == Interactive ]] || {
  echo "FAIL: camera LaunchAgent has the wrong ProcessType" >&2
  exit 2
}
[[ "$app_signing_identifier" == "$app_id" &&
   "$extension_signing_identifier" == "$extension_id" &&
   "$helper_signing_identifier" == "$helper_id" ]] || {
  echo "FAIL: one or more code-signing identifiers do not match their bundle identifiers" >&2
  exit 2
}
[[ -n "$app_team_identifier" &&
   "$app_team_identifier" == "$extension_team_identifier" &&
   "$app_team_identifier" == "$helper_team_identifier" ]] || {
  echo "FAIL: app, extension, and camera helper do not share one signing team" >&2
  exit 2
}
[[ "$app_cdhash" =~ ^[[:xdigit:]]{40,64}$ &&
   "$extension_cdhash" =~ ^[[:xdigit:]]{40,64}$ &&
   "$helper_cdhash" =~ ^[[:xdigit:]]{40,64}$ ]] || {
  echo "FAIL: one or more code-signing CDHashes are missing or malformed" >&2
  exit 2
}
selection_probe="$snapshot_root/selection-probe"

{
  printf 'capturedAtUTC=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  printf 'appPath=%s\n' "$(/bin/realpath "$app_path")"
  printf 'appBundleIdentifier=%s\n' "$app_id"
  printf 'extensionPath=%s\n' "$(/bin/realpath "$extension_path")"
  printf 'extensionBundleIdentifier=%s\n' "$extension_id"
  printf 'helperPath=%s\n' "$(/bin/realpath "$helper_path")"
  printf 'helperBundleIdentifier=%s\n' "$helper_id"
  printf 'machServiceName=%s\n' "$mach_service_name"
  printf 'launchAgentPath=%s\n' "$(/bin/realpath "$launch_agent_path")"
  printf 'snapshotLabel=%s\n' "$snapshot_label"
} >"$snapshot_root/manifest.txt"

record_command product-identities.txt write_product_identities
record_command sw-vers.txt /usr/bin/sw_vers
record_command xcode-version.txt xcodebuild -version
record_command boot-session.txt /usr/sbin/sysctl kern.boottime kern.bootsessionuuid
record_command app-signature.txt /usr/bin/codesign -dv --verbose=4 "$app_path"
record_command extension-signature.txt /usr/bin/codesign -dv --verbose=4 "$extension_path"
record_command helper-signature.txt /usr/bin/codesign -dv --verbose=4 "$helper_path"
record_command app-entitlements.plist /usr/bin/codesign -d --entitlements :- "$app_path"
record_command extension-entitlements.plist /usr/bin/codesign -d --entitlements :- "$extension_path"
record_command helper-entitlements.plist /usr/bin/codesign -d --entitlements :- "$helper_path"
record_command app-signature-verification.txt /usr/bin/codesign --verify --deep --strict --verbose=4 "$app_path"
record_command helper-signature-verification.txt /usr/bin/codesign --verify --strict --verbose=4 "$helper_path"
record_command screen-saver-registrations.txt /usr/bin/pluginkit -m -A -D -v -p com.apple.screensaver
record_command display-topology.json /usr/sbin/system_profiler SPDisplaysDataType -json
record_command online-displays.tsv write_online_displays
record_command space-configuration.plist write_space_configuration
record_command current-spaces.tsv write_current_spaces
record_command power-settings.txt /usr/bin/pmset -g custom
record_command power-assertions.txt /usr/bin/pmset -g assertions
record_command power-history.txt write_power_history

xcrun swiftc \
  "$project_root/IdleScreenSystem/ScreenSaverSelection.swift" \
  "$project_root/scripts/ScreenSaverSelectionProbe.swift" \
  -o "$selection_probe"
record_command selection.txt "$selection_probe" "$extension_id"

record_command console-locked.txt write_console_lock_state
record_command helper-launchd-observation.txt write_helper_launchd_observation
record_command camera-helper-processes.tsv write_camera_helper_processes

/bin/ps -ww -axo pid=,ppid=,etime=,comm= |
  awk '/WallpaperAgent|ScreenSaverEngine|IdleScreenScreenSaver|IdleScreenCameraAgent|\/Applications\/idlescreen\.app\/|legacyScreenSaver|IdlescreenHelper/ { print }' \
    >"$snapshot_root/relevant-processes.txt"
printf 'relevant-processes.txt\t0\n' >>"$status_path"

{
  /usr/bin/find /Applications -maxdepth 2 \
    \( -iname '*idlescreen*.app' -o -iname '*idlescreen*.saver' \) -print 2>/dev/null
  /usr/bin/find "$HOME/Applications" -maxdepth 2 \
    \( -iname '*idlescreen*.app' -o -iname '*idlescreen*.saver' \) -print 2>/dev/null
  /usr/bin/find "$HOME/Library/Screen Savers" -maxdepth 2 \
    \( -iname '*idlescreen*.app' -o -iname '*idlescreen*.saver' \) -print 2>/dev/null
} | sort -u >"$snapshot_root/physical-copies.txt"
printf 'physical-copies.txt\t0\n' >>"$status_path"

record_command product-sha256.txt write_product_hashes

shared_container="$HOME/Library/Group Containers/group.com.idlescreen.shared"
if [[ -d "$shared_container" ]]; then
  mkdir -p "$snapshot_root/shared-state"
  [[ ! -f "$shared_container/configuration.json" ]] ||
    /usr/bin/ditto "$shared_container/configuration.json" "$snapshot_root/shared-state/configuration.json"
  [[ ! -d "$shared_container/Health" ]] ||
    /usr/bin/ditto "$shared_container/Health" "$snapshot_root/shared-state/Health"
fi

if ! awk -F '\t' 'NF != 2 || $2 != "0" { exit 1 }' "$status_path"; then
  echo "FAIL: one or more snapshot commands failed:" >&2
  awk -F '\t' 'NF != 2 || $2 != "0" { print "  " $0 }' "$status_path" >&2
  echo "Evidence: $snapshot_root" >&2
  exit 1
fi

echo "PASS: captured read-only Phase 1 physical state."
echo "Evidence: $snapshot_root"
