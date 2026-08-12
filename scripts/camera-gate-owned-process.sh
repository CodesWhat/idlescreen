#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 identity pid /exact/executable cdhash" >&2
  echo "       $0 term-once|cleanup pid /exact/executable cdhash expected-identity" >&2
  exit 64
}

[[ $# -eq 4 || $# -eq 5 ]] || usage
operation="$1"
pid="$2"
expected_path="$3"
expected_cdhash="$4"
expected_identity="${5:-}"
[[ "$operation" == identity || "$operation" == term-once || "$operation" == cleanup ]] || usage
[[ "$pid" =~ ^[1-9][0-9]*$ && "$expected_path" = /* && -n "$expected_cdhash" ]] || usage
if [[ "$operation" == identity ]]; then
  [[ -z "$expected_identity" ]] || usage
else
  [[ -n "$expected_identity" ]] || usage
fi

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

ps_command="${IDLESCREEN_PROCESS_GUARD_PS:-/bin/ps}"
codesign_command="${IDLESCREEN_PROCESS_GUARD_CODESIGN:-/usr/bin/codesign}"
if [[ "$ps_command" != /bin/ps || "$codesign_command" != /usr/bin/codesign ]]; then
  [[ "${IDLESCREEN_PROCESS_GUARD_FIXTURE_MODE:-}" == YES ]] ||
    fail "process metadata command overrides require explicit fixture mode"
fi
[[ "$ps_command" = /* && -x "$ps_command" ]] || fail "process metadata command is unavailable"
[[ "$codesign_command" = /* && -x "$codesign_command" ]] || fail "code-signature command is unavailable"

cdhash_for_code() {
  "$codesign_command" -d --verbose=4 "$1" 2>&1 |
    /usr/bin/awk -F= '$1 == "CDHash" { print $2; exit }'
}

current_identity() {
  local process_record
  local dynamic_cdhash
  process_record="$("$ps_command" -p "$pid" -o lstart= -o comm= | /usr/bin/xargs)"
  [[ "$process_record" == *" $expected_path" ]] || return 1
  "$codesign_command" --verify --verbose=4 "$pid" >/dev/null 2>&1 || return 1
  dynamic_cdhash="$(cdhash_for_code "$pid")"
  [[ "$dynamic_cdhash" == "$expected_cdhash" ]] || return 1
  printf '%s|%s\n' "$process_record" "$dynamic_cdhash"
}

if [[ "$operation" == identity ]]; then
  current_identity || fail "process path, start time, or dynamic CDHash is unavailable"
  exit 0
fi

if ! /bin/kill -0 "$pid" 2>/dev/null; then
  [[ "$operation" == cleanup ]] && exit 0
  fail "fault target exited before guarded termination"
fi

identity="$(current_identity || true)"
[[ -n "$identity" && "$identity" == "$expected_identity" ]] ||
  fail "owned process identity changed before TERM"
/bin/kill -TERM "$pid"

[[ "$operation" == term-once ]] && exit 0

for _ in {1..20}; do
  /bin/kill -0 "$pid" 2>/dev/null || exit 0
  /bin/sleep 0.1
done

# TERM-ignoring owned children are force-closed, but only after the immutable
# start-time/path/CDHash tuple is revalidated immediately before KILL.
identity="$(current_identity || true)"
[[ -n "$identity" && "$identity" == "$expected_identity" ]] ||
  fail "owned process identity changed before KILL"
/bin/kill -KILL "$pid"
for _ in {1..10}; do
  /bin/kill -0 "$pid" 2>/dev/null || exit 0
  /bin/sleep 0.1
done
fail "owned process remained alive after bounded TERM and KILL"
