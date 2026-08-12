#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/path/to/host.log true|false [minimum-duration-seconds]" >&2
  exit 64
}

[[ $# -ge 2 && $# -le 3 ]] || usage

log_path="$1"
expected_preview="$2"
minimum_duration_seconds="${3:-0}"
project_root="$(cd "$(dirname "$0")/.." && pwd)"
base_verifier="$project_root/scripts/verify-host-lifecycle-log.sh"

[[ "$log_path" = /* ]] || usage
[[ "$expected_preview" == true || "$expected_preview" == false ]] || usage
[[ "$minimum_duration_seconds" =~ ^[0-9]+$ ]] || usage

"$base_verifier" "$log_path" "$expected_preview"

start_line=""
end_line=""

process_exit_matches_for_pid() {
  local extension_pid="$1"
  grep -nF 'launchservicesd[' "$log_path" |
    grep -E 'com\.idlescreen\.app(\.dev)?\.screensaver|idlescreen \(Wallpaper\)' |
    grep -E "pid\"?[=:][[:space:]]*${extension_pid}([^0-9]|$)|pid:${extension_pid}([^0-9]|$)" || true
}

clean_process_exit_match_for_pid() {
  local extension_pid="$1"
  process_exit_matches_for_pid "$extension_pid" |
    grep -E '(exitStatus|LSExitStatus)"?=[[:space:]]*0([^0-9]|$)' |
    tail -1 || true
}

nonzero_process_exit_match_for_pid() {
  local extension_pid="$1"
  process_exit_matches_for_pid "$extension_pid" |
    grep -E '(exitStatus|LSExitStatus)"?=[[:space:]]*[1-9][0-9]*([^0-9]|$)' |
    tail -1 || true
}

while IFS= read -r extension_pid; do
  [[ "$extension_pid" =~ ^[1-9][0-9]*$ ]] || continue
  process_prefix="IdleScreenScreenSaver[$extension_pid:"
  candidate_start_match="$(
    grep -nF "$process_prefix" "$log_path" |
      grep -F "Animation started preview=$expected_preview" |
      tail -1 || true
  )"
  candidate_start_line="${candidate_start_match%%:*}"
  candidate_start_record="${candidate_start_match#*:}"
  candidate_instance="$(
    sed -nE 's/.* instance=([^[:space:]]+) display=[^[:space:]]+.*/\1/p' \
      <<<"$candidate_start_record"
  )"
  candidate_stop_line="$(
    grep -nF "$process_prefix" "$log_path" |
      grep -F "Animation stopped preview=$expected_preview" |
      grep -F "instance=$candidate_instance display=" |
      tail -1 |
      cut -d: -f1 || true
  )"

  nonzero_exit_match="$(nonzero_process_exit_match_for_pid "$extension_pid")"
  if [[ -n "$nonzero_exit_match" ]] &&
     ((${nonzero_exit_match%%:*} > candidate_start_line)); then
    echo "FAIL: extension process $extension_pid exited with a nonzero status after animation started." >&2
    exit 2
  fi

  clean_exit_match="$(clean_process_exit_match_for_pid "$extension_pid")"
  candidate_exit_line="${clean_exit_match%%:*}"
  candidate_end_line="$candidate_stop_line"
  if [[ -z "$candidate_end_line" ]] ||
     { [[ -n "$candidate_exit_line" ]] && ((candidate_exit_line > candidate_end_line)); }; then
    candidate_end_line="$candidate_exit_line"
  fi

  if [[ -n "$candidate_start_line" && -n "$candidate_end_line" ]] &&
     ((candidate_end_line > candidate_start_line)) &&
     { [[ -z "$start_line" ]] || ((candidate_start_line > start_line)); }; then
    start_line="$candidate_start_line"
    end_line="$candidate_end_line"
  fi
done < <(
  grep -F 'Extension initialized' "$log_path" |
    grep -F 'compatible=true' |
    sed -nE 's/.*pid=([0-9]+).*/\1/p' |
    awk '!seen[$0]++'
)

if [[ -z "$start_line" || -z "$end_line" ]] || ((end_line <= start_line)); then
  echo "WAIT: same-process callback or clean-exit invalidation evidence is incomplete." >&2
  exit 1
fi

if ((minimum_duration_seconds > 0)); then
  start_record="$(sed -n "${start_line}p" "$log_path")"
  end_record="$(sed -n "${end_line}p" "$log_path")"

  if [[ ! "$start_record" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2})\.[0-9]{3} ]] ||
    [[ ! "$end_record" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2})\.[0-9]{3} ]]; then
    echo "WAIT: timestamped lifecycle evidence is required to prove sustained animation." >&2
    exit 1
  fi

  start_timestamp="${start_record:0:19}"
  end_timestamp="${end_record:0:19}"
  start_epoch="$(/bin/date -j -f '%Y-%m-%d %H:%M:%S' "$start_timestamp" '+%s' 2>/dev/null || true)"
  end_epoch="$(/bin/date -j -f '%Y-%m-%d %H:%M:%S' "$end_timestamp" '+%s' 2>/dev/null || true)"
  if [[ -z "$start_epoch" || -z "$end_epoch" ]]; then
    echo "WAIT: lifecycle timestamps could not be parsed." >&2
    exit 1
  fi

  lifecycle_duration=$((end_epoch - start_epoch))
  if ((lifecycle_duration < minimum_duration_seconds)); then
    echo "FAIL: animation lasted ${lifecycle_duration}s; at least ${minimum_duration_seconds}s is required." >&2
    exit 2
  fi
fi

echo "PASS: extension animation ended through a same-process callback or clean process invalidation."
