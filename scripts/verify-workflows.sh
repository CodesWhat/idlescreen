#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"

if command -v actionlint >/dev/null 2>&1; then
  /usr/bin/find .github/workflows -maxdepth 1 -type f \
    \( -name '*.yml' -o -name '*.yaml' \) -exec actionlint {} +
else
  echo "SKIP: actionlint is not installed; CI still enforces it."
fi

if command -v zizmor >/dev/null 2>&1; then
  zizmor .github/workflows/ --min-severity medium
else
  echo "SKIP: zizmor is not installed; CI still enforces it."
fi
