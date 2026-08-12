#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
fixture_root="$(mktemp -d /tmp/idlescreen-launch-policy.XXXXXX)"

cleanup() {
  rm -rf "$fixture_root"
}

trap cleanup EXIT

xcrun swiftc \
  -parse-as-library \
  "$project_root/IdleScreenApp/IdleScreenLaunchPolicy.swift" \
  "$project_root/scripts/IdleScreenLaunchPolicyProbe.swift" \
  -o "$fixture_root/launch-policy-probe"

"$fixture_root/launch-policy-probe"
