#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/path/to/matrix-evidence expected-cycles [minimum-duration-seconds]" >&2
  exit 64
}

[[ $# -ge 2 && $# -le 3 ]] || usage

evidence_dir="$1"
expected_cycles="$2"
minimum_duration_seconds="${3:-5}"
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cycle_verifier="$project_root/scripts/verify-host-lifecycle-cycle-log.sh"

[[ "$evidence_dir" = /* ]] || usage
[[ "$expected_cycles" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$minimum_duration_seconds" =~ ^[0-9]+$ ]] || usage

incomplete() {
  echo "INCOMPLETE: $*" >&2
  exit 1
}

fatal() {
  echo "FAIL: $*" >&2
  exit 2
}

[[ -d "$evidence_dir" ]] || incomplete "matrix evidence directory does not exist: $evidence_dir"
[[ -x "$cycle_verifier" ]] || fatal "missing completed-cycle verifier"

cycle_file_count="$(find "$evidence_dir" -maxdepth 1 -type f -name 'cycle-*.log' | wc -l | tr -d ' ')"
if ((cycle_file_count < expected_cycles)); then
  incomplete "found $cycle_file_count of $expected_cycles required cycle logs"
fi
if ((cycle_file_count > expected_cycles)); then
  fatal "found $cycle_file_count cycle logs but exactly $expected_cycles were requested"
fi

seen_digests=""
seen_identities=""

for ((cycle = 1; cycle <= expected_cycles; cycle += 1)); do
  printf -v cycle_name 'cycle-%02d' "$cycle"
  cycle_log="$evidence_dir/$cycle_name.log"
  [[ -f "$cycle_log" ]] || incomplete "missing contiguous evidence file $cycle_name.log"

  set +e
  verification_output="$("$cycle_verifier" "$cycle_log" false "$minimum_duration_seconds" 2>&1)"
  verification_status=$?
  set -e
  case "$verification_status" in
    0) ;;
    1) incomplete "$cycle_name lacks complete same-process invalidation evidence" ;;
    *)
      printf '%s\n' "$verification_output" >&2
      fatal "$cycle_name contains fatal lifecycle evidence"
      ;;
  esac

  digest="$(/usr/bin/shasum -a 256 "$cycle_log" | awk '{ print $1 }')"
  if grep -Fxq "$digest" <<<"$seen_digests"; then
    fatal "$cycle_name duplicates an earlier cycle log"
  fi
  seen_digests="${seen_digests}${digest}"$'\n'

  extension_pid="$(
    grep -F 'Extension initialized' "$cycle_log" |
      grep -F 'compatible=true' |
      sed -nE 's/.*IdleScreenScreenSaver\[([0-9]+):.*pid=([0-9]+) compatible=true.*/\1 \2/p' |
      awk '$1 == $2 { print $1 }' |
      tail -1
  )"
  [[ "$extension_pid" =~ ^[1-9][0-9]*$ ]] || fatal "$cycle_name has no correlated extension PID"

  start_record="$(
    grep -F "IdleScreenScreenSaver[$extension_pid:" "$cycle_log" |
      grep -F 'Animation started preview=false' |
      tail -1
  )"
  [[ -n "$start_record" ]] || fatal "$cycle_name has no correlated full-screen start record"
  instance_identifier="$(
    sed -nE 's/.* instance=([^[:space:]]+) display=[^[:space:]]+.*/\1/p' <<<"$start_record"
  )"
  [[ -n "$instance_identifier" ]] ||
    fatal "$cycle_name has no exact correlated saver instance"
  host_activity_record_count="$(
    sed -nE 's/.*hostActivityRecords=([0-9]+).*/\1/p' <<<"$verification_output" |
      tail -1
  )"
  [[ "$host_activity_record_count" =~ ^[1-9][0-9]*$ ]] ||
    fatal "$cycle_name has no correlated global host-activity records"
  host_activity_changed="$(
    sed -nE 's/.* changed=(true|false) cameraDemand=(true|false).*/\1/p' \
      <<<"$verification_output" |
      tail -1
  )"
  host_activity_camera_demand="$(
    sed -nE 's/.* changed=(true|false) cameraDemand=(true|false).*/\2/p' \
      <<<"$verification_output" |
      tail -1
  )"
  [[ "$host_activity_changed" == true || "$host_activity_changed" == false ]] ||
    fatal "$cycle_name has no correlated host-activity change flag"
  [[ "$host_activity_camera_demand" == true || "$host_activity_camera_demand" == false ]] ||
    fatal "$cycle_name has no correlated camera-demand flag"

  lifecycle_identity="$extension_pid|$instance_identifier|$start_record"
  if grep -Fxq "$lifecycle_identity" <<<"$seen_identities"; then
    fatal "$cycle_name duplicates an earlier lifecycle identity"
  fi
  seen_identities="${seen_identities}${lifecycle_identity}"$'\n'

  printf '%s\tpid=%s\tinstance=%s\thostActivityRecords=%s\tchanged=%s\tcameraDemand=%s\tsha256=%s\n' \
    "$cycle_name" \
    "$extension_pid" \
    "$instance_identifier" \
    "$host_activity_record_count" \
    "$host_activity_changed" \
    "$host_activity_camera_demand" \
    "$digest"
done

echo "PASS: completed $expected_cycles independently retained physical host cycles."
