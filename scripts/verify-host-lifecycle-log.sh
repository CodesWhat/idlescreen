#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/path/to/host.log true|false" >&2
  exit 64
}

[[ $# -eq 2 ]] || usage

log_path="$1"
expected_preview="$2"

[[ "$log_path" = /* ]] || usage
[[ -f "$log_path" ]] || {
  echo "FAIL: missing host log: $log_path" >&2
  exit 2
}
[[ "$expected_preview" == true || "$expected_preview" == false ]] || usage

if grep -Eiq \
  'readyController error|unrecognized selector|ViewBridge Code=14|compatible=false|Missing ScreenSaver extension classes|Failed to find screen saver module|Failed to translate LiveContentKey|contentSettingsFailedToTranslate|provider=com\.apple\.wallpaper\.choice\.aerials|legacyScreenSaver.*com\.idlescreen\.screensaver|com\.idlescreen\.screensaver.*legacyScreenSaver' \
  "$log_path"; then
  echo "FAIL: host log contains a fatal extension, module-resolution, fallback, or legacy-renderer error." >&2
  exit 2
fi

malformed_host_activity="$({
  grep -F 'IdleScreenScreenSaver[' "$log_path" |
    grep -F 'Global host activity' |
    grep -Ev 'Global host activity state=(unavailable|inactive|running-foreground|running-background|inconsistent) source=(initialize|start-animation|animation-frame) changed=(true|false) cameraDemand=(true|false)($|[[:space:]])' || true
})"
if [[ -n "$malformed_host_activity" ]]; then
  echo "FAIL: global host-activity diagnostic is malformed or outside the read-only state vocabulary." >&2
  exit 2
fi

extension_pids="$(
  grep -F 'IdleScreenScreenSaver[' "$log_path" |
    grep -F 'Extension initialized' |
    grep -F 'compatible=true' |
    sed -nE 's/.*IdleScreenScreenSaver\[([0-9]+):.*pid=([0-9]+) compatible=true.*/\1 \2/p' |
    awk '$1 == $2 && !seen[$1]++ { print $1 }' || true
)"

if [[ -z "$extension_pids" ]]; then
  echo "WAIT: real extension-process initialization evidence is incomplete." >&2
  exit 1
fi

while IFS= read -r extension_pid; do
  [[ "$extension_pid" =~ ^[1-9][0-9]*$ ]] || continue
  process_prefix="IdleScreenScreenSaver[$extension_pid:"
  process_records="$(grep -F "$process_prefix" "$log_path" || true)"
  start_match="$(
    grep -nF "$process_prefix" "$log_path" |
      grep -F "Animation started preview=$expected_preview" |
      tail -1 || true
  )"
  [[ -n "$start_match" ]] || continue
  start_line="${start_match%%:*}"
  start_record="${start_match#*:}"
  instance_identifier="$(
    sed -nE 's/.* instance=([^[:space:]]+) display=[^[:space:]]+.*/\1/p' <<<"$start_record"
  )"
  if [[ -z "$instance_identifier" ]]; then
    echo "FAIL: extension process $extension_pid start evidence lacks an exact saver instance." >&2
    exit 2
  fi

  initialization_line="$(
    grep -nF "$process_prefix" "$log_path" |
      grep -F 'Extension initialized' |
      grep -F "pid=$extension_pid compatible=true" |
      awk -F: -v start="$start_line" '$1 < start { print $1 }' |
      tail -1 || true
  )"
  [[ -n "$initialization_line" ]] || continue

  previous_start_line="$(
    grep -nF "$process_prefix" "$log_path" |
      grep -F "Animation started preview=$expected_preview" |
      awk -F: -v start="$start_line" '$1 < start { print $1 }' |
      tail -1 || true
  )"
  activity_boundary_line="$initialization_line"
  if [[ -n "$previous_start_line" ]] &&
     ((previous_start_line > activity_boundary_line)); then
    activity_boundary_line="$previous_start_line"
  fi

  host_activity_records="$(
    grep -nF "$process_prefix" "$log_path" |
      grep -F 'Global host activity' || true
  )"
  correlated_activity_records="$(
    awk -F: -v boundary="$activity_boundary_line" -v started="$start_line" \
      '$1 > boundary && $1 < started' <<<"$host_activity_records"
  )"
  correlated_start_activity="$(
    grep -F 'source=start-animation' <<<"$correlated_activity_records" |
      tail -1 || true
  )"
  [[ -n "$correlated_start_activity" ]] || continue
  host_activity_changed="$(
    sed -nE 's/.* changed=(true|false) cameraDemand=(true|false)([[:space:]]|$).*/\1/p' \
      <<<"$correlated_start_activity"
  )"
  host_activity_camera_demand="$(
    sed -nE 's/.* changed=(true|false) cameraDemand=(true|false)([[:space:]]|$).*/\2/p' \
      <<<"$correlated_start_activity"
  )"
  [[ "$host_activity_changed" == true || "$host_activity_changed" == false ]] || continue
  [[ "$host_activity_camera_demand" == true || "$host_activity_camera_demand" == false ]] || continue

  host_activity_count="$(grep -Fc 'Global host activity' <<<"$correlated_activity_records" || true)"
  if grep -F 'Loading view' <<<"$process_records" | grep -Fq "preview=$expected_preview"; then
    echo "PASS: real extension process $extension_pid instance=$instance_identifier initialized, loaded, and started with preview=$expected_preview hostActivityRecords=$host_activity_count changed=$host_activity_changed cameraDemand=$host_activity_camera_demand diagnostic=read-only."
    exit 0
  fi
done <<<"$extension_pids"

echo "WAIT: one real extension PID/instance lacks initialization, loading, start, or correlated read-only host-activity evidence." >&2
exit 1
