#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 [ioreg-plist-fixture]" >&2
  exit 64
}

[[ $# -le 1 ]] || usage

read_lock_state() {
  if (($# == 1)); then
    /usr/bin/plutil \
      -extract IOConsoleLocked raw \
      -expect bool \
      -o - \
      "$1" 2>/dev/null
  else
    /usr/sbin/ioreg -n Root -d1 -a |
      /usr/bin/plutil \
        -extract IOConsoleLocked raw \
        -expect bool \
        -o - \
        - 2>/dev/null
  fi
}

lock_state="$(read_lock_state "$@")" || exit 2
case "$lock_state" in
  true | false) printf '%s\n' "$lock_state" ;;
  *) exit 2 ;;
esac
