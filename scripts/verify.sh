#!/bin/bash
# Full local gate: everything the slim pre-push hook no longer runs, in the
# order the hook used to run it. Fails fast and prints a summary.
# Usage: scripts/verify.sh

set -uo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root" || exit 1

names=()
seconds=()

summary() {
  local i
  echo
  echo "verify summary"
  for i in "${!names[@]}"; do
    printf '  %-32s %4ss\n' "${names[$i]}" "${seconds[$i]}"
  done
}

run_step() {
  local name="$1"
  shift
  local started=$SECONDS
  echo "==> $name"
  if "$@"; then
    names+=("$name PASS")
    seconds+=($((SECONDS - started)))
    return 0
  fi
  names+=("$name FAIL")
  seconds+=($((SECONDS - started)))
  summary
  echo "FAIL: $name" >&2
  exit 1
}

clean_tree() { test -z "$(git status --porcelain)"; }

repository_contracts() {
  ./scripts/test-repository-layout.sh && ./scripts/test-project-contracts.sh &&
    ./scripts/test-app-accessibility-labels.sh
}

release_fixtures() {
  # Keep in step with "Run deterministic product fixtures" in ci-verify.yml;
  # test-repository-layout.sh fails when a scripts/test-* file is in neither.
  python3 ./scripts/test_xccov_to_lcov.py &&
    python3 ./scripts/test_performance_r1_report.py &&
    ./scripts/test-run-performance-r1.sh &&
    ./scripts/test-camera-gate-c8-soak-planner.py &&
    ./scripts/test-controlled-physical-soak.py &&
    ./scripts/test-camera-gate-c4-evidence-fixtures.py &&
    ./scripts/test-camera-gate-c5-evidence-fixtures.py &&
    ./scripts/test-companion-compile-gate.sh &&
    ./scripts/test-release-archive-provenance-fixtures.sh &&
    ./scripts/test-r1-release-candidate-fixtures.sh &&
    ./scripts/test-public-release-contract.sh &&
    ./scripts/test-camera-agent-product-fixtures.sh &&
    ./scripts/test-synthetic-gate-product-fixtures.sh &&
    ./scripts/test-idlescreenctl-runtime.sh &&
    ./scripts/test-camera-agent-profile-policy.sh &&
    ./scripts/test-camera-gate-a1-config.sh &&
    ./scripts/test-camera-gate-a1-runner.sh &&
    ./scripts/test-companion-launch-policy.sh &&
    ./scripts/test-console-lock-state.sh &&
    ./scripts/test-host-lifecycle-log.sh &&
    ./scripts/test-host-lifecycle-matrix-evidence.sh &&
    ./scripts/test-host-lifecycle-matrix-guard.sh &&
    ./scripts/test-idle-activation-log.sh &&
    ./scripts/test-install-phase1-release-registration.sh &&
    ./scripts/test-live-configuration-delivery-guard.sh &&
    ./scripts/test-physical-state-transition.sh &&
    ./scripts/test-product-identity-verifier.sh &&
    ./scripts/test-record-host-lifecycle-matrix-cycle.sh &&
    ./scripts/test-selection-probe.sh &&
    ./scripts/test-shared-state-verifier.sh &&
    ./scripts/test-synthetic-gate-contracts.sh &&
    ./scripts/test-synthetic-gate-transaction.sh
}

release_build() {
  xcodebuild build -quiet -project IdleScreen.xcodeproj -scheme IdleScreenApp \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
}

run_step clean-tree clean_tree
run_step swift-format ./scripts/check-swift-format.sh changed
run_step qlty ./scripts/qlty-check-gate.sh all
run_step workflow-security ./scripts/verify-workflows.sh
run_step repository-contracts repository_contracts
run_step xcode-tests ./scripts/test-modern-schemes.sh
run_step release-fixtures release_fixtures
run_step release-build release_build

summary
echo "PASS: scripts/verify.sh"
