#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/path/to/idlescreen.app [idle-start-timeout-seconds] [invalidation-timeout-seconds] [minimum-sustain-seconds]" >&2
  exit 64
}

[[ $# -ge 1 && $# -le 4 ]] || usage

app_path="$1"
idle_timeout_seconds="${2:-900}"
invalidation_timeout_seconds="${3:-300}"
minimum_sustain_seconds="${4:-5}"

[[ "$app_path" = /* ]] || usage
[[ "$idle_timeout_seconds" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$invalidation_timeout_seconds" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$minimum_sustain_seconds" =~ ^[1-9][0-9]*$ ]] || usage

if [[ "${IDLESCREEN_ALLOW_PHYSICAL_TESTS:-NO}" != YES ]]; then
  echo "REFUSED: set IDLESCREEN_ALLOW_PHYSICAL_TESTS=YES only after explicitly authorizing an unattended idle/lock test." >&2
  exit 65
fi

project_root="$(cd "$(dirname "$0")/.." && pwd)"
host_runner="$project_root/scripts/test-host-lifecycle.sh"
[[ -x "$host_runner" ]] || {
  echo "FAIL: missing physical host lifecycle runner: $host_runner" >&2
  exit 1
}

echo "INFO: this gate does not change the idle interval or launch ScreenSaverEngine."
echo "INFO: configure the intended idle interval first; restore the exact prior setting after the session."

IDLESCREEN_HOST_ACTIVATION=idle \
  exec "$host_runner" \
    "$app_path" \
    "$idle_timeout_seconds" \
    "$invalidation_timeout_seconds" \
    "$minimum_sustain_seconds"
