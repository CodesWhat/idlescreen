#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 /absolute/path/to/session /absolute/path/to/host.log target-cycles [minimum-duration-seconds]" >&2
  exit 64
}

[[ $# -ge 3 && $# -le 4 ]] || usage

session_dir="$1"
source_log="$2"
target_cycles="$3"
minimum_duration_seconds="${4:-5}"
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cycle_verifier="$project_root/scripts/verify-host-lifecycle-cycle-log.sh"
matrix_verifier="$project_root/scripts/verify-host-lifecycle-matrix-evidence.sh"

[[ "$session_dir" = /* ]] || usage
[[ "$source_log" = /* ]] || usage
[[ "$target_cycles" =~ ^[1-9][0-9]*$ ]] || usage
[[ "$minimum_duration_seconds" =~ ^[0-9]+$ ]] || usage

incomplete() {
  echo "INCOMPLETE: $*" >&2
  exit 1
}

fatal() {
  echo "FAIL: $*" >&2
  exit 2
}

[[ -f "$source_log" ]] || incomplete "source host log does not exist: $source_log"
[[ -x "$cycle_verifier" ]] || fatal "missing completed-cycle verifier"
[[ -x "$matrix_verifier" ]] || fatal "missing matrix-evidence verifier"

set +e
source_verification="$("$cycle_verifier" "$source_log" false "$minimum_duration_seconds" 2>&1)"
source_status=$?
set -e
case "$source_status" in
  0) ;;
  1) incomplete "source host log lacks complete invalidation evidence" ;;
  *)
    printf '%s\n' "$source_verification" >&2
    fatal "source host log contains fatal lifecycle evidence"
    ;;
esac

mkdir -p "$session_dir"
target_record="$session_dir/target-cycles.txt"
if [[ -f "$target_record" ]]; then
  recorded_target="$(tr -d '[:space:]' <"$target_record")"
  [[ "$recorded_target" == "$target_cycles" ]] ||
    fatal "session target is $recorded_target cycles, not $target_cycles"
else
  printf '%s\n' "$target_cycles" >"$target_record"
fi

cycle_count="$(find "$session_dir" -maxdepth 1 -type f -name 'cycle-*.log' | wc -l | tr -d ' ')"
if ((cycle_count > 0)); then
  set +e
  existing_verification="$("$matrix_verifier" "$session_dir" "$cycle_count" "$minimum_duration_seconds" 2>&1)"
  existing_status=$?
  set -e
  [[ "$existing_status" -eq 0 ]] || {
    printf '%s\n' "$existing_verification" >&2
    fatal "existing matrix session is not internally valid"
  }
fi

((cycle_count < target_cycles)) || fatal "session already contains all $target_cycles requested cycles"

source_digest="$(/usr/bin/shasum -a 256 "$source_log" | awk '{ print $1 }')"
while IFS= read -r existing_log; do
  [[ -n "$existing_log" ]] || continue
  existing_digest="$(/usr/bin/shasum -a 256 "$existing_log" | awk '{ print $1 }')"
  [[ "$existing_digest" != "$source_digest" ]] || fatal "source log duplicates retained evidence"
done < <(find "$session_dir" -maxdepth 1 -type f -name 'cycle-*.log' | sort)

next_cycle=$((cycle_count + 1))
printf -v cycle_name 'cycle-%02d' "$next_cycle"
destination="$session_dir/$cycle_name.log"
[[ ! -e "$destination" ]] || fatal "destination already exists: $destination"
cp "$source_log" "$destination"

set +e
aggregate_output="$("$matrix_verifier" "$session_dir" "$next_cycle" "$minimum_duration_seconds" 2>&1)"
aggregate_status=$?
set -e
if [[ "$aggregate_status" -ne 0 ]]; then
  /bin/rm -f "$destination"
  printf '%s\n' "$aggregate_output" >&2
  fatal "new cycle did not preserve an independently valid matrix session"
fi
printf '%s\n' "$aggregate_output" >"$session_dir/matrix-verification.txt"

if ((next_cycle == target_cycles)); then
  echo "PASS: recorded and verified all $target_cycles physical host cycles."
else
  echo "INCOMPLETE: recorded $next_cycle of $target_cycles required physical host cycles."
fi
echo "Evidence: $session_dir"
