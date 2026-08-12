#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
runner="$project_root/scripts/run-performance-r1.sh"
fixture_root="$(mktemp -d /tmp/idlescreen-performance-runner-tests.XXXXXX)"
trap '/bin/rm -rf "$fixture_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

expect_fail() {
  local description="$1"
  shift
  if "$@" >"$fixture_root/expected-failure.out" 2>&1; then
    fail "$description was accepted"
  fi
}

[[ -x "$runner" ]] || fail "missing executable R1.1 runner"
grep -Fq 'IDLESCREEN_PERF_LIBRARY_MODE' "$runner" ||
  fail "runner does not expose its pure manifest helpers without executing workloads"

export IDLESCREEN_PERF_LIBRARY_MODE=1
# shellcheck source=run-performance-r1.sh
source "$runner"

r1_validate_mode_duration gating 900 || fail "the canonical 900-second gate was rejected"
expect_fail "a short gating run" r1_validate_mode_duration gating 899
r1_validate_mode_duration smoke 30 || fail "an explicit short smoke run was rejected"
r1_validate_mode_duration smoke 10 || fail "the minimum reliable Energy smoke was rejected"
expect_fail "a smoke run shorter than reliable Energy sampling" \
  r1_validate_mode_duration smoke 9
expect_fail "a smoke run too short for Energy coverage" r1_validate_mode_duration smoke 4
expect_fail "an implicit mode" r1_validate_mode_duration "" 30
expect_fail "a 900-second smoke run" r1_validate_mode_duration smoke 900
expect_fail "a fractional duration" r1_validate_mode_duration smoke 1.5

display_fixture="$fixture_root/display.json"
budget_fixture="$fixture_root/budgets.json"
/usr/bin/jq -n '{count:1,pixelWidth:4112,pixelHeight:2658,scale:2.000000}' >"$display_fixture"
/usr/bin/jq -n '{displayCount:1,displayPixelWidth:4112,displayPixelHeight:2658,displayScale:2}' >"$budget_fixture"
r1_validate_display_budget "$display_fixture" "$budget_fixture" ||
  fail "numerically equal display scales with different JSON formatting were rejected"
wrong_scale="$fixture_root/display-wrong-scale.json"
/usr/bin/jq '.scale = 1' "$display_fixture" >"$wrong_scale"
expect_fail "a display with the wrong backing scale" \
  r1_validate_display_budget "$wrong_scale" "$budget_fixture"

cleanup_fixture="$(mktemp -d /private/tmp/idlescreen-r1-derived.XXXXXX)"
R1_TASK_DERIVED_DATA="$cleanup_fixture"
R1_TASK_CAFFEINATE_PID=""
r1_cleanup
[[ ! -e "$cleanup_fixture" ]] || fail "runner cleanup left its Derived Data behind"

lsof_fixture="$fixture_root/helper-lsof.txt"
/usr/bin/printf '%s\n' \
  p4321 ftxt n/Library/Preferences/Logging/cache \
  ftxt n/Applications/idlescreen.app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent \
  ftxt n/usr/lib/dyld >"$lsof_fixture"
selected_helper_path="$(r1_select_helper_executable_path <"$lsof_fixture")" ||
  fail "the helper executable was not selected from multiple text mappings"
[[ "$selected_helper_path" == /Applications/idlescreen.app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent ]] ||
  fail "the helper path selector returned the wrong text mapping"

preflight_candidate="$fixture_root/preflight-candidate.json"
preflight_canonical="$fixture_root/preflight-canonical.json"
/usr/bin/jq -n '
  {
    schemaVersion: 1,
    runIdentifier: "r1.1-fixture",
    capturedAt: "2026-08-09T12:01:00Z",
    artifactBuiltAt: "2026-08-09T12:00:00Z",
    mode: "gating",
    requiredDurationSeconds: 900,
    coldStartupSampleCount: 5,
    warmStartupSampleCount: 5,
    energySamplingIntervalSeconds: 1,
    sourceIdentity: {
      commit: ("a" * 40),
      diffSHA256: ("b" * 64),
      dirtyPathCount: 2
    },
    toolchain: {
      xcodeVersion: "Xcode 26.6 / Build version 17F113",
      swiftVersion: "Apple Swift version 6.3.3",
      xcodegenVersion: "Version: 2.46.0"
    },
    operatingSystem: {version: "26.5.2", build: "25F84"},
    hardware: {
      modelIdentifier: "Mac16,7",
      hardwareClass: "m4-pro",
      chip: "Apple M4 Pro",
      cpuCoreCount: 14,
      gpuCoreCount: 20,
      memoryBytes: 51539607552
    },
    display: {
      count: 1,
      logicalWidth: 2056,
      logicalHeight: 1329,
      pixelWidth: 4112,
      pixelHeight: 2658,
      scale: 2,
      refreshRateHertz: 120
    },
    targetFramesPerSecond: 30,
    targetSurface: {
      logicalWidth: 2056,
      logicalHeight: 1329,
      pixelWidth: 4112,
      pixelHeight: 2658
    },
    powerSource: "AC Power",
    artifactManifestSHA256: ("c" * 64),
    budgetsSHA256: ("d" * 64),
    workloads: [
      {
        workload: "rendererStartupCold",
        resultPaths: [
          "rendererStartupCold-1.json",
          "rendererStartupCold-2.json",
          "rendererStartupCold-3.json",
          "rendererStartupCold-4.json",
          "rendererStartupCold-5.json"
        ],
        iterationsPerResult: 1,
        durationSeconds: null,
        energyPath: null
      },
      {
        workload: "rendererStartupWarm",
        resultPaths: ["rendererStartupWarm.json"],
        iterationsPerResult: 5,
        durationSeconds: null,
        energyPath: null
      },
      {
        workload: "generative",
        resultPaths: ["generative.json"],
        iterationsPerResult: null,
        durationSeconds: 900,
        energyPath: "generative.top.csv"
      }
    ],
    environmentInputPaths: [
      "displays.json",
      "generative.footprint.csv",
      "hardware.json",
      "power-source-before.txt"
    ]
  }
' >"$preflight_candidate"

r1_canonicalize_preflight "$preflight_candidate" "$preflight_canonical" ||
  fail "a complete preflight manifest was rejected"
[[ "$(/usr/bin/jq -r '.targetSurface.pixelWidth' "$preflight_canonical")" == 4112 ]] ||
  fail "canonical preflight lost the physical target surface"
[[ "$(/usr/bin/jq -r '.workloads[2] | has("iterationsPerResult") and has("durationSeconds") and has("energyPath")' "$preflight_canonical")" == true ]] ||
  fail "canonical workload entries did not preserve explicit null keys"

missing_surface="$fixture_root/preflight-missing-surface.json"
/usr/bin/jq 'del(.targetSurface.pixelWidth)' "$preflight_candidate" >"$missing_surface"
expect_fail "a preflight without the physical target width" \
  r1_canonicalize_preflight "$missing_surface" "$fixture_root/invalid.json"

wrong_gate="$fixture_root/preflight-wrong-gate.json"
/usr/bin/jq '.requiredDurationSeconds = 30' "$preflight_candidate" >"$wrong_gate"
expect_fail "a short gating preflight" \
  r1_canonicalize_preflight "$wrong_gate" "$fixture_root/invalid-gate.json"

too_short_smoke="$fixture_root/preflight-too-short-smoke.json"
/usr/bin/jq '.mode = "smoke" | .requiredDurationSeconds = 4' "$preflight_candidate" >"$too_short_smoke"
expect_fail "a smoke preflight too short for Energy coverage" \
  r1_canonicalize_preflight "$too_short_smoke" "$fixture_root/invalid-smoke.json"

reversed_timestamps="$fixture_root/preflight-reversed-timestamps.json"
/usr/bin/jq '.artifactBuiltAt = "2026-08-09T12:02:00Z"' "$preflight_candidate" >"$reversed_timestamps"
expect_fail "a preflight captured before its artifact existed" \
  r1_canonicalize_preflight "$reversed_timestamps" "$fixture_root/invalid-timestamps.json"

preserved_preflight="$fixture_root/preserved/preflight-manifest.json"
/bin/mkdir -p "$(/usr/bin/dirname "$preserved_preflight")"
r1_install_or_compare_preflight "$preflight_canonical" "$preserved_preflight" 0 ||
  fail "a new immutable preflight was not installed"
r1_install_or_compare_preflight "$preflight_canonical" "$preserved_preflight" 1 ||
  fail "an exact resume preflight was rejected"
changed_preflight="$fixture_root/preflight-changed.json"
/usr/bin/jq -S '.display.refreshRateHertz = 60' "$preflight_canonical" >"$changed_preflight"
expect_fail "a resume with changed display semantics" \
  r1_install_or_compare_preflight "$changed_preflight" "$preserved_preflight" 1

evidence_root="$fixture_root/evidence"
/bin/mkdir -p "$evidence_root"
/usr/bin/printf 'preflight\n' >"$evidence_root/preflight-manifest.json"
/usr/bin/printf 'artifact\n' >"$evidence_root/artifact-manifest.txt"
/usr/bin/printf 'budget\n' >"$evidence_root/budgets.json"
/usr/bin/printf 'result\n' >"$evidence_root/generative.json"
/usr/bin/printf 'energy\n' >"$evidence_root/generative.top.csv"
/usr/bin/printf 'environment\n' >"$evidence_root/hardware.json"
/usr/bin/printf 'helper-start\n' >"$evidence_root/helper-start-identity.json"
/usr/bin/printf 'helper-end\n' >"$evidence_root/helper-end-identity.json"
/usr/bin/printf 'metadata\n' >"$evidence_root/metadata.json"
/usr/bin/printf 'derived report\n' >"$evidence_root/report.json"

inventory="$fixture_root/evidence-inventory.tsv"
/usr/bin/printf '%s\t%s\n' \
  workload generative.json \
  helperIdentity helper-end-identity.json \
  preflight preflight-manifest.json \
  environment hardware.json \
  budgets budgets.json \
  energy generative.top.csv \
  artifact artifact-manifest.txt \
  helperIdentity helper-start-identity.json \
  metadata metadata.json \
  >"$inventory"
evidence_manifest="$evidence_root/evidence-manifest.json"
r1_write_evidence_manifest "$evidence_root" "$inventory" "$evidence_manifest" \
  r1.1-fixture || fail "a complete evidence inventory was rejected"

[[ "$(/usr/bin/jq '.entries | length' "$evidence_manifest")" == 9 ]] ||
  fail "evidence manifest did not contain every declared raw input"
[[ "$(/usr/bin/jq -r '[.entries[].path] == ([.entries[].path] | sort)' "$evidence_manifest")" == true ]] ||
  fail "evidence entries are not canonically path-sorted"
[[ "$(/usr/bin/jq -r '[.entries[].path] | index("report.json") == null' "$evidence_manifest")" == true ]] ||
  fail "derived reports entered the canonical evidence closure"
[[ "$(/usr/bin/jq -r '.entries[] | select(.path == "generative.json") | .byteCount' "$evidence_manifest")" == 7 ]] ||
  fail "evidence byte count is not exact"

duplicate_inventory="$fixture_root/duplicate-inventory.tsv"
/bin/cp "$inventory" "$duplicate_inventory"
/usr/bin/printf 'workload\tgenerative.json\n' >>"$duplicate_inventory"
expect_fail "a duplicate evidence path" r1_write_evidence_manifest \
  "$evidence_root" "$duplicate_inventory" "$fixture_root/duplicate.json" r1.1-fixture

absolute_inventory="$fixture_root/absolute-inventory.tsv"
/usr/bin/printf 'workload\t%s\n' "$evidence_root/generative.json" >"$absolute_inventory"
expect_fail "an absolute evidence path" r1_write_evidence_manifest \
  "$evidence_root" "$absolute_inventory" "$fixture_root/absolute.json" r1.1-fixture

symlink_inventory="$fixture_root/symlink-inventory.tsv"
/bin/ln -s generative.json "$evidence_root/result-link.json"
/usr/bin/printf 'workload\tresult-link.json\n' >"$symlink_inventory"
expect_fail "a symlink evidence leaf" r1_write_evidence_manifest \
  "$evidence_root" "$symlink_inventory" "$fixture_root/symlink.json" r1.1-fixture

helper_start="$fixture_root/helper-start.json"
helper_end="$fixture_root/helper-end.json"
/usr/bin/jq -n '
  {
    schemaVersion: 1,
    capturedAt: "2026-08-09T12:10:00Z",
    launchdJob: "gui/501/group.com.idlescreen.shared.camera-agent",
    launchdSnapshot: "pid = 4321",
    pid: 4321,
    startIdentity: "Sun Aug  9 12:00:00 2026 /Applications/idlescreen.app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent",
    executablePath: "/Applications/idlescreen.app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent",
    executableSHA256: ("e" * 64),
    codesign: {
      cdHash: ("f" * 40),
      identifier: "com.idlescreen.camera-agent",
      teamIdentifier: "3524374A2S",
      staticDetails: "Identifier=com.idlescreen.camera-agent",
      dynamicDetails: "Identifier=com.idlescreen.camera-agent"
    },
    bundle: {
      identifier: "com.idlescreen.camera-agent",
      version: "28",
      shortVersion: "0.1"
    }
  }
' >"$helper_start"
/usr/bin/jq '.capturedAt = "2026-08-09T12:25:00Z"' "$helper_start" >"$helper_end"
r1_validate_helper_identity_pair "$helper_start" "$helper_end" ||
  fail "one unchanged helper identity was rejected"
changed_helper="$fixture_root/helper-changed.json"
/usr/bin/jq '.pid = 9876' "$helper_end" >"$changed_helper"
expect_fail "a helper restart inside the measurement window" \
  r1_validate_helper_identity_pair "$helper_start" "$changed_helper"

source_fixture="$fixture_root/source-fixture"
/bin/mkdir -p "$source_fixture"
/bin/mkdir -p "$fixture_root/source-evidence"
/usr/bin/git -C "$source_fixture" init -q
/usr/bin/git -C "$source_fixture" config user.name Fixture
/usr/bin/git -C "$source_fixture" config user.email fixture@example.invalid
/usr/bin/printf 'tracked baseline\n' >"$source_fixture/tracked.txt"
/usr/bin/git -C "$source_fixture" add tracked.txt
/usr/bin/git -C "$source_fixture" commit -qm baseline
r1_capture_source_identity "$source_fixture" "$fixture_root/source-evidence" \
  "$fixture_root/source-clean-snapshot.json" "$fixture_root/source-clean-identity.json"
relative_evidence=".planning/evidence/relative-run"
/bin/mkdir -p "$source_fixture/$relative_evidence/.resume-runtime/Framework/Versions/A"
/bin/ln -s A \
  "$source_fixture/$relative_evidence/.resume-runtime/Framework/Versions/Current"
resolved_evidence="$(r1_resolve_evidence_directory \
  "$source_fixture" "$relative_evidence")" ||
  fail "a relative in-repository evidence path was not resolved"
canonical_source_fixture="$(cd "$source_fixture" && /bin/pwd -P)"
[[ "$resolved_evidence" == "$canonical_source_fixture/$relative_evidence" ]] ||
  fail "relative evidence did not resolve to its canonical absolute path"
r1_capture_source_identity "$canonical_source_fixture" "$resolved_evidence" \
  "$fixture_root/source-with-evidence.json" \
  "$fixture_root/source-with-evidence-identity.json" ||
  fail "active evidence symlinks leaked into the source closure"
/usr/bin/cmp -s \
  "$fixture_root/source-clean-identity.json" \
  "$fixture_root/source-with-evidence-identity.json" ||
  fail "active relative evidence changed the source identity"
/bin/mv "$resolved_evidence" "$fixture_root/resolved-evidence-checked"
/usr/bin/printf 'untracked version one\n' >"$source_fixture/untracked-input.swift"
r1_capture_source_identity "$source_fixture" "$fixture_root/source-evidence" \
  "$fixture_root/source-untracked-one.json" "$fixture_root/source-untracked-one-identity.json"
[[ "$(/usr/bin/jq -r '.dirtyPathCount' "$fixture_root/source-untracked-one-identity.json")" == 1 ]] ||
  fail "source identity did not count an untracked nonignored input"
clean_source_hash="$(/usr/bin/jq -r '.diffSHA256' "$fixture_root/source-clean-identity.json")"
untracked_source_hash="$(/usr/bin/jq -r '.diffSHA256' "$fixture_root/source-untracked-one-identity.json")"
[[ "$clean_source_hash" != "$untracked_source_hash" ]] ||
  fail "source identity did not bind the untracked input path and content"
/usr/bin/printf 'untracked version two\n' >"$source_fixture/untracked-input.swift"
r1_capture_source_identity "$source_fixture" "$fixture_root/source-evidence" \
  "$fixture_root/source-untracked-two.json" "$fixture_root/source-untracked-two-identity.json"
[[ "$untracked_source_hash" != "$(/usr/bin/jq -r '.diffSHA256' "$fixture_root/source-untracked-two-identity.json")" ]] ||
  fail "source identity did not change when untracked input content changed"
expect_fail "a changed source closure" r1_assert_source_identity_unchanged \
  "$source_fixture" "$fixture_root/source-evidence" \
  "$fixture_root/source-untracked-one-identity.json" \
  "$fixture_root/source-check-snapshot.json" \
  "$fixture_root/source-check-identity.json" unit
source_failure="$fixture_root/source-evidence/source-status-failure-unit.json"
[[ -f "$source_failure" && ! -L "$source_failure" ]] ||
  fail "source mismatch did not preserve its exact diagnostic snapshot"
grep -Fq 'untracked-input.swift' "$source_failure" ||
  fail "source mismatch diagnostic omitted the changed path"

runtime_source="$fixture_root/runtime-source"
runtime_framework="$runtime_source/IdleScreenRenderer.framework/Versions/A"
runtime_capsule="$fixture_root/runtime-capsule"
/bin/mkdir -p "$runtime_framework/Resources"
/usr/bin/printf '#!/bin/bash\nexit 0\n' >"$runtime_source/idlescreen-perf"
/bin/chmod +x "$runtime_source/idlescreen-perf"
/usr/bin/printf 'renderer-binary\n' >"$runtime_framework/IdleScreenRenderer"
/usr/bin/printf 'renderer-plist\n' >"$runtime_framework/Resources/Info.plist"
/usr/bin/printf 'renderer-metallib\n' >"$runtime_framework/Resources/default.metallib"
runtime_manifest="$fixture_root/runtime-manifest.txt"
r1_write_artifact_manifest \
  "$runtime_source/idlescreen-perf" "$runtime_framework" "$runtime_manifest"
r1_install_resume_runtime \
  "$runtime_source/idlescreen-perf" "$runtime_framework" "$runtime_capsule" ||
  fail "a new exact resume runtime was not preserved"
resolved_runtime="$(r1_validate_resume_runtime "$runtime_capsule" "$runtime_manifest")" ||
  fail "the preserved exact resume runtime was rejected"
resolved_binary="${resolved_runtime%%$'\t'*}"
resolved_framework="${resolved_runtime#*$'\t'}"
[[ "$resolved_binary" == "$runtime_capsule/idlescreen-perf" ]] ||
  fail "resume selected the wrong performance executable"
[[ "$resolved_framework" == "$runtime_capsule/IdleScreenRenderer.framework/Versions/A" ]] ||
  fail "resume selected the wrong renderer framework"
/usr/bin/printf 'different rebuild bytes\n' >"$runtime_source/idlescreen-perf"
r1_validate_resume_runtime "$runtime_capsule" "$runtime_manifest" >/dev/null ||
  fail "a later non-reproducible rebuild invalidated the preserved runtime"
/usr/bin/printf 'tampered capsule\n' >>"$runtime_capsule/idlescreen-perf"
expect_fail "a tampered preserved resume runtime" \
  r1_validate_resume_runtime "$runtime_capsule" "$runtime_manifest"

grep -Fq -- '--drawable-width "$pixel_width"' "$runner" ||
  fail "runner does not pass the physical drawable width to the Swift CLI"
grep -Fq -- '--drawable-height "$pixel_height"' "$runner" ||
  fail "runner does not pass the physical drawable height to the Swift CLI"
grep -Fq 'preflight-manifest.json' "$runner" ||
  fail "runner does not preserve an immutable preflight manifest"
grep -Fq 'evidence-manifest.json' "$runner" ||
  fail "runner does not finalize a canonical evidence manifest"

echo "PASS: R1.1 runner enforces gating/smoke policy and immutable resume identity."
echo "PASS: preflight and raw-evidence manifests are canonical, complete, and fail closed."
echo "PASS: helper identity remains exact across its sampled window and reports stay derived."
