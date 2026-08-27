#!/usr/bin/env bash

set -euo pipefail

mode="${1:-all}"
case "$mode" in
  all | changed) ;;
  *)
    echo "Usage: $0 [all|changed]" >&2
    exit 64
    ;;
esac

command=(qlty check --no-progress)
if [[ "$mode" == all ]]; then
  command+=(--all)
elif git rev-parse --verify --quiet refs/remotes/origin/main >/dev/null; then
  command+=(--upstream origin/main)
fi

echo "Running Qlty gate: ${command[*]}"
"${command[@]}" </dev/null
