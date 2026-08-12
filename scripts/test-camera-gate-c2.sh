#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
artifact_root="$(mktemp -d /tmp/idlescreen-camera-gate-c2.XXXXXX)"
trap '/bin/rm -rf "$artifact_root"' EXIT

cd "$project_root"

# Project generation is metadata-only. This aggregate must never build an
# application product, install/register either gate artifact, launch a host, or
# access the camera.
xcodegen generate
./scripts/test-repository-layout.sh
./scripts/test-project-contracts.sh
./scripts/test-camera-agent-product-fixtures.sh
./scripts/test-synthetic-gate-contracts.sh
./scripts/test-synthetic-gate-product-fixtures.sh
./scripts/test-synthetic-gate-transaction.sh
./scripts/test-camera-gate-a1-config.sh
./scripts/test-camera-gate-a1-runner.sh

run_non_application_tests() {
  local scheme="$1"
  local result_name="$2"
  shift 2
  xcodebuild test -quiet \
    -project "$project_root/IdleScreen.xcodeproj" \
    -scheme "$scheme" \
    -destination 'platform=macOS' \
    -derivedDataPath "$artifact_root/${result_name}DerivedData" \
    -resultBundlePath "$artifact_root/$result_name.xcresult" \
    CODE_SIGNING_ALLOWED=NO \
    "$@"
}

run_non_application_tests \
  IdleScreenSyntheticGateTests \
  SyntheticGate
run_non_application_tests \
  IdleScreenScreenSaver \
  SyntheticHostedGate \
  -only-testing:IdleScreenScreenSaverTests/IdleScreenSyntheticHostedGateViewControllerTests

echo "PASS: C2 helper/hosted-product, transaction, runner, config, and isolated test gates are green."
echo "PASS: no application product was built, installed, registered, launched, or granted camera access."
