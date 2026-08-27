#!/bin/bash

set -euo pipefail

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: $0 /path/to/commit-message" >&2
  exit 64
fi

subject="$(/usr/bin/sed -n '1p' "$1")"
pattern='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([a-z0-9][a-z0-9._/-]*\))?!?: [^[:space:]].+$'

if [[ ! "$subject" =~ $pattern ]]; then
  echo "Commit subject must use plain Conventional Commits:" >&2
  echo "  <type>(<optional scope>): <description>" >&2
  exit 1
fi
