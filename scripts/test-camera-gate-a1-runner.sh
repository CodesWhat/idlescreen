#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
runner="$project_root/scripts/run-camera-gate-a1.sh"
verifier="$project_root/scripts/verify-camera-gate-a1-log.sh"
parser="$project_root/scripts/verify_camera_gate_a1_log.py"
process_guard="$project_root/scripts/camera-gate-owned-process.sh"
fixture_root="$(mktemp -d /tmp/idlescreen-camera-gate-a1-fixtures.XXXXXX)"
fixture_child_pid=""
helper_path="/Applications/idlescreen.app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent"
helper_marker_path="/Applications/idlescreen.app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/Info.plist"
extension_path="/Applications/idlescreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver"
extension_marker_path="/Applications/idlescreen.app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/Info.plist"
helper_hash="1111111111111111111111111111111111111111"
extension_hash="2222222222222222222222222222222222222222"

cleanup_fixtures() {
  if [[ "$fixture_child_pid" =~ ^[1-9][0-9]*$ ]] &&
     /bin/kill -0 "$fixture_child_pid" 2>/dev/null; then
    /bin/kill -KILL "$fixture_child_pid" >/dev/null 2>&1 || true
    wait "$fixture_child_pid" >/dev/null 2>&1 || true
  fi
  /bin/rm -rf "$fixture_root"
}
trap cleanup_fixtures EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

[[ -x "$runner" && -x "$verifier" && -x "$process_guard" && -f "$parser" ]] ||
  fail "missing executable runner/verifier or ordered parser"
/bin/bash -n "$runner" "$verifier" || fail "camera gate shell syntax failed"
/usr/bin/env PYTHONPYCACHEPREFIX="$fixture_root/pycache" \
  /usr/bin/python3 -m py_compile "$parser" || fail "camera gate parser syntax failed"

fixture_ps="$fixture_root/fixture-ps.sh"
fixture_codesign="$fixture_root/fixture-codesign.sh"
# These literal lines are the generated fixture script.
# shellcheck disable=SC2016
/usr/bin/printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  '[[ $# -eq 6 && "$1" == -p && "$3" == -o && "$4" == lstart= && "$5" == -o && "$6" == comm= ]] || exit 64' \
  '/bin/kill -0 "$2" 2>/dev/null' \
  '/usr/bin/printf "Fri Aug  1 12:00:00 2026 %s\\n" "$IDLESCREEN_PROCESS_GUARD_FIXTURE_PATH"' \
  >"$fixture_ps"
# These literal lines are the generated fixture script.
# shellcheck disable=SC2016
/usr/bin/printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  'target="${!#}"' \
  '/bin/kill -0 "$target" 2>/dev/null' \
  'case "$1" in' \
  '  --verify) exit 0 ;;' \
  '  -d) /usr/bin/printf "CDHash=%s\\n" "$IDLESCREEN_PROCESS_GUARD_FIXTURE_CDHASH" >&2 ;;' \
  '  *) exit 64 ;;' \
  'esac' \
  >"$fixture_codesign"
/bin/chmod +x "$fixture_ps" "$fixture_codesign"

term_ignoring_child="$fixture_root/term-ignoring-child"
/usr/bin/printf '%s\n' \
  '#include <signal.h>' \
  '#include <unistd.h>' \
  'int main(void) { signal(SIGTERM, SIG_IGN); for (;;) pause(); }' |
  xcrun clang -x c - -o "$term_ignoring_child"
/usr/bin/codesign --force --sign - "$term_ignoring_child" >/dev/null
"$term_ignoring_child" &
term_ignoring_pid=$!
fixture_child_pid="$term_ignoring_pid"
/bin/sleep 0.1
term_ignoring_cdhash="$(/usr/bin/codesign -d --verbose=4 "$term_ignoring_child" 2>&1 |
  /usr/bin/awk -F= '$1 == "CDHash" { print $2; exit }')"
run_process_guard_fixture() {
  /usr/bin/env \
    IDLESCREEN_PROCESS_GUARD_FIXTURE_MODE=YES \
    IDLESCREEN_PROCESS_GUARD_PS="$fixture_ps" \
    IDLESCREEN_PROCESS_GUARD_CODESIGN="$fixture_codesign" \
    IDLESCREEN_PROCESS_GUARD_FIXTURE_PATH="$term_ignoring_child" \
    IDLESCREEN_PROCESS_GUARD_FIXTURE_CDHASH="$term_ignoring_cdhash" \
    "$process_guard" "$@"
}
term_ignoring_identity="$(run_process_guard_fixture identity \
  "$term_ignoring_pid" "$term_ignoring_child" "$term_ignoring_cdhash")"
run_process_guard_fixture cleanup \
  "$term_ignoring_pid" "$term_ignoring_child" "$term_ignoring_cdhash" "$term_ignoring_identity" ||
  fail "bounded owned-process cleanup did not handle a TERM-ignoring child"
wait "$term_ignoring_pid" >/dev/null 2>&1 || true
fixture_child_pid=""
/bin/kill -0 "$term_ignoring_pid" 2>/dev/null &&
  fail "TERM-ignoring owned child survived bounded TERM/KILL cleanup"

"$term_ignoring_child" &
exited_pid=$!
fixture_child_pid="$exited_pid"
/bin/sleep 0.1
exited_identity="$(run_process_guard_fixture identity \
  "$exited_pid" "$term_ignoring_child" "$term_ignoring_cdhash")"
/bin/kill -KILL "$exited_pid"
wait "$exited_pid" >/dev/null 2>&1 || true
fixture_child_pid=""
set +e
run_process_guard_fixture term-once \
  "$exited_pid" "$term_ignoring_child" "$term_ignoring_cdhash" "$exited_identity" \
  >/dev/null 2>&1
exited_status=$?
set -e
((exited_status == 1)) ||
  fail "guard did not refuse an exited/mutated PID identity before TERM"

agent_line() {
  local pid="$1"
  local category="$2"
  shift 2
  printf '2026-08-01 12:00:00.000000-0400 I IdleScreenCameraAgent[%s:abc] [com.idlescreen.camera-agent:%s] %s\n' \
    "$pid" "$category" "$*"
}

receipt_line() {
  local state="$1"
  local instance="$2"
  if [[ "$state" == fallback ]]; then
    printf '2026-08-01 12:00:00.000000-0400 I IdleScreenScreenSaver[501:def] [com.idlescreen.screensaver:View] Camera receipt state=fallback-unavailable instance=%s display=1\n' "$instance"
  else
    local epoch="$3"
    local sequence="$4"
    printf '2026-08-01 12:00:00.000000-0400 I IdleScreenScreenSaver[501:def] [com.idlescreen.screensaver:View] Camera receipt state=available epoch=%s sequence=%s instance=%s display=1\n' \
      "$epoch" "$sequence" "$instance"
  fi
}

animation_line() {
  local state="$1"
  local instance="$2"
  printf '2026-08-01 12:00:00.000000-0400 I IdleScreenScreenSaver[501:def] [com.idlescreen.screensaver:View] Animation %s preview=false instance=%s display=1\n' \
    "$state" "$instance"
}

hosted_gate_line() {
  local saver_pid="$1"
  local instance="$2"
  printf '2026-08-01 12:00:00.000000-0400 I IdleScreenScreenSaver[%s:def] [com.idlescreen.screensaver:SyntheticHostedGate] Synthetic hosted gate loaded topology-equivalent=true trusted-for-production=false pid=%s instance=%s preview=false\n' \
    "$saver_pid" "$saver_pid" "$instance"
}

hosted_preflight_line() {
  local saver_pid="$1"
  local helper_pid="$2"
  printf '2026-08-01 12:00:00.000000-0400 I IdleScreenScreenSaver[%s:def] [com.idlescreen.screensaver:SyntheticHostedGate] Synthetic hosted gate preflight helper_pid=%s accepted=true active_lease_count=0 capture_active=false\n' \
    "$saver_pid" "$helper_pid"
}

emit_authenticated_preflight() {
  local helper_pid="$1"
  local saver_pid="$2"
  local connection="$3"
  agent_line "$helper_pid" identity \
    "peer_admission_accepted connection_id=$connection pid=$saver_pid team_id=3524374A2S bundle_id=com.idlescreen.app.screensaver role=screen-saver"
  hosted_preflight_line "$saver_pid" "$helper_pid"
  agent_line "$helper_pid" identity \
    "connection_invalidated connection_id=$connection pid=$saver_pid team_id=3524374A2S bundle_id=com.idlescreen.app.screensaver role=screen-saver"
}

sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print $1 }'
}

replace_manifest_field() {
  local manifest="$1"
  local key="$2"
  local value="$3"
  local replacement="$manifest.replacement"
  /usr/bin/awk -F= -v key="$key" -v value="$value" '
    $1 == key { print key "=" value; next }
    { print }
  ' "$manifest" >"$replacement"
  /bin/mv "$replacement" "$manifest"
}

write_evidence_manifest() {
  local mode="$1"
  local log="$2"
  local initial_pid="$3"
  local recovered_pid="${4:-}"
  local helper_class="${5:-absent-cold}"
  local stem="${log%.log}"
  local initial_procinfo="$stem.initial-helper-procinfo-$initial_pid.txt"
  local saver_procinfo="$stem.hosted-saver-procinfo-501.txt"
  local helper_marker_extract="$stem.helper-marker-extract.txt"
  local extension_marker_extract="$stem.extension-marker-extract.txt"
  local helper_codesign_output="$stem.helper-codesign.txt"
  local extension_codesign_output="$stem.extension-codesign.txt"
  local recovered_procinfo="none"
  local recovered_identity="none"
  local recovered_procinfo_sha256="none"
  local fault_termination_timestamp="none"
  local configuration_snapshot="$stem.configuration-preflight.txt"
  local manifest="$stem.evidence-manifest.txt"

  printf 'pid=%s\nentitlements validated\n' "$initial_pid" >"$initial_procinfo"
  printf 'pid=501\nentitlements validated\n' >"$saver_procinfo"
  printf 'marker_path=%s\nmarker_key=IdleScreenSyntheticGateVersion\nmarker_value=1\n' \
    "$helper_marker_path" >"$helper_marker_extract"
  printf 'marker_path=%s\nmarker_key=IdleScreenSyntheticHostedGateVersion\nmarker_value=1\n' \
    "$extension_marker_path" >"$extension_marker_extract"
  printf 'Identifier=com.idlescreen.camera-agent\nTeamIdentifier=3524374A2S\nCDHash=%s\n' \
    "$helper_hash" >"$helper_codesign_output"
  printf 'Identifier=com.idlescreen.app.screensaver\nTeamIdentifier=3524374A2S\nCDHash=%s\n' \
    "$extension_hash" >"$extension_codesign_output"
  printf '%s\n' \
    'format=IdleScreenCameraGateConfigurationV1' \
    'configuration_path=/Users/fixture/Library/Group Containers/group.com.idlescreen.shared/configuration.json' \
    'schema_version=1' \
    'source=camera' \
    'device=1' \
    'inode=2' \
    'size=41' \
    'mtime_ns=1785600000000000000' \
    'sha256=3333333333333333333333333333333333333333333333333333333333333333' \
    >"$configuration_snapshot"
  if [[ "$mode" == a1tr ]]; then
    recovered_procinfo="$stem.recovered-helper-procinfo-$recovered_pid.txt"
    printf 'pid=%s\nentitlements validated\n' "$recovered_pid" >"$recovered_procinfo"
    recovered_identity="Sat Aug 1 12:00:01 2026 $helper_path|$helper_hash"
    recovered_procinfo_sha256="$(sha256_file "$recovered_procinfo")"
    fault_termination_timestamp='2026-08-01 12:00:00.000000-0400'
  else
    recovered_pid=none
  fi
  printf '%s\n' \
    'format=IdleScreenCameraGateEvidenceV1' \
    "mode=$mode" \
    'evidence_semantics=topology-equivalent-a1t' \
    'trusted_for_production=false' \
    "log_path=$log" \
    "log_sha256=$(sha256_file "$log")" \
    "helper_marker_path=$helper_marker_path" \
    'helper_marker_version=1' \
    "extension_marker_path=$extension_marker_path" \
    'extension_marker_version=1' \
    "helper_marker_extract=$helper_marker_extract" \
    "helper_marker_extract_sha256=$(sha256_file "$helper_marker_extract")" \
    "extension_marker_extract=$extension_marker_extract" \
    "extension_marker_extract_sha256=$(sha256_file "$extension_marker_extract")" \
    "helper_path=$helper_path" \
    "helper_cdhash=$helper_hash" \
    "extension_path=$extension_path" \
    "extension_cdhash=$extension_hash" \
    "helper_codesign_output=$helper_codesign_output" \
    "helper_codesign_output_sha256=$(sha256_file "$helper_codesign_output")" \
    "extension_codesign_output=$extension_codesign_output" \
    "extension_codesign_output_sha256=$(sha256_file "$extension_codesign_output")" \
    "initial_helper_class=$helper_class" \
    "initial_helper_pid=$initial_pid" \
    "initial_helper_identity=Sat Aug 1 12:00:00 2026 $helper_path|$helper_hash" \
    "initial_helper_procinfo=$initial_procinfo" \
    "initial_helper_procinfo_sha256=$(sha256_file "$initial_procinfo")" \
    'saver_pid=501' \
    "saver_identity=Sat Aug 1 12:00:00 2026 $extension_path|$extension_hash" \
    "saver_procinfo=$saver_procinfo" \
    "saver_procinfo_sha256=$(sha256_file "$saver_procinfo")" \
    "configuration_snapshot=$configuration_snapshot" \
    "configuration_snapshot_sha256=$(sha256_file "$configuration_snapshot")" \
    "fault_termination_timestamp=$fault_termination_timestamp" \
    "recovered_helper_pid=$recovered_pid" \
    "recovered_helper_identity=$recovered_identity" \
    "recovered_helper_procinfo=$recovered_procinfo" \
    "recovered_helper_procinfo_sha256=$recovered_procinfo_sha256" \
    >"$manifest"
  printf '%s\n' "$manifest"
}

emit_incarnation_start() {
  local pid="$1"
  local peer_pid="$2"
  local connection="$3"
  local epoch="$4"
  local generation="$5"
  agent_line "$pid" identity \
    "peer_admission_accepted connection_id=$connection pid=$peer_pid team_id=3524374A2S bundle_id=com.idlescreen.app.screensaver role=screen-saver"
  agent_line "$pid" lifecycle "lease_count_changed previous=0 current=1 epoch=$epoch"
  agent_line "$pid" lifecycle "capture_start_requested generation=$generation epoch=$epoch"
  agent_line "$pid" lifecycle "capture_started generation=$generation epoch=$epoch"
  agent_line "$pid" lifecycle "first_frame_published generation=$generation epoch=$epoch sequence=1"
}

emit_cleanup() {
  local pid="$1"
  local peer_pid="$2"
  local connection="$3"
  local epoch="$4"
  local generation="$5"
  agent_line "$pid" identity \
    "connection_invalidated connection_id=$connection pid=$peer_pid team_id=3524374A2S bundle_id=com.idlescreen.app.screensaver role=screen-saver"
  agent_line "$pid" lifecycle "lease_count_changed previous=1 current=0 epoch=$epoch"
  agent_line "$pid" lifecycle "capture_stop_requested generation=$generation epoch=$epoch"
  agent_line "$pid" lifecycle "capture_stopped generation=$generation epoch=$epoch"
}

good_a1="$fixture_root/good-a1t.log"
{
  emit_authenticated_preflight 101 501 connection-preflight-A
  hosted_gate_line 501 view-a
  animation_line started view-a
  emit_incarnation_start 101 501 connection-A-1 7001 4
  receipt_line available view-a 7001 1
  receipt_line available view-a 7001 11
  receipt_line available view-a 7001 21
  animation_line stopped view-a
  emit_cleanup 101 501 connection-A-1 7001 4
  printf 'operator-note screenshot=false\n'
} >"$good_a1"
good_a1_manifest="$(write_evidence_manifest a1t "$good_a1" 101)"
"$verifier" a1t "$good_a1" "$good_a1_manifest" >/dev/null || fail "valid A1T fixture was rejected"

good_a1r="$fixture_root/good-a1tr.log"
{
  emit_authenticated_preflight 101 501 connection-preflight-A
  hosted_gate_line 501 view-a
  animation_line started view-a
  emit_incarnation_start 101 501 connection-A-1 7001 4
  receipt_line available view-a 7001 1
  receipt_line available view-a 7001 11
  receipt_line available view-a 7001 21
  receipt_line fallback view-a
  emit_incarnation_start 202 501 connection-B-1 9001 1
  receipt_line available view-a 9001 1
  receipt_line available view-a 9001 12
  receipt_line available view-a 9001 24
  animation_line stopped view-a
  emit_cleanup 202 501 connection-B-1 9001 1
} >"$good_a1r"
good_a1r_manifest="$(write_evidence_manifest a1tr "$good_a1r" 101 202)"
"$verifier" a1tr "$good_a1r" "$good_a1r_manifest" >/dev/null || fail "valid A1TR fixture was rejected"

expect_rejected() {
  local fixture="$1"
  local mode="$2"
  local initial_pid="$3"
  local recovered_pid="${4:-}"
  local manifest
  local status
  manifest="$(write_evidence_manifest "$mode" "$fixture" "$initial_pid" "$recovered_pid")"
  set +e
  "$verifier" "$mode" "$fixture" "$manifest" >/dev/null 2>&1
  status=$?
  set -e
  if ((status == 0)); then
    fail "adversarial fixture was accepted: $(basename "$fixture")"
  fi
  ((status == 1)) || fail "adversarial fixture hit usage/setup status $status instead of evidence rejection"
}

expect_accepted() {
  local fixture="$1"
  local mode="$2"
  local initial_pid="$3"
  local recovered_pid="${4:-}"
  local helper_class="${5:-absent-cold}"
  local manifest
  manifest="$(write_evidence_manifest "$mode" "$fixture" "$initial_pid" "$recovered_pid" "$helper_class")"
  "$verifier" "$mode" "$fixture" "$manifest" >/dev/null
}

expect_usage_rejected() {
  set +e
  "$@" >/dev/null 2>&1
  local status=$?
  set -e
  ((status == 64)) || fail "obsolete or malformed invocation returned $status instead of 64: $*"
}

expect_manifest_rejected() {
  local mode="$1"
  local fixture="$2"
  local manifest="$3"
  set +e
  "$verifier" "$mode" "$fixture" "$manifest" >/dev/null 2>&1
  local status=$?
  set -e
  ((status == 1)) || fail "adversarial manifest returned $status instead of evidence rejection"
}

expect_rejected_with_class() {
  local fixture="$1"
  local helper_class="$2"
  local manifest
  manifest="$(write_evidence_manifest a1t "$fixture" 101 '' "$helper_class")"
  expect_manifest_rejected a1t "$fixture" "$manifest"
}

expect_accepted "$good_a1" a1t 101 || fail "valid control failed shared fixture invocation"
expect_accepted "$good_a1" a1t 101 '' warm-idle-bootstrapped ||
  fail "valid warm-idle classification was rejected"
expect_accepted "$good_a1r" a1tr 101 202 || fail "valid recovery control failed shared fixture invocation"
expect_usage_rejected "$verifier" a1 "$good_a1" "$good_a1_manifest"
expect_usage_rejected "$verifier" a1r "$good_a1r" "$good_a1r_manifest"
expect_usage_rejected "$verifier" arbitrary "$good_a1" "$good_a1_manifest"

nonidle_warm_helper="$fixture_root/nonidle-warm-helper.log"
{
  agent_line 101 lifecycle 'lease_count_changed previous=0 current=1 epoch=6001'
  agent_line 101 lifecycle 'capture_start_requested generation=3 epoch=6001'
  agent_line 101 lifecycle 'capture_started generation=3 epoch=6001'
  /bin/cat "$good_a1"
} >"$nonidle_warm_helper"
expect_rejected_with_class "$nonidle_warm_helper" warm-idle-bootstrapped

missing_marker="$fixture_root/missing-hosted-marker.log"
/usr/bin/grep -v 'Synthetic hosted gate loaded' "$good_a1" >"$missing_marker"
expect_rejected "$missing_marker" a1t 101

missing_preflight="$fixture_root/missing-hosted-preflight.log"
/usr/bin/grep -v 'Synthetic hosted gate preflight' "$good_a1" >"$missing_preflight"
expect_rejected "$missing_preflight" a1t 101

wrong_preflight_helper="$fixture_root/wrong-preflight-helper.log"
/usr/bin/sed '/Synthetic hosted gate preflight/s/helper_pid=101/helper_pid=202/' \
  "$good_a1" >"$wrong_preflight_helper"
expect_rejected "$wrong_preflight_helper" a1t 101

nonidle_preflight="$fixture_root/nonidle-hosted-preflight.log"
/usr/bin/sed '/Synthetic hosted gate preflight/s/active_lease_count=0 capture_active=false/active_lease_count=1 capture_active=true/' \
  "$good_a1" >"$nonidle_preflight"
expect_rejected "$nonidle_preflight" a1t 101

unclosed_preflight="$fixture_root/unclosed-hosted-preflight.log"
/usr/bin/grep -v 'connection_invalidated connection_id=connection-preflight-A' \
  "$good_a1" >"$unclosed_preflight"
expect_rejected "$unclosed_preflight" a1t 101

late_preflight="$fixture_root/late-hosted-preflight.log"
/usr/bin/awk '
  /Synthetic hosted gate preflight/ { late = 1 }
  late { sub("12:00:00.000000-0400", "12:00:03.000000-0400") }
  { print }
' "$good_a1" >"$late_preflight"
expect_rejected "$late_preflight" a1t 101

compact_timestamp="$fixture_root/compact-timestamp.log"
/usr/bin/sed 's/\.000000-0400/.000/g' "$good_a1" >"$compact_timestamp"
expect_accepted "$compact_timestamp" a1t 101 ||
  fail "valid three-digit compact unified-log timestamps were rejected"

trusted_marker="$fixture_root/trusted-hosted-marker.log"
/usr/bin/sed 's/trusted-for-production=false/trusted-for-production=true/' \
  "$good_a1" >"$trusted_marker"
expect_rejected "$trusted_marker" a1t 101

wrong_marker_payload_pid="$fixture_root/wrong-marker-payload-pid.log"
/usr/bin/sed 's/false pid=501/false pid=777/' "$good_a1" >"$wrong_marker_payload_pid"
expect_rejected "$wrong_marker_payload_pid" a1t 101

wrong_marker_instance="$fixture_root/wrong-marker-instance.log"
/usr/bin/sed '/Synthetic hosted gate loaded/s/instance=view-a/instance=view-other/' \
  "$good_a1" >"$wrong_marker_instance"
expect_rejected "$wrong_marker_instance" a1t 101

reused_generation="$fixture_root/reused-recovery-generation.log"
/usr/bin/sed 's/generation=1 epoch=9001/generation=4 epoch=9001/g' \
  "$good_a1r" >"$reused_generation"
expect_rejected "$reused_generation" a1tr 101 202

late_receipts="$fixture_root/late-receipts.log"
/usr/bin/awk '
  /sequence=21/ { late = 1 }
  late { sub("12:00:00.000000-0400", "12:00:06.000000-0400") }
  { print }
' "$good_a1" >"$late_receipts"
expect_rejected "$late_receipts" a1t 101

nonmonotonic="$fixture_root/nonmonotonic.log"
/usr/bin/sed '/capture_started/s/12:00:00.000000-0400/11:59:59.999999-0400/' \
  "$good_a1" >"$nonmonotonic"
expect_rejected "$nonmonotonic" a1t 101

wrong_path_manifest="$(write_evidence_manifest a1t "$good_a1" 101)"
/usr/bin/sed -i '' 's#helper_path=/Applications/idlescreen.app/#helper_path=/Applications/other.app/#' \
  "$wrong_path_manifest"
expect_manifest_rejected a1t "$good_a1" "$wrong_path_manifest"

wrong_hash_manifest="$(write_evidence_manifest a1t "$good_a1" 101)"
/usr/bin/sed -i '' 's/helper_cdhash=1111111111111111111111111111111111111111/helper_cdhash=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/' \
  "$wrong_hash_manifest"
expect_manifest_rejected a1t "$good_a1" "$wrong_hash_manifest"

wrong_pid_manifest="$(write_evidence_manifest a1t "$good_a1" 101)"
/usr/bin/sed -i '' 's/initial_helper_pid=101/initial_helper_pid=999/' "$wrong_pid_manifest"
expect_manifest_rejected a1t "$good_a1" "$wrong_pid_manifest"

bad_procinfo_manifest="$(write_evidence_manifest a1t "$good_a1" 101)"
bad_procinfo="$(/usr/bin/awk -F= '$1 == "initial_helper_procinfo" { print substr($0, index($0, "=") + 1) }' \
  "$bad_procinfo_manifest")"
printf 'pid=101\nentitlements NOT validated\n' >"$bad_procinfo"
replace_manifest_field "$bad_procinfo_manifest" initial_helper_procinfo_sha256 \
  "$(sha256_file "$bad_procinfo")"
expect_manifest_rejected a1t "$good_a1" "$bad_procinfo_manifest"

bad_marker_manifest="$(write_evidence_manifest a1t "$good_a1" 101)"
bad_marker_extract="$(/usr/bin/awk -F= '$1 == "helper_marker_extract" { print substr($0, index($0, "=") + 1) }' \
  "$bad_marker_manifest")"
/usr/bin/sed -i '' 's/marker_key=IdleScreenSyntheticGateVersion/marker_key=UntrustedGateVersion/' \
  "$bad_marker_extract"
replace_manifest_field "$bad_marker_manifest" helper_marker_extract_sha256 \
  "$(sha256_file "$bad_marker_extract")"
expect_manifest_rejected a1t "$good_a1" "$bad_marker_manifest"

bad_codesign_manifest="$(write_evidence_manifest a1t "$good_a1" 101)"
bad_codesign_output="$(/usr/bin/awk -F= '$1 == "helper_codesign_output" { print substr($0, index($0, "=") + 1) }' \
  "$bad_codesign_manifest")"
/usr/bin/sed -i '' 's/Identifier=com.idlescreen.camera-agent/Identifier=com.attacker.camera-agent/' \
  "$bad_codesign_output"
replace_manifest_field "$bad_codesign_manifest" helper_codesign_output_sha256 \
  "$(sha256_file "$bad_codesign_output")"
expect_manifest_rejected a1t "$good_a1" "$bad_codesign_manifest"

bad_config_manifest="$(write_evidence_manifest a1t "$good_a1" 101)"
bad_config_snapshot="$(/usr/bin/awk -F= '$1 == "configuration_snapshot" { print substr($0, index($0, "=") + 1) }' \
  "$bad_config_manifest")"
/usr/bin/sed -i '' 's/source=camera/source=generative/' "$bad_config_snapshot"
replace_manifest_field "$bad_config_manifest" configuration_snapshot_sha256 \
  "$(sha256_file "$bad_config_snapshot")"
expect_manifest_rejected a1t "$good_a1" "$bad_config_manifest"

late_fault_manifest="$(write_evidence_manifest a1tr "$good_a1r" 101 202)"
replace_manifest_field "$late_fault_manifest" fault_termination_timestamp \
  '2026-08-01 11:59:58.000000-0400'
expect_manifest_rejected a1tr "$good_a1r" "$late_fault_manifest"

tampered_log="$fixture_root/tampered-after-manifest.log"
/bin/cp "$good_a1" "$tampered_log"
tampered_log_manifest="$(write_evidence_manifest a1t "$tampered_log" 101)"
printf 'operator-note mutation-after-manifest=true\n' >>"$tampered_log"
expect_manifest_rejected a1t "$tampered_log" "$tampered_log_manifest"

post_cleanup_restart="$fixture_root/post-cleanup-restart.log"
{
  /bin/cat "$good_a1"
  agent_line 101 lifecycle 'lease_count_changed previous=0 current=1 epoch=7001'
  agent_line 101 lifecycle 'capture_start_requested generation=5 epoch=7001'
  agent_line 101 lifecycle 'capture_started generation=5 epoch=7001'
} >"$post_cleanup_restart"
expect_rejected "$post_cleanup_restart" a1t 101

post_cleanup_host_restart="$fixture_root/post-cleanup-host-restart.log"
{
  /bin/cat "$good_a1"
  animation_line started view-a
  hosted_gate_line 501 view-a
} >"$post_cleanup_host_restart"
expect_rejected "$post_cleanup_host_restart" a1t 101

mixed_pid="$fixture_root/mixed-pid.log"
/usr/bin/sed 's/IdleScreenCameraAgent\[101:abc\] \[com.idlescreen.camera-agent:lifecycle\]/IdleScreenCameraAgent[202:abc] [com.idlescreen.camera-agent:lifecycle]/' \
  "$good_a1" >"$mixed_pid"
expect_rejected "$mixed_pid" a1t 101

mixed_epoch="$fixture_root/mixed-epoch.log"
/usr/bin/sed 's/capture_started generation=4 epoch=7001/capture_started generation=4 epoch=8001/' \
  "$good_a1" >"$mixed_epoch"
expect_rejected "$mixed_epoch" a1t 101

mixed_generation="$fixture_root/mixed-generation.log"
/usr/bin/sed 's/first_frame_published generation=4/first_frame_published generation=5/' \
  "$good_a1" >"$mixed_generation"
expect_rejected "$mixed_generation" a1t 101

wrong_connection="$fixture_root/wrong-connection.log"
/usr/bin/sed 's/connection_invalidated connection_id=connection-A-1/connection_invalidated connection_id=connection-other/' \
  "$good_a1" >"$wrong_connection"
expect_rejected "$wrong_connection" a1t 101

decreasing_sequence="$fixture_root/decreasing-sequence.log"
/usr/bin/sed 's/sequence=21/sequence=9/' "$good_a1" >"$decreasing_sequence"
expect_rejected "$decreasing_sequence" a1t 101

wrong_saver_pid="$fixture_root/wrong-saver-pid.log"
/usr/bin/sed '/Camera receipt state=/s/IdleScreenScreenSaver\[501:def\]/IdleScreenScreenSaver[777:def]/' \
  "$good_a1" >"$wrong_saver_pid"
expect_rejected "$wrong_saver_pid" a1t 101

cleanup_before_delivery="$fixture_root/cleanup-before-delivery.log"
{
  emit_incarnation_start 101 501 connection-A-1 7001 4
  emit_cleanup 101 501 connection-A-1 7001 4
  receipt_line available view-a 7001 1
  receipt_line available view-a 7001 11
  receipt_line available view-a 7001 21
} >"$cleanup_before_delivery"
expect_rejected "$cleanup_before_delivery" a1t 101

stale_epoch="$fixture_root/stale-old-epoch.log"
/usr/bin/awk '
  /connection_invalidated connection_id=connection-B-1/ {
    print "2026-08-01 12:00:00.000000-0400 I IdleScreenScreenSaver[501:def] [com.idlescreen.screensaver:View] Camera receipt state=available epoch=7001 sequence=99 instance=view-a display=1"
  }
  { print }
' "$good_a1r" >"$stale_epoch"
expect_rejected "$stale_epoch" a1tr 101 202

third_helper="$fixture_root/third-helper.log"
{
  /bin/cat "$good_a1r"
  agent_line 303 lifecycle 'authorization_status status=authorized source=startup'
} >"$third_helper"
expect_rejected "$third_helper" a1tr 101 202

unsafe_payload="$fixture_root/unsafe-payload.log"
{
  /bin/cat "$good_a1"
  printf 'debug frame_payload=deadbeef\n'
} >"$unsafe_payload"
expect_rejected "$unsafe_payload" a1t 101

unknown_agent_field="$fixture_root/unknown-agent-field.log"
{
  /bin/cat "$good_a1"
  agent_line 101 lifecycle 'frame_delivery payload=00ff'
} >"$unknown_agent_field"
expect_rejected "$unknown_agent_field" a1t 101

unknown_saver_field="$fixture_root/unknown-saver-field.log"
{
  /bin/cat "$good_a1"
  printf '2026-08-01 12:00:00.000000-0400 I IdleScreenScreenSaver[501:def] [com.idlescreen.screensaver:View] View attachment changed attached=true instance=view-a display=1\n'
} >"$unknown_saver_field"
expect_rejected "$unknown_saver_field" a1t 101

# Static command-construction guards: the physical runner itself is never
# executed by this fixture suite.
if /usr/bin/grep -Eq '\ba1r\b|\bA1R\b' "$runner"; then
  fail "runner still contains an obsolete A1R mode token"
fi
/usr/bin/grep -Fq 'IDLESCREEN_ALLOW_CAMERA_GATE_A1T' "$runner" || fail "missing physical opt-in"
/usr/bin/grep -Fq -- '--normal-host-activation-authorized' "$runner" || fail "missing activation token"
/usr/bin/grep -Fq -- '--terminate-exact-synthetic-helper-once' "$runner" || fail "missing recovery token"
/usr/bin/grep -Fq 'SyntheticHostedGate' "$runner" ||
  fail "runner log predicate excludes the hosted-gate marker"
/usr/bin/grep -Fq 'Synthetic hosted gate preflight helper_pid=' "$runner" ||
  fail "runner does not require authenticated zero-lease helper preflight"
/usr/bin/grep -Fq 'write_evidence_manifest' "$runner" ||
  fail "runner never writes its replayable evidence manifest"
/usr/bin/grep -Fq 'helper_marker_extract_sha256=' "$runner" ||
  fail "runner manifest does not hash the preserved helper marker extract"
/usr/bin/grep -Fq 'extension_marker_extract_sha256=' "$runner" ||
  fail "runner manifest does not hash the preserved extension marker extract"
/usr/bin/grep -Fq 'helper_codesign_output_sha256=' "$runner" ||
  fail "runner manifest does not hash the preserved helper codesign output"
/usr/bin/grep -Fq 'extension_codesign_output_sha256=' "$runner" ||
  fail "runner manifest does not hash the preserved extension codesign output"
/usr/bin/grep -Fq 'fault_termination_timestamp=' "$runner" ||
  fail "runner does not bind the A1TR fault boundary timestamp"
/usr/bin/grep -Fq '"$verifier" "$mode" "$log_path" "$evidence_manifest_path"' "$runner" ||
  fail "runner verifier invocation is not bound to the evidence manifest"
/usr/bin/grep -Fq '"$configuration_preflight" recheck' "$runner" ||
  fail "runner never rechecks the immutable configuration snapshot"
if /usr/bin/grep -Fq 'IDLESCREEN_A1T_SHARED_CONTAINER_OVERRIDE' "$runner"; then
  fail "physical runner permits a non-production shared-container override"
fi
/usr/bin/grep -Fq 'running_process_identity' "$runner" || fail "missing immutable PID identity"
/usr/bin/grep -Fq 'owned_cleanup_pid' "$runner" || fail "cleanup is not ownership-scoped"
/usr/bin/grep -Fq 'text_executable_for_candidate_pid' "$runner" ||
  fail "exact-path process enumeration does not resolve text-executable ownership"
/usr/bin/grep -Fq 'refusing to infer exact-path absence' "$runner" ||
  fail "exact-path process enumeration does not fail closed"
/usr/bin/grep -Fq 'text_path_count" == 1' "$runner" ||
  fail "exact-path process enumeration accepts ambiguous text executables"
if /usr/bin/grep -Eq '\[\[ -[zn] "\$\(pids_for_exact_path' "$runner"; then
  fail "runner masks exact-path enumeration failure inside an absence predicate"
fi
/usr/bin/grep -Fq 'owned_cleanup_pid="$initial_helper_pid"' "$runner" ||
  fail "initial helper is not explicitly adopted for cleanup"
/usr/bin/grep -Fq 'owned_cleanup_pid="$recovered_helper_pid"' "$runner" ||
  fail "recovered helper is not explicitly adopted for cleanup"
/usr/bin/grep -Fq 'local cleanup_pid="$owned_cleanup_pid"' "$runner" ||
  fail "EXIT cleanup discovers an arbitrary process instead of using ownership"
/usr/bin/grep -Fq 'terminate_validated_process_once "$initial_helper_pid" "$initial_helper_identity" fault-target' "$runner" ||
  fail "A1TR fault does not use the immediate identity revalidation boundary"
/usr/bin/grep -Fq '[[ "$frontmost_after" == "$frontmost_before" ]]' "$runner" ||
  fail "foreground invariant is not checked after invalidation"
/usr/bin/grep -Fq '/usr/bin/sudo -n' "$runner" || fail "missing noninteractive privilege preflight"
/usr/bin/grep -Fq 'read-console-lock-state.sh' "$runner" || fail "missing unlocked-console guard"
/usr/bin/grep -Fq '/usr/bin/lsappinfo front' "$runner" || fail "missing foreground invariant"

if /usr/bin/grep -Eq '/usr/bin/open|osascript|open -a|tccutil|pluginkit|SACScreenSaverStartNow|CGEvent' "$runner"; then
  fail "runner contains a focus-changing, TCC, registration, or synthesized-input command"
fi

preflight_line="$(/usr/bin/grep -nF '/usr/bin/sudo -n /usr/bin/true' "$runner" | /usr/bin/cut -d: -f1)"
log_line="$(/usr/bin/grep -nF '/usr/bin/log stream' "$runner" | /usr/bin/cut -d: -f1)"
((preflight_line < log_line)) || fail "privilege failure is not preflighted before log/activation"
configuration_line="$(/usr/bin/grep -nF '"$configuration_preflight" snapshot' "$runner" | /usr/bin/cut -d: -f1)"
activation_line="$(/usr/bin/grep -nF 'ACTION: activate the already-selected idlescreen' "$runner" | /usr/bin/cut -d: -f1)"
((configuration_line < activation_line)) ||
  fail "shared camera-backed configuration is not preflighted before activation"
handle_exit_body="$(/usr/bin/sed -n '/^handle_exit()/,/^}/p' "$runner")"
failure_cleanup_line="$(printf '%s\n' "$handle_exit_body" | /usr/bin/grep -nF 'drain_exact_marker_processes' | /usr/bin/cut -d: -f1)"
failure_log_stop_line="$(printf '%s\n' "$handle_exit_body" | /usr/bin/grep -nF 'stop_log_stream' | /usr/bin/cut -d: -f1)"
[[ "$failure_cleanup_line" =~ ^[1-9][0-9]*$ && "$failure_log_stop_line" =~ ^[1-9][0-9]*$ ]] ||
  fail "could not inspect failure cleanup/log ordering"
((failure_cleanup_line < failure_log_stop_line)) ||
  fail "failure cleanup stops evidence before draining marker processes"

echo "PASS: topology-equivalent Gate A1T/A1TR ordered evidence fixtures and static runner guards passed."
