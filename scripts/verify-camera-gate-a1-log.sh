#!/bin/bash

set -euo pipefail

usage() {
  echo "Usage: $0 a1t|a1tr /absolute/path/to/combined.log /absolute/path/to/evidence-manifest.txt" >&2
  exit 64
}

[[ $# -eq 3 ]] || usage
mode="$1"
log_path="$2"
manifest_path="$3"
[[ "$mode" == a1t || "$mode" == a1tr ]] || usage
[[ "$log_path" = /* && -f "$log_path" ]] || usage
[[ "$manifest_path" = /* && -f "$manifest_path" ]] || usage

project_root="$(cd "$(dirname "$0")/.." && pwd)"
parser="$project_root/scripts/verify_camera_gate_a1_log.py"
[[ -f "$parser" ]] || {
  echo "FAIL: missing ordered camera-gate evidence parser" >&2
  exit 1
}

exec /usr/bin/python3 "$parser" "$mode" "$log_path" "$manifest_path"
