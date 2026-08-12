#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/path/to/host.log true|false display-id [display-id ...]" >&2
  exit 64
}

[[ $# -ge 3 ]] || usage

log_path="$1"
expected_preview="$2"
shift 2
expected_display_identifiers=("$@")
project_root="$(cd "$(dirname "$0")/.." && pwd)"
base_verifier="$project_root/scripts/verify-host-lifecycle-log.sh"
minimum_sustain_seconds="${IDLESCREEN_MINIMUM_DISPLAY_SUSTAIN_SECONDS:-0}"

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

[[ "$log_path" = /* ]] || usage
[[ "$expected_preview" == true || "$expected_preview" == false ]] || usage
[[ "$minimum_sustain_seconds" =~ ^[0-9]+$ ]] || usage
for display_identifier in "${expected_display_identifiers[@]}"; do
  [[ "$display_identifier" =~ ^[0-9]+$ ]] || usage
done

"$base_verifier" "$log_path" "$expected_preview"

seen_instances="|"

for display_identifier in "${expected_display_identifiers[@]}"; do
  resolution_match="$(
    grep -nF 'IdleScreenScreenSaver[' "$log_path" |
      grep -F 'Display resolved' |
      grep -E "display=${display_identifier}($|[[:space:]])" |
      tail -1 || true
  )"

  if [[ -n "$resolution_match" ]]; then
    resolution_line="${resolution_match%%:*}"
    resolution_record="${resolution_match#*:}"
    instance_identifier="$(sed -nE 's/.*instance=([^[:space:]]+).*/\1/p' <<<"$resolution_record")"
    extension_pid="$(sed -nE 's/.*IdleScreenScreenSaver\[([0-9]+):.*/\1/p' <<<"$resolution_record")"
    start_match="$(
      grep -nF "IdleScreenScreenSaver[$extension_pid:" "$log_path" |
        grep -F "Animation started preview=$expected_preview" |
        grep -F "instance=$instance_identifier" |
        tail -1 || true
    )"
  else
    start_match="$(
      grep -nF 'IdleScreenScreenSaver[' "$log_path" |
        grep -F "Animation started preview=$expected_preview" |
        grep -E "display=${display_identifier}($|[[:space:]])" |
        tail -1 || true
    )"
    start_record="${start_match#*:}"
    instance_identifier="$(sed -nE 's/.*instance=([^[:space:]]+).*/\1/p' <<<"$start_record")"
    extension_pid="$(sed -nE 's/.*IdleScreenScreenSaver\[([0-9]+):.*/\1/p' <<<"$start_record")"
  fi

  if [[ -z "$start_match" ]]; then
    echo "WAIT: display $display_identifier has no post-migration animation-start evidence." >&2
    exit 1
  fi

  start_line="${start_match%%:*}"
  start_record="${start_match#*:}"
  if [[ -z "$instance_identifier" || ! "$extension_pid" =~ ^[1-9][0-9]*$ ]]; then
    echo "FAIL: display $display_identifier start evidence lacks a view instance or extension PID." >&2
    exit 2
  fi
  if [[ -n "$resolution_match" ]] && ((resolution_line <= start_line)); then
    echo "FAIL: display $display_identifier resolution predates its hosted-view animation start." >&2
    exit 2
  fi

  if [[ "$seen_instances" == *"|$instance_identifier|"* ]]; then
    echo "FAIL: view instance $instance_identifier was reused for multiple displays." >&2
    exit 2
  fi
  seen_instances+="$instance_identifier|"

  if ! grep -F "IdleScreenScreenSaver[$extension_pid:" "$log_path" |
       grep -F 'Extension initialized' |
       grep -Fq "pid=$extension_pid compatible=true"; then
    echo "WAIT: display $display_identifier start is not tied to a compatible initialized process." >&2
    exit 1
  fi

  stop_match="$(
    grep -nF "IdleScreenScreenSaver[$extension_pid:" "$log_path" |
      grep -F "Animation stopped preview=$expected_preview" |
      grep -F "instance=$instance_identifier" |
      grep -E "display=${display_identifier}($|[[:space:]])" |
      tail -1 || true
  )"

  nonzero_exit_match="$(nonzero_process_exit_match_for_pid "$extension_pid")"
  if [[ -n "$nonzero_exit_match" ]] &&
     ((${nonzero_exit_match%%:*} > start_line)); then
    echo "FAIL: display $display_identifier extension process $extension_pid exited with a nonzero status." >&2
    exit 2
  fi

  clean_exit_match="$(clean_process_exit_match_for_pid "$extension_pid")"
  end_match="$stop_match"
  if [[ -z "$end_match" ]] ||
     { [[ -n "$clean_exit_match" ]] && ((${clean_exit_match%%:*} > ${end_match%%:*})); }; then
    end_match="$clean_exit_match"
  fi
  if [[ -z "$end_match" ]]; then
    echo "WAIT: display $display_identifier view $instance_identifier has no callback or clean-exit teardown evidence." >&2
    exit 1
  fi
  end_line="${end_match%%:*}"
  if ((end_line <= start_line)); then
    echo "WAIT: display $display_identifier teardown evidence predates its start." >&2
    exit 1
  fi

  if ((minimum_sustain_seconds > 0)); then
    end_record="${end_match#*:}"
    if [[ ! "$start_record" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2})\.[0-9]{3} ]] ||
       [[ ! "$end_record" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2})\.[0-9]{3} ]]; then
      echo "WAIT: timestamped lifecycle evidence is required for display $display_identifier." >&2
      exit 1
    fi
    start_timestamp="${start_record:0:19}"
    end_timestamp="${end_record:0:19}"
    start_epoch="$(/bin/date -j -f '%Y-%m-%d %H:%M:%S' "$start_timestamp" '+%s' 2>/dev/null || true)"
    end_epoch="$(/bin/date -j -f '%Y-%m-%d %H:%M:%S' "$end_timestamp" '+%s' 2>/dev/null || true)"
    if [[ -z "$start_epoch" || -z "$end_epoch" ]]; then
      echo "WAIT: display $display_identifier lifecycle timestamps could not be parsed." >&2
      exit 1
    fi
    lifecycle_duration=$((end_epoch - start_epoch))
    if ((lifecycle_duration < minimum_sustain_seconds)); then
      echo "FAIL: display $display_identifier animated for ${lifecycle_duration}s; at least ${minimum_sustain_seconds}s is required." >&2
      exit 2
    fi
  fi
done

echo "PASS: every requested display completed an independent hosted-view lifecycle."
if ((minimum_sustain_seconds > 0)); then
  echo "PASS: every requested display animated for at least ${minimum_sustain_seconds}s."
fi
