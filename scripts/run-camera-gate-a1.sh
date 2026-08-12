#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /Applications/idlescreen.app /absolute/evidence-directory a1t --normal-host-activation-authorized" >&2
  echo "   or: $0 /Applications/idlescreen.app /absolute/evidence-directory a1tr --normal-host-activation-authorized --terminate-exact-synthetic-helper-once" >&2
  exit 64
}

[[ $# -eq 4 || $# -eq 5 ]] || usage
app_path="$1"
evidence_root="$2"
mode="$3"
activation_token="$4"
restart_token="${5:-}"
[[ "$app_path" == /Applications/idlescreen.app ]] || usage
[[ "$evidence_root" = /* && "$evidence_root" != / ]] || usage
[[ "$mode" == a1t || "$mode" == a1tr ]] || usage
[[ "$activation_token" == --normal-host-activation-authorized ]] || usage
if [[ "$mode" == a1tr ]]; then
  [[ "$restart_token" == --terminate-exact-synthetic-helper-once ]] || usage
else
  [[ -z "$restart_token" ]] || usage
fi

if [[ "${IDLESCREEN_ALLOW_PHYSICAL_TESTS:-NO}" != YES ||
      "${IDLESCREEN_ALLOW_CAMERA_GATE_A1T:-NO}" != YES ]]; then
  echo "REFUSED: both IDLESCREEN_ALLOW_PHYSICAL_TESTS=YES and IDLESCREEN_ALLOW_CAMERA_GATE_A1T=YES are required." >&2
  exit 65
fi

if [[ -n "${IDLESCREEN_PROCESS_GUARD_FIXTURE_MODE:-}" ||
      -n "${IDLESCREEN_PROCESS_GUARD_PS:-}" ||
      -n "${IDLESCREEN_PROCESS_GUARD_CODESIGN:-}" ]]; then
  echo "REFUSED: process-guard fixture overrides are forbidden in the physical runner." >&2
  exit 65
fi

project_root="$(cd "$(dirname "$0")/.." && pwd)"
verifier="$project_root/scripts/verify-camera-gate-a1-log.sh"
configuration_preflight="$project_root/scripts/verify-camera-gate-a1-config.py"
process_guard="$project_root/scripts/camera-gate-owned-process.sh"
helper_bundle="$app_path/Contents/Helpers/IdleScreenCameraAgent.app"
helper_info="$helper_bundle/Contents/Info.plist"
helper_executable="$helper_bundle/Contents/MacOS/IdleScreenCameraAgent"
extension_bundle="$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex"
extension_info="$extension_bundle/Contents/Info.plist"
extension_executable="$extension_bundle/Contents/MacOS/IdleScreenScreenSaver"
companion_executable="$app_path/Contents/MacOS/IdleScreen"
launch_agent_label="group.com.idlescreen.shared.camera-agent"
launch_agent_plist="$app_path/Contents/Library/LaunchAgents/$launch_agent_label.plist"
configuration_path="$HOME/Library/Group Containers/group.com.idlescreen.shared/configuration.json"
log_path="$evidence_root/combined.log"
checkpoint_path="$evidence_root/checkpoints.txt"
configuration_snapshot_path="$evidence_root/configuration-preflight.txt"
evidence_manifest_path="$evidence_root/evidence-manifest.txt"
helper_marker_extract_path="$evidence_root/helper-marker-extract.txt"
extension_marker_extract_path="$evidence_root/extension-marker-extract.txt"
helper_codesign_output_path="$evidence_root/helper-codesign.txt"
extension_codesign_output_path="$evidence_root/extension-codesign.txt"
log_stream_pid=""
log_stream_cdhash=""
log_stream_identity=""
initial_helper_pid=""
initial_helper_class=""
initial_helper_identity=""
initial_helper_procinfo_path=""
recovered_helper_pid=""
recovered_helper_identity=""
recovered_helper_procinfo_path=""
fault_termination_timestamp=none
helper_cdhash=""
extension_cdhash=""
saver_pid=""
saver_identity=""
saver_procinfo_path=""
owned_cleanup_pid=""
owned_cleanup_identity=""
owned_saver_pid=""
owned_saver_identity=""
cleanup_complete=false
marker_cleanup_armed=false

fail() {
  echo "FAIL: $*" >&2
  echo "Evidence: $evidence_root" >&2
  exit 1
}

# `launchctl procinfo` requires privilege. Prove noninteractive availability
# before starting logging or asking the operator to activate the host; this must
# never turn into a password prompt during a saver session.
if ((EUID != 0)); then
  /usr/bin/sudo -n /usr/bin/true >/dev/null 2>&1 ||
    fail "noninteractive privilege is unavailable for runtime entitlement evidence"
fi

lock_state="$("$project_root/scripts/read-console-lock-state.sh" 2>/dev/null || true)"
[[ "$lock_state" == false ]] || fail "the console must be unlocked before A1T activation"
frontmost_before="$(/usr/bin/lsappinfo front 2>/dev/null || true)"
[[ -n "$frontmost_before" ]] || fail "could not record the foreground application invariant"

[[ ! -e "$evidence_root" ]] || fail "evidence directory already exists"
/bin/mkdir -m 700 "$evidence_root"
: >"$log_path"
: >"$checkpoint_path"
printf 'before=%s\n' "$frontmost_before" >"$evidence_root/foreground-invariant.txt"

record_checkpoint() {
  printf 'elapsed_seconds=%s event=%s\n' "$SECONDS" "$1" >>"$checkpoint_path"
}

cdhash_for_code() {
  /usr/bin/codesign -d --verbose=4 "$1" 2>&1 |
    /usr/bin/awk -F= '$1 == "CDHash" { print $2; exit }'
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print $1 }'
}

write_evidence_manifest() {
  local recovered_pid=none
  local recovered_identity=none
  local recovered_procinfo=none
  local recovered_procinfo_sha256=none
  if [[ "$mode" == a1tr ]]; then
    recovered_pid="$recovered_helper_pid"
    recovered_identity="$recovered_helper_identity"
    recovered_procinfo="$recovered_helper_procinfo_path"
    recovered_procinfo_sha256="$(sha256_file "$recovered_helper_procinfo_path")"
  fi
  printf '%s\n' \
    'format=IdleScreenCameraGateEvidenceV1' \
    "mode=$mode" \
    'evidence_semantics=topology-equivalent-a1t' \
    'trusted_for_production=false' \
    "log_path=$log_path" \
    "log_sha256=$(sha256_file "$log_path")" \
    "helper_marker_path=$helper_info" \
    'helper_marker_version=1' \
    "extension_marker_path=$extension_info" \
    'extension_marker_version=1' \
    "helper_marker_extract=$helper_marker_extract_path" \
    "helper_marker_extract_sha256=$(sha256_file "$helper_marker_extract_path")" \
    "extension_marker_extract=$extension_marker_extract_path" \
    "extension_marker_extract_sha256=$(sha256_file "$extension_marker_extract_path")" \
    "helper_path=$helper_executable" \
    "helper_cdhash=$helper_cdhash" \
    "extension_path=$extension_executable" \
    "extension_cdhash=$extension_cdhash" \
    "helper_codesign_output=$helper_codesign_output_path" \
    "helper_codesign_output_sha256=$(sha256_file "$helper_codesign_output_path")" \
    "extension_codesign_output=$extension_codesign_output_path" \
    "extension_codesign_output_sha256=$(sha256_file "$extension_codesign_output_path")" \
    "initial_helper_class=$initial_helper_class" \
    "initial_helper_pid=$initial_helper_pid" \
    "initial_helper_identity=$initial_helper_identity" \
    "initial_helper_procinfo=$initial_helper_procinfo_path" \
    "initial_helper_procinfo_sha256=$(sha256_file "$initial_helper_procinfo_path")" \
    "saver_pid=$saver_pid" \
    "saver_identity=$saver_identity" \
    "saver_procinfo=$saver_procinfo_path" \
    "saver_procinfo_sha256=$(sha256_file "$saver_procinfo_path")" \
    "configuration_snapshot=$configuration_snapshot_path" \
    "configuration_snapshot_sha256=$(sha256_file "$configuration_snapshot_path")" \
    "fault_termination_timestamp=$fault_termination_timestamp" \
    "recovered_helper_pid=$recovered_pid" \
    "recovered_helper_identity=$recovered_identity" \
    "recovered_helper_procinfo=$recovered_procinfo" \
    "recovered_helper_procinfo_sha256=$recovered_procinfo_sha256" \
    >"$evidence_manifest_path"
}

text_executable_for_candidate_pid() {
  local candidate_pid="$1"
  local lsof_output
  local text_path
  local text_path_count
  [[ "$candidate_pid" =~ ^[1-9][0-9]*$ ]] || return 1
  lsof_output="$(/usr/sbin/lsof -a -p "$candidate_pid" -d txt -Fn 2>/dev/null)" || {
    echo "CRITICAL: could not resolve the text executable for candidate PID $candidate_pid; refusing to infer process absence." >&2
    return 1
  }
  text_path_count="$(/usr/bin/awk \
    'substr($0, 1, 1) == "n" && length($0) > 1 { count += 1 } END { print count + 0 }' \
    <<<"$lsof_output")"
  [[ "$text_path_count" == 1 ]] || {
    echo "CRITICAL: candidate PID $candidate_pid has $text_path_count resolvable text executables; refusing ambiguous ownership." >&2
    return 1
  }
  text_path="$(/usr/bin/awk \
    'substr($0, 1, 1) == "n" && length($0) > 1 { print substr($0, 2); exit }' \
    <<<"$lsof_output")"
  [[ "$text_path" = /* ]] || return 1
  /bin/realpath "$text_path" || {
    echo "CRITICAL: candidate PID $candidate_pid text executable is not an intact canonical path: $text_path" >&2
    return 1
  }
}

pids_for_exact_path() {
  local expected_path="$1"
  local expected_realpath
  local expected_basename
  local process_listing
  local candidate_pid candidate_command candidate_path
  expected_realpath="$(/bin/realpath "$expected_path")" || return 1
  expected_basename="$(/usr/bin/basename "$expected_realpath")"
  process_listing="$(/bin/ps -ww -axo pid=,comm= 2>/dev/null)" || {
    echo "CRITICAL: could not enumerate process identities; refusing to infer exact-path absence." >&2
    return 1
  }
  [[ -n "$process_listing" ]] || {
    echo "CRITICAL: process enumeration returned no records; refusing to infer exact-path absence." >&2
    return 1
  }
  while read -r candidate_pid candidate_command; do
    [[ "$candidate_pid" =~ ^[1-9][0-9]*$ && -n "$candidate_command" ]] || continue
    [[ "$(/usr/bin/basename "$candidate_command")" == "$expected_basename" ]] || continue
    candidate_path="$(text_executable_for_candidate_pid "$candidate_pid")" || return 1
    [[ "$candidate_path" == "$expected_realpath" ]] && printf '%s\n' "$candidate_pid"
  done <<<"$process_listing"
}

single_pid_for_exact_path() {
  local expected_path="$1"
  local pids
  pids="$(pids_for_exact_path "$expected_path")" || return 1
  [[ "$(printf '%s\n' "$pids" | /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')" == 1 ]] ||
    return 1
  printf '%s\n' "$pids"
}

validate_running_code() {
  local pid="$1"
  local expected_path="$2"
  local expected_cdhash="$3"
  local label="$4"
  local running_path
  local running_cdhash
  local procinfo_path="$evidence_root/${label}-procinfo-$pid.txt"

  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || fail "$label PID is invalid"
  running_path="$(/bin/ps -p "$pid" -o comm= | /usr/bin/xargs)"
  [[ "$running_path" == "$expected_path" ]] ||
    fail "$label PID $pid runs '$running_path', not '$expected_path'"
  /usr/bin/codesign --verify --verbose=4 "$pid" >/dev/null 2>&1 ||
    fail "$label PID $pid failed dynamic code-signature verification"
  running_cdhash="$(cdhash_for_code "$pid")"
  [[ -n "$running_cdhash" && "$running_cdhash" == "$expected_cdhash" ]] ||
    fail "$label PID $pid CDHash '$running_cdhash' differs from '$expected_cdhash'"
  printf 'pid=%s\n' "$pid" >"$procinfo_path"
  if ((EUID == 0)); then
    /bin/launchctl procinfo "$pid" >>"$procinfo_path" 2>&1 ||
      fail "$label PID $pid runtime entitlement inspection failed"
  elif ! /usr/bin/sudo -n /bin/launchctl procinfo "$pid" 2>&1 |
    /usr/bin/tee -a "$procinfo_path" >/dev/null; then
    fail "$label PID $pid runtime entitlement inspection failed"
  fi
  /usr/bin/grep -Fq 'entitlements validated' "$procinfo_path" ||
    fail "$label PID $pid does not report entitlements validated"
}

running_process_identity() {
  local pid="$1"
  local expected_path="$2"
  local expected_cdhash="$3"
  "$process_guard" identity "$pid" "$expected_path" "$expected_cdhash"
}

terminate_validated_process_once() {
  local pid="$1"
  local expected_identity="$2"
  local label="$3"
  "$process_guard" term-once \
    "$pid" "$helper_executable" "$helper_cdhash" "$expected_identity" ||
    fail "$label PID identity changed before guarded termination"
}

stop_log_stream() {
  [[ "$log_stream_pid" =~ ^[1-9][0-9]*$ ]] || return 0
  [[ -n "$log_stream_cdhash" && -n "$log_stream_identity" ]] || return 1
  "$process_guard" cleanup \
    "$log_stream_pid" /usr/bin/log "$log_stream_cdhash" "$log_stream_identity" || return 1
  wait "$log_stream_pid" >/dev/null 2>&1 || true
  log_stream_pid=""
  log_stream_cdhash=""
  log_stream_identity=""
}

terminate_marker_helper_for_cleanup() {
  local cleanup_pid="$owned_cleanup_pid"
  local cleanup_identity="$owned_cleanup_identity"
  local remaining_helper_pids
  [[ "$cleanup_pid" =~ ^[1-9][0-9]*$ && -n "$cleanup_identity" ]] || return 0
  if ! /bin/kill -0 "$cleanup_pid" 2>/dev/null; then
    owned_cleanup_pid=""
    owned_cleanup_identity=""
    remaining_helper_pids="$(pids_for_exact_path "$helper_executable")" || return 1
    [[ -z "$remaining_helper_pids" ]] || return 1
    return 0
  fi
  "$process_guard" cleanup \
    "$cleanup_pid" "$helper_executable" "$helper_cdhash" "$cleanup_identity" || return 1
  record_checkpoint "cleanup-helper-term-pid-$cleanup_pid"
  owned_cleanup_pid=""
  owned_cleanup_identity=""
  return 0
}

adopt_exact_marker_processes_for_cleanup() {
  local candidate_pid
  local candidate_pids
  local candidate_count
  local candidate_identity
  if [[ -z "$extension_cdhash" && -d "$extension_bundle" ]]; then
    extension_cdhash="$(cdhash_for_code "$extension_bundle" || true)"
  fi
  if [[ -z "$helper_cdhash" && -d "$helper_bundle" ]]; then
    helper_cdhash="$(cdhash_for_code "$helper_bundle" || true)"
  fi
  if [[ -z "$owned_saver_pid" ]]; then
    candidate_pids="$(pids_for_exact_path "$extension_executable")" || return 1
    candidate_count="$(printf '%s\n' "$candidate_pids" |
      /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
    if [[ "$candidate_count" == 1 ]]; then
      candidate_pid="$(printf '%s\n' "$candidate_pids" | /usr/bin/awk 'NF { print; exit }')"
      candidate_identity="$(running_process_identity \
        "$candidate_pid" "$extension_executable" "$extension_cdhash" || true)"
      [[ -n "$candidate_identity" ]] || return 1
      owned_saver_pid="$candidate_pid"
      owned_saver_identity="$candidate_identity"
    elif [[ "$candidate_count" != 0 ]]; then
      return 1
    fi
  fi
  if [[ -z "$owned_cleanup_pid" ]]; then
    candidate_pids="$(pids_for_exact_path "$helper_executable")" || return 1
    candidate_count="$(printf '%s\n' "$candidate_pids" |
      /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
    if [[ "$candidate_count" == 1 ]]; then
      candidate_pid="$(printf '%s\n' "$candidate_pids" | /usr/bin/awk 'NF { print; exit }')"
      candidate_identity="$(running_process_identity \
        "$candidate_pid" "$helper_executable" "$helper_cdhash" || true)"
      [[ -n "$candidate_identity" ]] || return 1
      owned_cleanup_pid="$candidate_pid"
      owned_cleanup_identity="$candidate_identity"
    elif [[ "$candidate_count" != 0 ]]; then
      return 1
    fi
  fi
}

terminate_marker_saver_for_cleanup() {
  local cleanup_pid="$owned_saver_pid"
  local cleanup_identity="$owned_saver_identity"
  [[ "$cleanup_pid" =~ ^[1-9][0-9]*$ && -n "$cleanup_identity" ]] || return 0
  if /bin/kill -0 "$cleanup_pid" 2>/dev/null; then
    "$process_guard" cleanup \
      "$cleanup_pid" "$extension_executable" "$extension_cdhash" "$cleanup_identity" || return 1
    record_checkpoint "cleanup-saver-term-pid-$cleanup_pid"
  fi
  owned_saver_pid=""
  owned_saver_identity=""
  return 0
}

cleanup_exact_marker_path() {
  local expected_path="$1"
  local expected_cdhash="$2"
  local label="$3"
  local candidate_pids
  local candidate_pid
  local candidate_identity
  candidate_pids="$(pids_for_exact_path "$expected_path")" || return 1
  for candidate_pid in $candidate_pids; do
    [[ "$candidate_pid" =~ ^[1-9][0-9]*$ ]] || return 1
    candidate_identity="$(running_process_identity \
      "$candidate_pid" "$expected_path" "$expected_cdhash" || true)"
    [[ -n "$candidate_identity" ]] || return 1
    "$process_guard" cleanup \
      "$candidate_pid" "$expected_path" "$expected_cdhash" "$candidate_identity" || return 1
    record_checkpoint "cleanup-$label-term-pid-$candidate_pid"
  done
}

drain_exact_marker_processes() {
  local saver_pids
  local helper_pids
  for _ in {1..3}; do
    cleanup_exact_marker_path "$extension_executable" "$extension_cdhash" saver || return 1
    cleanup_exact_marker_path "$helper_executable" "$helper_cdhash" helper || return 1
    saver_pids="$(pids_for_exact_path "$extension_executable")" || return 1
    helper_pids="$(pids_for_exact_path "$helper_executable")" || return 1
    if [[ -z "$saver_pids" && -z "$helper_pids" ]]; then
      return 0
    fi
    /bin/sleep 0.1
  done
  echo "CRITICAL: an exact-path marker process respawned during bounded cleanup." >&2
  return 1
}

wait_for_failure_cleanup_evidence() {
  [[ -n "$log_stream_pid" && -f "$log_path" ]] || return 0
  for _ in {1..20}; do
    if /usr/bin/grep -Eq 'lease_count_changed previous=1 current=0 epoch=[1-9][0-9]*' "$log_path" &&
       /usr/bin/grep -Eq 'capture_stopped generation=[1-9][0-9]* epoch=[1-9][0-9]*' "$log_path"; then
      return 0
    fi
    /bin/sleep 0.1
  done
  return 0
}

handle_exit() {
  local command_exit=$?
  trap - EXIT INT TERM HUP
  if ! $cleanup_complete && $marker_cleanup_armed; then
    adopt_exact_marker_processes_for_cleanup || command_exit=70
    terminate_marker_saver_for_cleanup || command_exit=70
    wait_for_failure_cleanup_evidence
    terminate_marker_helper_for_cleanup || command_exit=70
    drain_exact_marker_processes || command_exit=70
  fi
  stop_log_stream || command_exit=70
  exit "$command_exit"
}

trap handle_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

[[ -x "$verifier" && -x "$configuration_preflight" && -x "$process_guard" ]] ||
  fail "missing A1T evidence verifier, configuration preflight, or process guard"
[[ -d "$helper_bundle" && -f "$helper_info" && -x "$helper_executable" ]] ||
  fail "missing synthetic helper at the production nested path"
[[ -d "$extension_bundle" && -f "$extension_info" && -x "$extension_executable" ]] ||
  fail "missing topology-equivalent hosted-gate extension"

marker="$(/usr/bin/plutil -extract IdleScreenSyntheticGateVersion raw "$helper_info" 2>/dev/null || true)"
[[ "$marker" == 1 ]] || fail "nested helper is not the marker-bearing synthetic gate"
hosted_marker="$(/usr/bin/plutil -extract IdleScreenSyntheticHostedGateVersion raw "$extension_info" 2>/dev/null || true)"
[[ "$hosted_marker" == 1 ]] ||
  fail "nested extension is not the marker-bearing topology-equivalent hosted gate"
printf 'marker_path=%s\nmarker_key=IdleScreenSyntheticGateVersion\nmarker_value=%s\n' \
  "$helper_info" "$marker" >"$helper_marker_extract_path"
printf 'marker_path=%s\nmarker_key=IdleScreenSyntheticHostedGateVersion\nmarker_value=%s\n' \
  "$extension_info" "$hosted_marker" >"$extension_marker_extract_path"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$helper_info")" == com.idlescreen.camera-agent ]] ||
  fail "synthetic helper does not preserve the production helper identifier"
[[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw "$extension_info")" == com.idlescreen.app.screensaver ]] ||
  fail "extension does not preserve the production identifier"
[[ "$(/usr/bin/plutil -extract ScreenSaverViewControllerClass raw "$extension_info")" == \
   IdleScreenScreenSaver.IdleScreenSyntheticHostedGateViewController ]] ||
  fail "extension does not select the gate-only hosted controller"

/usr/bin/codesign --verify --strict --verbose=4 "$app_path" >/dev/null 2>&1 ||
  fail "gate app signature is invalid"
/usr/bin/codesign --verify --strict --verbose=4 "$helper_bundle" >/dev/null 2>&1 ||
  fail "synthetic helper signature is invalid"
/usr/bin/codesign --verify --strict --verbose=4 "$extension_bundle" >/dev/null 2>&1 ||
  fail "extension signature is invalid"
/usr/bin/codesign -dv --verbose=4 "$helper_bundle" >"$helper_codesign_output_path" 2>&1 ||
  fail "could not preserve helper codesign identity"
/usr/bin/codesign -dv --verbose=4 "$extension_bundle" >"$extension_codesign_output_path" 2>&1 ||
  fail "could not preserve extension codesign identity"
helper_cdhash="$(/usr/bin/awk -F= '$1 == "CDHash" { print $2; exit }' "$helper_codesign_output_path")"
extension_cdhash="$(/usr/bin/awk -F= '$1 == "CDHash" { print $2; exit }' "$extension_codesign_output_path")"
[[ "$helper_cdhash" =~ ^[0-9A-Fa-f]{40}$ &&
   "$extension_cdhash" =~ ^[0-9A-Fa-f]{40}$ ]] ||
  fail "could not record valid nested CDHashes"
marker_cleanup_armed=true
printf 'helper_path=%s\nhelper_cdhash=%s\nextension_path=%s\nextension_cdhash=%s\n' \
  "$helper_executable" "$helper_cdhash" "$extension_executable" "$extension_cdhash" \
  >"$evidence_root/code-identity.txt"
printf 'evidence_semantics=topology-equivalent-a1t\ntrusted_for_production=false\n' \
  >>"$evidence_root/code-identity.txt"

"$configuration_preflight" snapshot "$configuration_path" "$configuration_snapshot_path" ||
  fail "real group-container configuration failed immutable camera/hybrid preflight"
configuration_source="$(/usr/bin/awk -F= '$1 == "source" { print $2 }' "$configuration_snapshot_path")"
[[ "$configuration_source" == camera || "$configuration_source" == hybrid ]] ||
  fail "configuration preflight did not record a camera-backed source"
record_checkpoint "configuration-preflight-source-$configuration_source"

[[ -f "$launch_agent_plist" ]] || fail "installed Release LaunchAgent plist is missing"
[[ "$(/usr/bin/plutil -extract Label raw "$launch_agent_plist")" == "$launch_agent_label" ]] ||
  fail "installed LaunchAgent label is stale"
[[ "$(/usr/bin/plutil -extract "MachServices.$launch_agent_label" raw "$launch_agent_plist")" == true ]] ||
  fail "installed LaunchAgent Mach service is stale"
[[ "$(/usr/bin/plutil -extract BundleProgram raw "$launch_agent_plist")" == \
   'Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent' ]] ||
  fail "installed LaunchAgent BundleProgram is stale"
[[ "$(/usr/bin/plutil -extract AssociatedBundleIdentifiers raw "$launch_agent_plist")" == \
   com.idlescreen.app ]] || fail "installed LaunchAgent association is stale"
launch_agent_domain="gui/$(/usr/bin/id -u)/$launch_agent_label"
/bin/launchctl print "$launch_agent_domain" >"$evidence_root/launch-agent-registration.txt" 2>&1 ||
  fail "the production LaunchAgent job is not registered in the GUI domain"
/usr/bin/grep -Fq "$launch_agent_label" "$evidence_root/launch-agent-registration.txt" ||
  fail "registered LaunchAgent snapshot lacks the expected Mach service"
if /usr/bin/grep -Eq 'program|bundle program' "$evidence_root/launch-agent-registration.txt"; then
  /usr/bin/grep -Fq 'IdleScreenCameraAgent' "$evidence_root/launch-agent-registration.txt" ||
    fail "registered LaunchAgent exposes a different BundleProgram"
fi
launch_agent_runtime_pid="$(/usr/bin/awk '
  $1 == "pid" && $2 == "=" && $3 ~ /^[1-9][0-9]*$/ { print $3; exit }
' "$evidence_root/launch-agent-registration.txt")"

companion_preflight_pids="$(pids_for_exact_path "$companion_executable")" ||
  fail "could not prove exact companion-process absence"
extension_preflight_pids="$(pids_for_exact_path "$extension_executable")" ||
  fail "could not prove exact hosted-extension absence"
[[ -z "$companion_preflight_pids" ]] ||
  fail "the companion must be closed before A1T"
[[ -z "$extension_preflight_pids" ]] ||
  fail "a screen-saver extension is already active"
preflight_helper_pids="$(pids_for_exact_path "$helper_executable")" ||
  fail "could not enumerate the exact synthetic helper before A1T"
preflight_helper_count="$(printf '%s\n' "$preflight_helper_pids" |
  /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
((preflight_helper_count <= 1)) || fail "more than one exact-path helper exists before A1T"
if ((preflight_helper_count == 1)); then
  initial_helper_class=warm-idle-bootstrapped
  initial_helper_pid="$(printf '%s\n' "$preflight_helper_pids" | /usr/bin/awk 'NF { print; exit }')"
  [[ "$launch_agent_runtime_pid" == "$initial_helper_pid" ]] ||
    fail "warm helper PID is not the bootstrapped LaunchAgent PID"
  validate_running_code "$initial_helper_pid" "$helper_executable" "$helper_cdhash" initial-helper
  initial_helper_procinfo_path="$evidence_root/initial-helper-procinfo-$initial_helper_pid.txt"
  initial_helper_identity="$(running_process_identity \
    "$initial_helper_pid" "$helper_executable" "$helper_cdhash" || true)"
  [[ -n "$initial_helper_identity" ]] || fail "could not bind warm-idle helper identity"
  owned_cleanup_pid="$initial_helper_pid"
  owned_cleanup_identity="$initial_helper_identity"
else
  initial_helper_class=absent-cold
  [[ -z "$launch_agent_runtime_pid" ]] ||
    fail "LaunchAgent reports a running PID while the exact helper path is absent"
fi
printf 'initial_helper_class=%s\ninitial_helper_pid=%s\nlaunch_agent_pid=%s\n' \
  "$initial_helper_class" "${initial_helper_pid:-none}" "${launch_agent_runtime_pid:-none}" \
  >"$evidence_root/helper-preflight.txt"
record_checkpoint "helper-preflight-$initial_helper_class"

privacy_pattern='raw[ _-]*(frame|image|pixel)|pixel[ _-]*(data|bytes|buffer|sample)|glyph[ _-]*(field|content|output)|checksum|camera[ _-]*image|screenshot|base64|focus[ _-]*(stolen|changed)|settings[ _-]*focus|permission[ _-]*prompt|tcc[ _-]*prompt'
assert_log_is_safe() {
  if /usr/bin/grep -Eiq "$privacy_pattern" "$log_path"; then
    fail "combined log contains forbidden image-derived, prompt, or focus evidence"
  fi
  if /usr/bin/grep -Eiq 'peer_(identity|admission)_rejected|capture_runtime_error|recovery_failure|capture-first-frame-timeout|capture-frame-stall|crash loop|restart loop' "$log_path"; then
    fail "combined log contains a rejected lifecycle condition"
  fi
}

line_count() {
  /usr/bin/wc -l <"$log_path" | /usr/bin/xargs
}

pattern_after_line() {
  local first_line="$1"
  local pattern="$2"
  /usr/bin/tail -n "+$first_line" "$log_path" | /usr/bin/grep -Eq "$pattern"
}

wait_for_pattern_polls() {
  local first_line="$1"
  local pattern="$2"
  local polls="$3"
  local description="$4"
  for ((poll = 0; poll <= polls; poll += 1)); do
    assert_log_is_safe
    /bin/kill -0 "$log_stream_pid" 2>/dev/null || fail "unified-log stream exited early"
    pattern_after_line "$first_line" "$pattern" && return 0
    /bin/sleep 0.1
  done
  fail "timed out waiting for $description"
}

receipt_epoch_after_line() {
  local first_line="$1"
  local excluded_epoch="${2:-0}"
  /usr/bin/tail -n "+$first_line" "$log_path" |
    /usr/bin/sed -nE \
      's/.*Camera receipt state=available epoch=([1-9][0-9]*) sequence=([1-9][0-9]*).*/\1/p' |
    /usr/bin/awk -v excluded="$excluded_epoch" '$1 != excluded { print; exit }'
}

increasing_receipt_count_after_line() {
  local first_line="$1"
  local epoch="$2"
  /usr/bin/tail -n "+$first_line" "$log_path" |
    /usr/bin/sed -nE \
      's/.*Camera receipt state=available epoch=([1-9][0-9]*) sequence=([1-9][0-9]*).*/\1 \2/p' |
    /usr/bin/awk -v expected="$epoch" '
      $1 == expected && $2 > last { count += 1; last = $2 }
      END { print count + 0 }
    '
}

log_predicate='subsystem == "com.idlescreen.camera-agent" OR (process == "IdleScreenScreenSaver" AND subsystem == "com.idlescreen.screensaver" AND ((category == "View" AND (eventMessage BEGINSWITH "Camera receipt" OR eventMessage BEGINSWITH "Animation started" OR eventMessage BEGINSWITH "Animation stopped")) OR (category == "SyntheticHostedGate" AND (eventMessage BEGINSWITH "Synthetic hosted gate preflight" OR eventMessage BEGINSWITH "Synthetic hosted gate loaded"))))'
/usr/bin/log stream \
  --style compact \
  --level info \
  --timeout 240 \
  --predicate "$log_predicate" \
  >"$log_path" 2>/dev/null &
log_stream_pid=$!
/bin/sleep 0.2
/bin/kill -0 "$log_stream_pid" 2>/dev/null || fail "could not start unified-log evidence stream"
log_stream_cdhash="$(cdhash_for_code /usr/bin/log)"
log_stream_identity="$("$process_guard" identity \
  "$log_stream_pid" /usr/bin/log "$log_stream_cdhash" || true)"
[[ -n "$log_stream_identity" ]] || fail "could not bind the unified-log child identity"

activation_first_line=$(( $(line_count) + 1 ))
[[ "$("$project_root/scripts/read-console-lock-state.sh" 2>/dev/null || true)" == false ]] ||
  fail "console locked before the authorized host action"
[[ "$(/usr/bin/lsappinfo front 2>/dev/null || true)" == "$frontmost_before" ]] ||
  fail "foreground application changed before the authorized host action"
record_checkpoint operator-normal-host-activation-authorized
echo "ACTION: activate the already-selected idlescreen once through the normal macOS screen-saver host."
echo "This runner will not open an app, open settings, change selection, or synthesize input."
wait_for_pattern_polls "$activation_first_line" 'Animation started preview=false' 600 'one normal hosted screen-saver activation'
record_checkpoint host-animation-started

pattern_after_line "$activation_first_line" \
  'Synthetic hosted gate preflight helper_pid=[1-9][0-9]* accepted=true active_lease_count=0 capture_active=false' ||
  fail "the activated saver did not prove an authenticated idle helper preflight"
record_checkpoint authenticated-zero-lease-helper-preflight

pattern_after_line "$activation_first_line" \
  'Synthetic hosted gate loaded topology-equivalent=true trusted-for-production=false pid=[1-9][0-9]* instance=[A-Za-z0-9.-]+ preview=false' ||
  fail "the activated saver did not emit the hosted-gate topology marker"
record_checkpoint topology-equivalent-hosted-gate-loaded

host_start_line="$(/usr/bin/grep -nE 'Animation started preview=false' "$log_path" |
  /usr/bin/awk -F: -v minimum="$activation_first_line" '$1 >= minimum { print $1; exit }')"
[[ "$host_start_line" =~ ^[1-9][0-9]*$ ]] || fail "could not locate hosted start line"

# Admission/lease keep their two-second sub-deadline while first and rolling
# hosted receipt evidence share one five-second deadline from host start.
for ((poll = 0; poll <= 50; poll += 1)); do
  assert_log_is_safe
  if ((poll == 20)); then
    pattern_after_line "$host_start_line" 'peer_admission_accepted .*role=screen-saver' ||
      fail "screen-saver XPC peer admission exceeded two seconds"
    pattern_after_line "$host_start_line" 'lease_count_changed previous=0 current=1 epoch=[1-9][0-9]*' ||
      fail "screen-saver begin-stream lease exceeded two seconds"
  fi
  /bin/sleep 0.1
done
pattern_after_line "$host_start_line" 'peer_admission_accepted .*role=screen-saver' ||
  fail "screen-saver XPC peer admission exceeded two seconds"
pattern_after_line "$host_start_line" 'lease_count_changed previous=0 current=1 epoch=[1-9][0-9]*' ||
  fail "screen-saver begin-stream lease exceeded two seconds"
record_checkpoint xpc-admitted-and-lease-one
pattern_after_line "$host_start_line" \
  'Camera receipt state=available epoch=[1-9][0-9]* sequence=[1-9][0-9]*' ||
  fail "first hosted receipt exceeded five seconds"
record_checkpoint first-hosted-receipt

initial_epoch="$(receipt_epoch_after_line "$host_start_line")"
[[ "$initial_epoch" =~ ^[1-9][0-9]*$ ]] || fail "could not parse initial hosted epoch"
observed_initial_helper_pid="$(single_pid_for_exact_path "$helper_executable")" ||
  fail "expected exactly one unambiguous exact-path synthetic helper after first receipt"
[[ "$observed_initial_helper_pid" =~ ^[1-9][0-9]*$ ]] ||
  fail "expected exactly one exact-path synthetic helper after first receipt"
if [[ -n "$initial_helper_pid" && "$observed_initial_helper_pid" != "$initial_helper_pid" ]]; then
  fail "warm-idle helper PID changed before hosted admission"
fi
initial_helper_pid="$observed_initial_helper_pid"
validate_running_code "$initial_helper_pid" "$helper_executable" "$helper_cdhash" initial-helper
initial_helper_procinfo_path="$evidence_root/initial-helper-procinfo-$initial_helper_pid.txt"
initial_helper_identity="$(running_process_identity \
  "$initial_helper_pid" "$helper_executable" "$helper_cdhash" || true)"
[[ -n "$initial_helper_identity" ]] || fail "could not bind the initial helper process identity"
owned_cleanup_pid="$initial_helper_pid"
owned_cleanup_identity="$initial_helper_identity"

saver_pid="$(/usr/bin/tail -n "+$host_start_line" "$log_path" |
  /usr/bin/sed -nE \
    's/.*peer_admission_accepted connection_id=[A-Za-z0-9-]+ pid=([1-9][0-9]*).*role=screen-saver.*/\1/p' |
  /usr/bin/head -1)"
[[ "$saver_pid" =~ ^[1-9][0-9]*$ ]] || fail "could not parse admitted saver PID"
validate_running_code "$saver_pid" "$extension_executable" "$extension_cdhash" hosted-saver
saver_procinfo_path="$evidence_root/hosted-saver-procinfo-$saver_pid.txt"
saver_identity="$(running_process_identity \
  "$saver_pid" "$extension_executable" "$extension_cdhash" || true)"
[[ -n "$saver_identity" ]] || fail "could not bind hosted saver process identity"
owned_saver_pid="$saver_pid"
owned_saver_identity="$saver_identity"
pattern_after_line "$activation_first_line" \
  "IdleScreenScreenSaver\\[$saver_pid:[^]]*\\].*Synthetic hosted gate preflight helper_pid=$initial_helper_pid accepted=true active_lease_count=0 capture_active=false" ||
  fail "authenticated helper preflight does not bind validated helper and saver PIDs"
pattern_after_line "$activation_first_line" \
  "IdleScreenScreenSaver\\[$saver_pid:[^]]*\\].*Synthetic hosted gate loaded topology-equivalent=true trusted-for-production=false pid=$saver_pid instance=[A-Za-z0-9.-]+ preview=false" ||
  fail "hosted-gate marker PID does not match the validated saver process"

initial_receipt_count="$(increasing_receipt_count_after_line "$host_start_line" "$initial_epoch")"
((initial_receipt_count >= 3)) ||
  fail "fewer than three increasing hosted receipts arrived over five seconds"
record_checkpoint initial-rolling-receipts-proven

if [[ "$mode" == a1tr ]]; then
  [[ "$("$project_root/scripts/read-console-lock-state.sh" 2>/dev/null || true)" == false ]] ||
    fail "console locked before the authorized A1TR fault injection"
  validate_running_code "$initial_helper_pid" "$helper_executable" "$helper_cdhash" fault-target
  initial_helper_identity="$(running_process_identity \
    "$initial_helper_pid" "$helper_executable" "$helper_cdhash" || true)"
  [[ -n "$initial_helper_identity" ]] || fail "fault target identity became unavailable"
  fault_first_line=$(( $(line_count) + 1 ))
  printf 'fault_pid=%s\nfault_path=%s\nfault_cdhash=%s\n' \
    "$initial_helper_pid" "$helper_executable" "$helper_cdhash" \
    >"$evidence_root/a1tr-fault-termination.txt"
  fault_termination_timestamp="$(/usr/bin/python3 -c \
    'from datetime import datetime; print(datetime.now().astimezone().strftime("%Y-%m-%d %H:%M:%S.%f"))')"
  terminate_validated_process_once "$initial_helper_pid" "$initial_helper_identity" fault-target
  printf 'fault_termination_timestamp=%s\n' "$fault_termination_timestamp" \
    >>"$evidence_root/a1tr-fault-termination.txt"
  record_checkpoint "a1tr-exact-helper-term-pid-$initial_helper_pid"

  recovered_epoch=""
  for ((poll = 0; poll <= 80; poll += 1)); do
    assert_log_is_safe
    if [[ "$owned_cleanup_pid" == "$initial_helper_pid" ]] &&
       ! /bin/kill -0 "$initial_helper_pid" 2>/dev/null; then
      owned_cleanup_pid=""
      owned_cleanup_identity=""
    fi
    if ((poll == 10)); then
      pattern_after_line "$fault_first_line" 'Camera receipt state=fallback-unavailable' ||
        fail "hosted fallback exceeded one second after guarded termination"
    fi
    helper_pids="$(pids_for_exact_path "$helper_executable")" ||
      fail "could not enumerate the exact synthetic helper during recovery"
    helper_pid_count="$(printf '%s\n' "$helper_pids" |
      /usr/bin/awk 'NF { count += 1 } END { print count + 0 }')"
    ((helper_pid_count <= 1)) || fail "more than one exact-path helper appeared during recovery"
    candidate_pid="$(printf '%s\n' "$helper_pids" | /usr/bin/awk 'NF { print; exit }')"
    if [[ "$candidate_pid" =~ ^[1-9][0-9]*$ && "$candidate_pid" != "$initial_helper_pid" ]]; then
      recovered_helper_pid="$candidate_pid"
    fi
    recovered_epoch="$(receipt_epoch_after_line "$fault_first_line" "$initial_epoch")"
    if [[ "$recovered_helper_pid" =~ ^[1-9][0-9]*$ &&
          "$recovered_epoch" =~ ^[1-9][0-9]*$ ]] &&
       pattern_after_line "$fault_first_line" 'Camera receipt state=fallback-unavailable'; then
      break
    fi
    /bin/sleep 0.1
  done
  pattern_after_line "$fault_first_line" 'Camera receipt state=fallback-unavailable' ||
    fail "hosted fallback was not observed after guarded termination"
  record_checkpoint hosted-fallback-after-helper-term
  [[ "$recovered_helper_pid" =~ ^[1-9][0-9]*$ ]] ||
    fail "launchd did not produce one new exact-path helper PID within eight seconds"
  [[ "$owned_cleanup_pid" != "$initial_helper_pid" ]] ||
    fail "initial fault-target helper did not exit before recovery"
  [[ "$recovered_epoch" =~ ^[1-9][0-9]*$ && "$recovered_epoch" != "$initial_epoch" ]] ||
    fail "fresh hosted receipt did not arrive with a distinct epoch within eight seconds"
  validate_running_code "$recovered_helper_pid" "$helper_executable" "$helper_cdhash" recovered-helper
  recovered_helper_procinfo_path="$evidence_root/recovered-helper-procinfo-$recovered_helper_pid.txt"
  recovered_helper_identity="$(running_process_identity \
    "$recovered_helper_pid" "$helper_executable" "$helper_cdhash" || true)"
  [[ -n "$recovered_helper_identity" ]] || fail "could not bind recovered helper identity"
  owned_cleanup_pid="$recovered_helper_pid"
  owned_cleanup_identity="$recovered_helper_identity"
  record_checkpoint "recovered-helper-pid-$recovered_helper_pid"

  recovered_first_line="$(/usr/bin/grep -nE \
    "Camera receipt state=available epoch=$recovered_epoch sequence=[1-9][0-9]*" \
    "$log_path" | /usr/bin/head -1 | /usr/bin/cut -d: -f1)"
  for _ in {1..50}; do
    assert_log_is_safe
    current_recovered_helper_pid="$(single_pid_for_exact_path "$helper_executable")" ||
      fail "recovered helper ownership became absent or ambiguous"
    [[ "$current_recovered_helper_pid" == "$recovered_helper_pid" ]] ||
      fail "helper entered a restart loop after launchd recovery"
    /bin/sleep 0.1
  done
  recovered_receipt_count="$(increasing_receipt_count_after_line "$recovered_first_line" "$recovered_epoch")"
  ((recovered_receipt_count >= 3)) ||
    fail "recovered helper did not sustain three increasing hosted receipts"
  if /usr/bin/tail -n "+$((recovered_first_line + 1))" "$log_path" |
    /usr/bin/grep -Eq "Camera receipt state=available epoch=$initial_epoch sequence="; then
    fail "hosted saver accepted an old-epoch receipt after recovery"
  fi
  record_checkpoint recovered-rolling-receipts-proven
fi

cleanup_first_line=$(( $(line_count) + 1 ))
echo "ACTION: exit the screen saver normally (for example, unlock or provide normal input)."
wait_for_pattern_polls "$cleanup_first_line" \
  'Animation stopped preview=false|connection_invalidated .*role=screen-saver' \
  1200 'normal hosted invalidation'
record_checkpoint host-invalidation-observed

for _ in {1..20}; do
  assert_log_is_safe
  if pattern_after_line "$cleanup_first_line" 'lease_count_changed previous=1 current=0 epoch=[1-9][0-9]*' &&
     pattern_after_line "$cleanup_first_line" 'capture_stopped generation=[1-9][0-9]* epoch=[1-9][0-9]*'; then
    break
  fi
  /bin/sleep 0.1
done
pattern_after_line "$cleanup_first_line" 'lease_count_changed previous=1 current=0 epoch=[1-9][0-9]*' ||
  fail "final hosted lease did not reach zero within two seconds"
pattern_after_line "$cleanup_first_line" 'capture_stopped generation=[1-9][0-9]* epoch=[1-9][0-9]*' ||
  fail "synthetic producer did not stop within two seconds of the final lease"
for _ in {1..50}; do
  remaining_extension_pids="$(pids_for_exact_path "$extension_executable")" ||
    fail "could not enumerate the exact hosted extension during final cleanup"
  if ! /bin/kill -0 "$saver_pid" 2>/dev/null &&
     [[ -z "$remaining_extension_pids" ]]; then
    break
  fi
  /bin/sleep 0.1
done
remaining_extension_pids="$(pids_for_exact_path "$extension_executable")" ||
  fail "could not prove exact hosted-extension absence after final cleanup"
if /bin/kill -0 "$saver_pid" 2>/dev/null ||
   [[ -n "$remaining_extension_pids" ]]; then
  fail "hosted extension remained resident after bounded normal invalidation"
fi
[[ "$("$project_root/scripts/read-console-lock-state.sh" 2>/dev/null || true)" == false ]] ||
  fail "console did not return to the unlocked state after normal invalidation"
frontmost_after="$(/usr/bin/lsappinfo front 2>/dev/null || true)"
printf 'after=%s\n' "$frontmost_after" >>"$evidence_root/foreground-invariant.txt"
[[ "$frontmost_after" == "$frontmost_before" ]] ||
  fail "foreground application changed across the authorized host cycle"
record_checkpoint final-lease-and-producer-clean

final_stop_line="$(/usr/bin/grep -nE 'capture_stopped generation=[1-9][0-9]* epoch=[1-9][0-9]*' "$log_path" |
  /usr/bin/awk -F: -v minimum="$cleanup_first_line" '$1 >= minimum { line = $1 } END { print line }')"
[[ "$final_stop_line" =~ ^[1-9][0-9]*$ ]] || fail "could not bind the final producer-stop line"
for _ in {1..10}; do
  assert_log_is_safe
  if /usr/bin/tail -n "+$((final_stop_line + 1))" "$log_path" |
    /usr/bin/grep -Eq 'lease_count_changed .*current=[1-9][0-9]*|capture_start_requested|capture_started|Camera receipt state='; then
    fail "helper lifecycle or hosted delivery resumed after final zero leases"
  fi
  /bin/sleep 0.1
done
"$configuration_preflight" recheck "$configuration_path" "$configuration_snapshot_path" ||
  fail "real group-container configuration changed after immutable preflight"

# The transactional installer cannot restore production while a marker-bearing
# process remains resident. This is cleanup, not another recovery stimulus.
terminate_marker_helper_for_cleanup || fail "could not stop marker-bearing helper before restore"
owned_saver_pid=""
owned_saver_identity=""
drain_exact_marker_processes || fail "a marker-bearing process remained after bounded cleanup"
stop_log_stream || fail "unified-log stream did not terminate within three seconds"
assert_log_is_safe
write_evidence_manifest
"$verifier" "$mode" "$log_path" "$evidence_manifest_path"
cleanup_complete=true
trap - EXIT INT TERM HUP

echo "PASS: topology-equivalent camera Gate $mode completed without opening settings, changing selection, or retaining camera content."
echo "Evidence: $evidence_root"
