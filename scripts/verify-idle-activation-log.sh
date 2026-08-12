#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/path/to/host.log" >&2
  exit 64
}

[[ $# -eq 1 ]] || usage

log_path="$1"
[[ "$log_path" = /* ]] || usage
[[ -f "$log_path" ]] || {
  echo "INCOMPLETE: host log does not exist: $log_path" >&2
  exit 1
}

start_line="$(
  grep -nF 'IdleScreenScreenSaver[' "$log_path" |
    grep -F 'Animation started preview=false' |
    tail -1 |
    cut -d: -f1 || true
)"
if [[ ! "$start_line" =~ ^[1-9][0-9]*$ ]]; then
  echo "INCOMPLETE: no real full-screen extension start is present." >&2
  exit 1
fi

idle_line="$(
  grep -nF 'loginwindow[' "$log_path" |
    grep -F 'kLWLockFromScreenSaverIdleLaunch (3)' |
    awk -F: -v start="$start_line" '$1 < start { line = $1 } END { print line }' || true
)"
non_idle_line="$(
  grep -nF 'loginwindow[' "$log_path" |
    grep -E 'kLWLockFromScreenSaver(OtherLaunch|HotCornerActivation|Preview)' |
    awk -F: -v start="$start_line" '$1 < start { line = $1 } END { print line }' || true
)"

if [[ "$non_idle_line" =~ ^[1-9][0-9]*$ ]] &&
   { [[ ! "$idle_line" =~ ^[1-9][0-9]*$ ]] || ((non_idle_line > idle_line)); }; then
  echo "FAIL: the extension was started by a non-idle screen-saver launch path." >&2
  exit 2
fi

if [[ ! "$idle_line" =~ ^[1-9][0-9]*$ ]]; then
  echo "INCOMPLETE: Tahoe idle-timer launch-origin evidence is missing." >&2
  exit 1
fi

echo "PASS: loginwindow classified the extension start as kLWLockFromScreenSaverIdleLaunch (3)."
