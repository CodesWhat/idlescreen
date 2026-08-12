#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
project_file="$project_root/project.yml"

scheme_block="$({
  awk '
    /^schemes:$/ { in_schemes = 1; next }
    in_schemes && /^targets:$/ { exit }
    in_schemes { print }
  ' "$project_file"
})"

for test_target in IdleScreenAgentTests IdleScreenCoreTests IdleScreenDisplayTests IdleScreenRendererTests IdleScreenPerformanceTests IdleScreenCameraTests IdleScreenCameraAgentTests IdleScreenSyntheticGateTests IdleScreenSystemTests IdleScreenScreenSaverTests IdleScreenAppCameraTests IdleScreenAppCompileGateTests; do
  if ! grep -Fq "$test_target: [test]" <<<"$scheme_block" ||
     ! grep -Fq -- "- $test_target" <<<"$scheme_block"; then
    echo "FAIL: generated modern schemes must attach $test_target to the Test action." >&2
    exit 1
  fi
done

echo "PASS: modern agent, Core, display, renderer, performance, camera, companion, system, and screen saver schemes expose repeatable Test actions."

camera_agent_test_scheme="$({
  awk '
    /^  IdleScreenCameraAgent:$/ { in_scheme = 1 }
    in_scheme && /^  [[:alnum:]_]+:$/ && $0 != "  IdleScreenCameraAgent:" { exit }
    in_scheme { print }
  ' "$project_file"
})"
screen_saver_test_scheme="$({
  awk '
    /^  IdleScreenScreenSaver:$/ { in_scheme = 1 }
    in_scheme && /^  [[:alnum:]_]+:$/ && $0 != "  IdleScreenScreenSaver:" { exit }
    in_scheme { print }
  ' "$project_file"
})"
if grep -Fq 'IdleScreenCameraAgent: all' <<<"$camera_agent_test_scheme" ||
   ! grep -Fq 'IdleScreenCameraAgentCore: all' <<<"$camera_agent_test_scheme" ||
   grep -Fq 'IdleScreenScreenSaver: all' <<<"$screen_saver_test_scheme"; then
  echo "FAIL: local unit-test schemes must not build GUI/helper or extension products." >&2
  exit 1
fi

echo "PASS: local camera-agent and saver unit-test schemes compile source-only test graphs without GUI/product registration."

companion_compile_gate="$project_root/scripts/test-companion-compile-gate.sh"
ci_workflow="$project_root/.github/workflows/ci.yml"
companion_ci_invocation_count="$(grep -Fc './scripts/test-companion-compile-gate.sh' "$ci_workflow" || true)"
ci_modern_test_block="$({
  awk '
    /- name: Run modern unit and integration tests/ { in_step = 1 }
    in_step && /- name:/ && !/- name: Run modern unit and integration tests/ { exit }
    in_step { print }
  ' "$ci_workflow"
})"
if ! grep -Fq 'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES' "$companion_compile_gate" ||
   [[ "$companion_ci_invocation_count" -ne 1 ]] ||
   grep -Fq 'IdleScreenAppCompileGate \' <<<"$ci_modern_test_block"; then
  echo "FAIL: CI must run the warnings-as-errors companion safety wrapper exactly once, outside the generic scheme loop." >&2
  exit 1
fi

echo "PASS: CI runs the companion compile safety wrapper once with warnings as errors."

if ! grep -Fq 'result_root="$RUNNER_TEMP/idlescreen-test-results"' <<<"$ci_modern_test_block" ||
   ! grep -Fq -- '-resultBundlePath "$result_bundle"' <<<"$ci_modern_test_block" ||
   ! grep -Fq 'xcrun xcresulttool get test-results summary --path "$result_bundle"' <<<"$ci_modern_test_block" ||
   ! grep -Fq 'xcrun xcresulttool get test-results tests --path "$result_bundle"' <<<"$ci_modern_test_block"; then
  echo "FAIL: CI must preserve and print actionable Xcode test diagnostics for every modern scheme." >&2
  exit 1
fi

echo "PASS: CI preserves and prints actionable Xcode test diagnostics for every modern scheme."

checkout_sha='11d5960a326750d5838078e36cf38b85af677262'
qlty_coverage_sha='ea1eaf434a27bf50cd544153084fbb11c52aaf84'
ci_coverage_block="$(sed -n '/^  coverage:$/,$p' "$ci_workflow")"
if [[ "$(grep -Fc "uses: actions/checkout@$checkout_sha" "$ci_workflow" || true)" -ne 2 ]] ||
   [[ "$(grep -Fc 'persist-credentials: false' "$ci_workflow" || true)" -ne 2 ]] ||
   ! grep -Fq 'permissions:' "$ci_workflow" ||
   ! grep -Fq 'contents: read' "$ci_workflow" ||
   ! grep -Fq 'id-token: write' "$ci_workflow" ||
   ! grep -Fq "uses: qltysh/qlty-action/coverage@$qlty_coverage_sha" "$ci_workflow" ||
   ! grep -Fq "if: github.event_name == 'push'" "$ci_workflow" ||
   ! grep -Fq -- '-enableCodeCoverage YES' "$ci_workflow" ||
   ! grep -Fq -- '-resultBundlePath "$result_bundle"' "$ci_workflow" ||
   ! grep -Fq 'xcrun xccov view --archive --json "$result_bundle"' "$ci_workflow" ||
   ! grep -Fq 'oidc: true' "$ci_workflow" ||
   ! grep -Fq 'format: xccov-json' "$ci_workflow" ||
   ! grep -Fq 'skip-errors: false' "$ci_workflow" ||
   ! grep -Fq 'validate: true' "$ci_workflow" ||
   ! grep -Fq 'cli-version: 0.618.0' "$ci_workflow" ||
   ! grep -Fq 'IdleScreenAppCompileGate; do' <<<"$ci_coverage_block" ||
   grep -Eq '^[[:space:]]+token:' <<<"$ci_coverage_block" ||
   grep -Fq 'QLTY_COVERAGE_TOKEN' "$ci_workflow" ||
   grep -Eq 'uses: [^[:space:]]+@v[0-9]' "$ci_workflow"; then
  echo "FAIL: CI must pin actions, discard checkout credentials, minimize permissions, and upload trusted-push Xcode coverage through Qlty OIDC." >&2
  exit 1
fi

while IFS= read -r action_ref; do
  if [[ "$action_ref" == ./* ]]; then
    continue
  fi
  if [[ ! "$action_ref" =~ ^[^@[:space:]]+@[0-9a-f]{40}$ ]]; then
    echo "FAIL: every external GitHub Action reference must use a full lowercase commit SHA: $action_ref" >&2
    exit 1
  fi
done < <(awk '/uses:/ { print $2 }' "$ci_workflow")

if [[ "$(grep -Ec '^[[:space:]]+id-token: write$' "$ci_workflow" || true)" -ne 1 ]] ||
   grep -Eq '^[[:space:]]+(actions|attestations|checks|deployments|discussions|issues|models|packages|pages|pull-requests|security-events|statuses): write$' "$ci_workflow" ||
   grep -Eq 'permissions:[[:space:]]+(read-all|write-all)' "$ci_workflow"; then
  echo "FAIL: CI may grant write permission only to one coverage-job OIDC token." >&2
  exit 1
fi

echo "PASS: CI actions are pinned and the trusted-push Qlty coverage job uses least-privilege OIDC without a stored token."

qlty_config="$project_root/.qlty/qlty.toml"
if ! grep -Fq '[coverage]' "$qlty_config" ||
   ! grep -Fq '"**/*Tests/**"' "$qlty_config" ||
   ! grep -Fq '"IdleScreenCoreTestSupport/**"' "$qlty_config"; then
  echo "FAIL: Qlty coverage must report production code without test or test-support inflation." >&2
  exit 1
fi

echo "PASS: Qlty coverage excludes test and test-support sources from production coverage metrics."

if ! grep -Fq '"RendererFrame"' "$project_root/IdleScreenRenderer/IdleScreenRenderer.swift" ||
   ! grep -Fq '"MailboxPublish"' "$project_root/IdleScreenCameraAgent/CameraFrameMailboxWriter.swift" ||
   ! grep -Fq '"MailboxRead"' "$project_root/IdleScreenCamera/CameraFrameMapping.swift" ||
   ! grep -Fq '"AgentSignalPoll"' "$project_root/IdleScreenCore/AgentSignalMonitor.swift"; then
  echo "FAIL: R1.1 requires privacy-minimal signposts at renderer, mailbox, and AgentSignal boundaries." >&2
  exit 1
fi

echo "PASS: R1.1 renderer, transport, and polling boundaries expose privacy-minimal signposts."

r1_runner="$project_root/scripts/run-performance-r1.sh"
r1_runner_fixture="$project_root/scripts/test-run-performance-r1.sh"
performance_contract="$project_root/IdleScreenPerformance/PerformanceContract.swift"
performance_contract_tests="$project_root/IdleScreenPerformanceTests/PerformanceContractTests.swift"
performance_report="$project_root/scripts/performance_r1_report.py"
performance_report_tests="$project_root/scripts/test_performance_r1_report.py"
if [[ ! -x "$r1_runner" ]] ||
   [[ ! -x "$r1_runner_fixture" ]] ||
   ! grep -Fq 'IDLESCREEN_PERF_DURATION_SECONDS:-900' "$r1_runner" ||
   ! grep -Fq 'CODE_SIGNING_ALLOWED=NO' "$r1_runner" ||
   ! grep -Fq 'performance_r1_report.py' "$r1_runner" ||
   ! grep -Fq "Now drawing from 'AC Power'" "$r1_runner" ||
   ! grep -Fq 'caffeinate -di -w $$' "$r1_runner" ||
   ! grep -Fq './scripts/test-run-performance-r1.sh' "$ci_workflow" ||
   ! grep -Fq 'python3 ./scripts/test_performance_r1_report.py' "$ci_workflow" ||
   grep -Eq '(launchctl (kickstart|bootout)|pluginkit|killall|open -a|register|activate)' "$r1_runner"; then
  echo "FAIL: R1.1 must use a 15-minute, AC-powered, sleep-fenced, unsigned, state-safe measurement runner." >&2
  exit 1
fi

echo "PASS: R1.1 has a 15-minute AC-powered, sleep-fenced, unsigned measurement runner that cannot mutate installed lifecycle state."

if ! grep -Fq 'm4-pro-4112x2658-single-display-r1.1-v2-render-capacity' "$performance_contract" ||
   ! grep -Fq '.attemptDurationP95Milliseconds' "$performance_contract" ||
   ! grep -Fq 'limit.metric == .frameIntervalP95Milliseconds' "$performance_contract_tests" ||
   ! grep -Fq 'slowSubmissionWithSlowAttemptStartCount' "$performance_report" ||
   ! grep -Fq 'test_adjacent_submission_interval_is_diagnostic_not_gating' "$performance_report_tests"; then
  echo "FAIL: R1.1 v2 must gate render-attempt capacity while retaining correlated wake/submission cadence as non-gating telemetry." >&2
  exit 1
fi

echo "PASS: R1.1 v2 gates render-attempt capacity and preserves adjacent-submission cadence as correlated diagnostic telemetry."

agent_target_block="$({
  awk '
    /^targets:$/ { in_targets = 1; next }
    in_targets && /^  IdleScreenAgent:$/ { in_agent = 1; next }
    in_agent && /^  [[:alnum:]_]+:$/ { exit }
    in_agent { print }
  ' "$project_file"
})"
control_tool_target_block="$({
  awk '
    /^targets:$/ { in_targets = 1; next }
    in_targets && /^  IdleScreenCtl:$/ { in_tool = 1; next }
    in_tool && /^  [[:alnum:]_]+:$/ { exit }
    in_tool { print }
  ' "$project_file"
})"
control_tool_entitlements="$project_root/IdleScreenAgentExecutable/idlescreenctl.entitlements"
control_tool_developer_id_entitlements="$project_root/IdleScreenAgentExecutable/idlescreenctl-DeveloperID.entitlements"
control_tool_source="$project_root/IdleScreenAgentExecutable/main.swift"
control_tool_runtime_test="$project_root/scripts/test-idlescreenctl-runtime.sh"

if [[ -z "$agent_target_block" || -z "$control_tool_target_block" ]] ||
   ! grep -Fq 'type: framework.static' <<<"$agent_target_block" ||
   ! grep -Fq 'path: IdleScreenAgent' <<<"$agent_target_block" ||
   ! grep -Fq 'target: IdleScreenCore' <<<"$agent_target_block" ||
   ! grep -Fq 'type: tool' <<<"$control_tool_target_block" ||
   ! grep -Fq 'PRODUCT_NAME: idlescreenctl' <<<"$control_tool_target_block" ||
   ! grep -Fq 'OTHER_CODE_SIGN_FLAGS: "--identifier com.idlescreen.ctl"' <<<"$control_tool_target_block" ||
   ! grep -Fq 'ENABLE_APP_SANDBOX: YES' <<<"$control_tool_target_block" ||
   ! grep -Fq 'REGISTER_APP_GROUPS: YES' <<<"$control_tool_target_block" ||
   [[ ! -x "$control_tool_runtime_test" ]] ||
   ! grep -Fq '#if DEBUG && IDLESCREEN_CTL_SCRATCH_GATE' "$control_tool_source" ||
   ! grep -Fq 'group.com.idlescreen.tests.scratch' "$control_tool_source" ||
   ! grep -Fq 'IDLESCREEN_CTL_SCRATCH_ROOT' "$control_tool_source" ||
   grep -Fq -- '--root' "$control_tool_source" ||
   [[ "$(grep -Fc './scripts/test-idlescreenctl-runtime.sh' "$ci_workflow")" -ne 1 ]] ||
   ! grep -Fq 'configuration Release' "$control_tool_runtime_test" ||
   ! grep -Fq "strings \"\$release_control_tool\"" "$control_tool_runtime_test" ||
   ! grep -Fq 'path: IdleScreenCoreTestSupport' "$project_file" ||
   [[ "$(grep -Fc 'target: IdleScreenCoreStoreTestWorker' "$project_file")" -ne 1 ]] ||
   ! grep -Fq 'link: false' "$project_file" ||
   [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$control_tool_entitlements" 2>/dev/null || true)" != true ]] ||
   [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$control_tool_entitlements" 2>/dev/null || true)" != 3524374A2S ]] ||
   [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$control_tool_entitlements" 2>/dev/null || true)" != 3524374A2S.com.idlescreen.ctl ]] ||
   [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$control_tool_entitlements" 2>/dev/null || true)" != group.com.idlescreen.shared ]] ||
   [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$control_tool_developer_id_entitlements" 2>/dev/null || true)" != 3524374A2S ]] ||
   [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$control_tool_developer_id_entitlements" 2>/dev/null || true)" != 3524374A2S.com.idlescreen.ctl ]] ||
   /usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.camera' "$control_tool_entitlements" >/dev/null 2>&1 ||
   grep -RqsE '(transcript_path|tool_input|tool_output|last_assistant_message|permission_suggestions|credential)' "$project_root/IdleScreenAgent" ||
   ! grep -Fq 'target: IdleScreenCtl' "$project_file" ||
   ! grep -Fq 'subpath: Contents/Helpers' "$project_file" ||
   ! grep -Fq 'IdleScreenAgentSignalMonitor' "$project_root/IdleScreenScreenSaver/IdleScreenSaverView.swift" ||
   ! grep -Fq 'IntegrationsView()' "$project_root/IdleScreenApp/IdleScreenStudio.swift" ||
   ! grep -Fq 'IdleScreenAgent' "$project_root/.github/workflows/ci.yml"; then
  echo "FAIL: P3 requires tested privacy-minimal adapters, a release-inaccessible scratch-tested App Group control tool, explicit companion controls, and saver monitoring." >&2
  exit 1
fi

echo "PASS: P3 AgentSignal ingress is sandboxed, privacy-minimal, explicitly configured, scratch-runtime tested behind a Debug compile gate, embedded in both products, and covered by deterministic tests."

camera_target_block="$({
  awk '
    /^targets:$/ { in_targets = 1; next }
    in_targets && /^  IdleScreenCamera:$/ { in_camera = 1; next }
    in_camera && /^  [[:alnum:]_]+:$/ { exit }
    in_camera { print }
  ' "$project_file"
})"

if [[ -z "$camera_target_block" ]] ||
   ! grep -Fq 'type: framework.static' <<<"$camera_target_block" ||
   ! grep -Fq 'path: IdleScreenCamera' <<<"$camera_target_block" ||
   grep -RqsE '(import AVFoundation|AVCapture(Session|Device|Output))' "$project_root/IdleScreenCamera"; then
  echo "FAIL: deterministic camera contracts must live in an isolated camera-free static framework." >&2
  exit 1
fi

echo "PASS: camera lease, frame, and reconnect contracts are isolated from AVFoundation."

camera_agent_target_block="$({
  awk '
    /^targets:$/ { in_targets = 1; next }
    in_targets && /^  IdleScreenCameraAgent:$/ { in_agent = 1; next }
    in_agent && /^  [[:alnum:]_]+:$/ { exit }
    in_agent { print }
  ' "$project_file"
})"

camera_agent_core_target_block="$({
  awk '
    /^  IdleScreenCameraAgentCore:$/ { in_agent_core = 1; next }
    in_agent_core && /^  [[:alnum:]_]+:$/ { exit }
    in_agent_core { print }
  ' "$project_file"
})"

camera_agent_tests_target_block="$({
  awk '
    /^  IdleScreenCameraAgentTests:$/ { in_agent_tests = 1; next }
    in_agent_tests && /^  [[:alnum:]_]+:$/ { exit }
    in_agent_tests { print }
  ' "$project_file"
})"

if [[ -z "$camera_agent_target_block" ]] ||
   ! grep -Fq 'type: application' <<<"$camera_agent_target_block" ||
   ! grep -Fq 'path: IdleScreenCameraAgentExecutable' <<<"$camera_agent_target_block" ||
   ! grep -Fq 'target: IdleScreenCameraAgentCore' <<<"$camera_agent_target_block" ||
   ! grep -Fq 'LSBackgroundOnly: true' <<<"$camera_agent_target_block" ||
   ! grep -Fq 'LSUIElement: true' <<<"$camera_agent_target_block" ||
   ! grep -Fq 'NSCameraUsageDescription' <<<"$camera_agent_target_block" ||
   ! grep -Fq 'NSCameraUseContinuityCameraDeviceType: true' <<<"$camera_agent_target_block" ||
   ! grep -Fq 'CODE_SIGN_ENTITLEMENTS: IdleScreenCameraAgent/IdleScreenCameraAgent.entitlements' <<<"$camera_agent_target_block" ||
   ! grep -Fq 'REGISTER_APP_GROUPS: YES' <<<"$camera_agent_target_block" ||
   ! grep -Fq 'type: framework.static' <<<"$camera_agent_core_target_block" ||
   ! grep -Fq 'path: IdleScreenCameraAgent' <<<"$camera_agent_core_target_block" ||
   ! grep -Fq 'target: IdleScreenCamera' <<<"$camera_agent_core_target_block" ||
   ! grep -Fq 'sdk: AVFoundation.framework' <<<"$camera_agent_core_target_block" ||
   ! grep -Fq 'target: IdleScreenCameraAgentCore' <<<"$camera_agent_tests_target_block"; then
  echo "FAIL: the camera owner must be a separately provisioned, GUI-less app bundle with a tested AVFoundation core." >&2
  exit 1
fi

for static_dependency in IdleScreenCameraAgentCore IdleScreenCamera IdleScreenCameraAtomics; do
  if ! grep -Fq -- $'- target: '"$static_dependency"$'\n        embed: false' \
    <<<"$camera_agent_target_block"; then
    echo "FAIL: the camera-agent app must link, but never embed, static dependency $static_dependency." >&2
    exit 1
  fi
done

if [[ "$(/usr/bin/plutil -extract NSCameraUseContinuityCameraDeviceType raw "$project_root/IdleScreenCameraAgentExecutable/Info.plist" 2>/dev/null || true)" != "true" ]]; then
  echo "FAIL: the camera agent must opt into distinct Continuity Camera device classification." >&2
  exit 1
fi

if grep -Fq 'CREATE_INFOPLIST_SECTION_IN_BINARY: YES' <<<"$camera_agent_target_block"; then
  echo "FAIL: the app-wrapped camera agent must use its bundle Info.plist, not a bare executable Info section." >&2
  exit 1
fi

echo "PASS: the camera owner is a separately provisioned, GUI-less app bundle with a tested AVFoundation core."

release_agent_plist="$project_root/IdleScreenCameraAgent/LaunchAgents/group.com.idlescreen.shared.camera-agent.plist"
debug_agent_plist="$project_root/IdleScreenCameraAgent/LaunchAgents/group.com.idlescreen.dev.shared.camera-agent.plist"
release_agent_entitlements="$project_root/IdleScreenCameraAgent/IdleScreenCameraAgent.entitlements"

for agent_plist in "$release_agent_plist" "$debug_agent_plist"; do
  if [[ ! -f "$agent_plist" ]] ||
     [[ "$(/usr/libexec/PlistBuddy -c 'Print :BundleProgram' "$agent_plist" 2>/dev/null || true)" != "Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent" ]] ||
     [[ "$(/usr/libexec/PlistBuddy -c 'Print :ProcessType' "$agent_plist" 2>/dev/null || true)" != "Interactive" ]]; then
    echo "FAIL: each camera LaunchAgent plist must run the embedded helper with an explicit process type." >&2
    exit 1
  fi
done

if [[ "$(/usr/libexec/PlistBuddy -c 'Print :AssociatedBundleIdentifiers' "$release_agent_plist" 2>/dev/null || true)" != "com.idlescreen.app" ]] ||
   [[ "$(/usr/libexec/PlistBuddy -c 'Print :AssociatedBundleIdentifiers' "$debug_agent_plist" 2>/dev/null || true)" != "com.idlescreen.app.dev" ]]; then
  echo "FAIL: each LaunchAgent must carry its configuration-matched associated companion identity for TCC attribution." >&2
  exit 1
fi

if [[ "$(/usr/libexec/PlistBuddy -c 'Print :MachServices:group.com.idlescreen.shared.camera-agent' "$release_agent_plist" 2>/dev/null || true)" != "true" ]] ||
   [[ "$(/usr/libexec/PlistBuddy -c 'Print :MachServices:group.com.idlescreen.dev.shared.camera-agent' "$debug_agent_plist" 2>/dev/null || true)" != "true" ]]; then
  echo "FAIL: camera agent Mach services must be immediate children of their App Group identifiers." >&2
  exit 1
fi

if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$release_agent_entitlements" 2>/dev/null || true)" != "true" ]] ||
   [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.camera' "$release_agent_entitlements" 2>/dev/null || true)" != "true" ]] ||
   [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$release_agent_entitlements" 2>/dev/null || true)" != '$(IDLESCREEN_APP_GROUP_IDENTIFIER)' ]]; then
  echo "FAIL: only the signed camera agent may own sandboxed camera and shared-container access." >&2
  exit 1
fi

companion_target_block="$({
  awk '
    /^  IdleScreenApp:$/ { in_companion = 1; next }
    in_companion && /^  [[:alnum:]_]+:$/ { exit }
    in_companion { print }
  ' "$project_file"
})"

if [[ -z "$companion_target_block" ]]; then
  echo "FAIL: project.yml must define the new IdleScreenApp companion target." >&2
  exit 1
fi

if ! grep -Fq 'type: application' <<<"$companion_target_block"; then
  echo "FAIL: IdleScreenApp must be a macOS application target." >&2
  exit 1
fi

if ! grep -Fq 'path: IdleScreenApp' <<<"$companion_target_block"; then
  echo "FAIL: IdleScreenApp must own sources in the isolated IdleScreenApp directory." >&2
  exit 1
fi

echo "PASS: IdleScreenApp is an isolated companion application target."

companion_camera_tests_target_block="$({
  awk '
    /^  IdleScreenAppCameraTests:$/ { in_tests = 1; next }
    in_tests && /^  [[:alnum:]_]+:$/ { exit }
    in_tests { print }
  ' "$project_file"
})"

if ! grep -Fq 'path: IdleScreenApp/IdleScreenCompanionCameraClient.swift' <<<"$companion_camera_tests_target_block" ||
   ! grep -Fq 'path: IdleScreenAppCameraTests' <<<"$companion_camera_tests_target_block" ||
   ! grep -Fq 'target: IdleScreenCamera' <<<"$companion_camera_tests_target_block"; then
  echo "FAIL: the companion camera lifecycle must have a narrow deterministic test target." >&2
  exit 1
fi

echo "PASS: the companion camera lifecycle has a narrow deterministic test target."

companion_compile_gate_target_block="$({
  awk '
    /^  IdleScreenAppCompileGateTests:$/ { in_compile_gate = 1; next }
    in_compile_gate && /^  [[:alnum:]_]+:$/ { exit }
    in_compile_gate { print }
  ' "$project_file"
})"

if [[ -z "$companion_compile_gate_target_block" ]] ||
   ! grep -Fq 'type: bundle.unit-test' <<<"$companion_compile_gate_target_block" ||
   ! grep -Fq 'path: IdleScreenApp' <<<"$companion_compile_gate_target_block" ||
   ! grep -Fq -- '- "**/*.swift"' <<<"$companion_compile_gate_target_block" ||
   ! grep -Fq -- '- "Info.plist"' <<<"$companion_compile_gate_target_block" ||
   ! grep -Fq 'path: IdleScreenAppCompileGateTests' <<<"$companion_compile_gate_target_block" ||
   ! grep -Fq 'IDLESCREEN_APP_COMPILE_GATE' <<<"$companion_compile_gate_target_block" ||
   ! grep -Fq 'INFOPLIST_FILE: ""' <<<"$companion_compile_gate_target_block" ||
   ! grep -Fq 'SWIFT_TREAT_WARNINGS_AS_ERRORS: YES' <<<"$companion_compile_gate_target_block" ||
   ! grep -Fq 'target: IdleScreenCore' <<<"$companion_compile_gate_target_block" ||
   ! grep -Fq 'target: IdleScreenCamera' <<<"$companion_compile_gate_target_block" ||
   ! grep -Fq 'target: IdleScreenSystem' <<<"$companion_compile_gate_target_block" ||
   grep -Fq 'target: IdleScreenApp' <<<"$companion_compile_gate_target_block" ||
   grep -Fq 'target: IdleScreenScreenSaver' <<<"$companion_compile_gate_target_block" ||
   grep -Fq 'target: IdleScreenCameraAgent' <<<"$companion_compile_gate_target_block" ||
   grep -Fq 'CODE_SIGN_ENTITLEMENTS' <<<"$companion_compile_gate_target_block" ||
   ! grep -Fq '#if !IDLESCREEN_APP_COMPILE_GATE' "$project_root/IdleScreenApp/IdleScreenStudio.swift"; then
  echo "FAIL: the companion compile gate must compile every companion Swift source in an isolated non-app test bundle." >&2
  exit 1
fi

echo "PASS: every companion Swift source has a non-app compile-and-smoke-test gate."

companion_compile_gate_runner="$project_root/scripts/test-companion-compile-gate.sh"
phase1_runner="$project_root/scripts/test-phase1.sh"
if [[ ! -x "$companion_compile_gate_runner" ]] ||
   ! grep -Fq 'xcodebuild test' "$companion_compile_gate_runner" ||
   ! grep -Fq -- '-scheme IdleScreenAppCompileGate' "$companion_compile_gate_runner" ||
   ! grep -Fq 'RegisterWithLaunchServices' "$companion_compile_gate_runner" ||
   ! grep -Fq 'lsregister' "$companion_compile_gate_runner" ||
   ! grep -Fq 'Test run with [1-9][0-9]* tests?' "$companion_compile_gate_runner" ||
   grep -Fq 'xcodebuild build' "$companion_compile_gate_runner" ||
   ! grep -Fq './scripts/test-companion-compile-gate.sh "$artifact_root/CompanionCompileGate"' "$phase1_runner"; then
  echo "FAIL: the headless companion compile gate must scan its build log and run in Phase 1." >&2
  exit 1
fi

echo "PASS: Phase 1 invokes the headless companion compile gate and preserves its registration scan."

if ! grep -Fq 'path: IdleScreenCameraAgent/LaunchAgents' <<<"$companion_target_block" ||
   ! grep -Fq 'destination: wrapper' <<<"$companion_target_block" ||
   ! grep -Fq 'subpath: Contents/Library/LaunchAgents' <<<"$companion_target_block" ||
   ! grep -Fq 'target: IdleScreenCameraAgent' <<<"$companion_target_block" ||
   ! grep -Fq 'subpath: Contents/Helpers' <<<"$companion_target_block"; then
  echo "FAIL: the companion must embed the agent executable and configuration-specific LaunchAgent resources in Apple's bundle layout." >&2
  exit 1
fi

echo "PASS: camera-agent signing, App Group Mach service, and configuration-specific bundle layout match SMAppService."

if ! grep -Eq 'PRODUCT_BUNDLE_IDENTIFIER: com\.idlescreen\.app\.dev$' <<<"$companion_target_block" ||
   ! grep -Eq 'PRODUCT_BUNDLE_IDENTIFIER: com\.idlescreen\.app$' <<<"$companion_target_block" ||
   ! grep -Fq 'configs:' <<<"$companion_target_block"; then
  echo "FAIL: IdleScreenApp must use separate Debug and Release bundle identifiers." >&2
  exit 1
fi

if ! grep -Fq 'NSCameraUsageDescription' <<<"$companion_target_block"; then
  echo "FAIL: responsible-code camera consent requires purpose text in the containing companion." >&2
  exit 1
fi

if ! grep -Fq 'CODE_SIGN_ENTITLEMENTS: IdleScreenApp/IdleScreenApp.entitlements' <<<"$companion_target_block" ||
   ! grep -Fq 'CODE_SIGN_ENTITLEMENTS: IdleScreenApp/IdleScreenApp-Debug.entitlements' <<<"$companion_target_block" ||
   ! grep -Fq 'IDLESCREEN_APP_GROUP_IDENTIFIER: group.com.idlescreen.dev.shared' <<<"$companion_target_block" ||
   ! grep -Fq 'IDLESCREEN_APP_GROUP_IDENTIFIER: group.com.idlescreen.shared' <<<"$companion_target_block" ||
   ! grep -Fq 'IDLESCREEN_SHARED_CONTAINER_ENABLED: NO' <<<"$companion_target_block" ||
   ! grep -Fq 'IDLESCREEN_SHARED_CONTAINER_ENABLED: YES' <<<"$companion_target_block"; then
  echo "FAIL: IdleScreenApp must declare separate development and release shared containers." >&2
  exit 1
fi

echo "PASS: IdleScreenApp isolates development installs without requesting camera access."

companion_info="$project_root/IdleScreenApp/Info.plist"
for camera_info_tuple in \
  'IdleScreenCameraAgentAppGroupIdentifier:$(IDLESCREEN_APP_GROUP_IDENTIFIER)' \
  'IdleScreenCameraAgentMachServiceName:$(IDLESCREEN_CAMERA_AGENT_MACH_SERVICE_NAME)' \
  'IdleScreenCameraAgentTeamIdentifier:$(IDLESCREEN_CAMERA_AGENT_TEAM_IDENTIFIER)'; do
  camera_info_key="${camera_info_tuple%%:*}"
  camera_info_value="${camera_info_tuple#*:}"
  if [[ "$(plutil -extract "$camera_info_key" raw "$companion_info" 2>/dev/null || true)" != "$camera_info_value" ]] ||
     ! grep -Fq "$camera_info_key: $camera_info_value" <<<"$companion_target_block"; then
    echo "FAIL: IdleScreenApp must publish the exact camera client Info tuple ($camera_info_key)." >&2
    exit 1
  fi
done

if ! grep -Fq 'IDLESCREEN_CAMERA_AGENT_MACH_SERVICE_NAME: group.com.idlescreen.dev.shared.camera-agent' <<<"$companion_target_block" ||
   ! grep -Fq 'IDLESCREEN_CAMERA_AGENT_MACH_SERVICE_NAME: group.com.idlescreen.shared.camera-agent' <<<"$companion_target_block" ||
   ! grep -Fq 'target: IdleScreenCamera' <<<"$companion_target_block" ||
   ! awk '
      /^  IdleScreenApp:$/ { in_app = 1 }
      in_app && /^      - target: IdleScreenCamera$/ { found_camera = 1; next }
      found_camera && /^        embed: false$/ { found_no_embed = 1 }
      in_app && /^  [[:alnum:]_]+:$/ && $1 != "IdleScreenApp:" { exit }
      END { exit !(found_camera && found_no_embed) }
    ' "$project_file"; then
  echo "FAIL: IdleScreenApp must link the camera client with exact Debug and Release service identities." >&2
  exit 1
fi

for companion_entitlements in \
  "$project_root/IdleScreenApp/IdleScreenApp.entitlements" \
  "$project_root/IdleScreenApp/IdleScreenApp-Debug.entitlements"; do
  if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.camera' "$companion_entitlements" >/dev/null 2>&1; then
    echo "FAIL: IdleScreenApp must never carry the camera entitlement." >&2
    exit 1
  fi
done

camera_agent_info="$project_root/IdleScreenCameraAgentExecutable/Info.plist"
companion_camera_purpose="$(/usr/libexec/PlistBuddy -c 'Print :NSCameraUsageDescription' "$companion_info" 2>/dev/null || true)"
agent_camera_purpose="$(/usr/libexec/PlistBuddy -c 'Print :NSCameraUsageDescription' "$camera_agent_info" 2>/dev/null || true)"
if [[ -z "$companion_camera_purpose" ]] ||
   [[ "$companion_camera_purpose" != "$agent_camera_purpose" ]]; then
  echo "FAIL: the containing app and sole camera agent must publish identical camera purpose text." >&2
  exit 1
fi

echo "PASS: companion camera tuples and responsible-code purpose text are exact; only the agent owns camera entitlement."

companion_camera_lifecycle="$project_root/IdleScreenApp/IdleScreenCompanionCameraClient.swift"
companion_app_delegate="$project_root/IdleScreenApp/IdleScreenAppDelegate.swift"
companion_studio="$project_root/IdleScreenApp/IdleScreenStudio.swift"
companion_system_view="$project_root/IdleScreenApp/SystemViews.swift"
if [[ "$(grep -Fc 'CameraClientBootstrap.makeRuntime(' "$companion_app_delegate")" != "1" ]] ||
   ! grep -Fq 'private lazy var cameraClient' "$companion_app_delegate" ||
   ! grep -Fq 'cameraPageDidAppear()' "$companion_studio" ||
   ! grep -Fq 'cameraPageDidDisappear()' "$companion_studio" ||
   ! grep -Fq 'window.delegate = self' "$companion_app_delegate" ||
   ! grep -Fq 'mainWindowWillClose()' "$companion_app_delegate" ||
   ! grep -Fq 'mainWindowDidOpen()' "$companion_app_delegate"; then
  echo "FAIL: companion camera demand must use one bootstrap, page lifecycle, and explicit window-close teardown." >&2
  exit 1
fi

if grep -Eqs '(import AVFoundation|AVCapture|SMAppService|AVCaptureDevice\.requestAccess|openCameraSettings)' \
  "$companion_camera_lifecycle"; then
  echo "FAIL: companion camera bootstrap must remain inert and permission-free." >&2
  exit 1
fi

echo "PASS: companion preview demand is visibility-scoped and explicit window close is fail-safe."

if grep -Fq 'Added only if direct capture fails' "$companion_system_view" ||
   grep -Fq 'Added only if direct capture fails' "$companion_studio" ||
   ! grep -Fq 'The current camera agent reports authorization' "$companion_system_view"; then
  echo "FAIL: companion status copy must attribute authorization to verified live evidence." >&2
  exit 1
fi

echo "PASS: companion health copy attributes authorization to verified live evidence."

if [[ "$(plutil -extract CFBundleDisplayName raw "$project_root/IdleScreenApp/Info.plist" 2>/dev/null || true)" != "idlescreen" ]] ||
   [[ "$(plutil -extract CFBundleName raw "$project_root/IdleScreenApp/Info.plist")" != "idlescreen" ]] ||
   [[ "$(plutil -extract CFBundleDisplayName raw "$project_root/IdleScreenScreenSaver/Info.plist")" != "idlescreen" ]]; then
  echo "FAIL: every user-visible modern product name must be lowercase idlescreen." >&2
  exit 1
fi

for forbidden_brand in \
  'Start IdleScreen' \
  'Open IdleScreen' \
  'Quit IdleScreen' \
  'Select IdleScreen' \
  'IdleScreen.app' \
  'IDLESCREEN  /'; do
  if grep -RqsF "$forbidden_brand" \
    "$project_root/IdleScreenApp" \
    "$project_root/IdleScreenScreenSaver/IdleScreenSaverView.swift"; then
    echo "FAIL: user-facing modern copy contains non-lowercase brand '$forbidden_brand'." >&2
    exit 1
  fi
done

echo "PASS: modern app, screen saver tile, and UI copy use lowercase idlescreen branding."

if ! grep -Fq '@NSApplicationDelegateAdaptor(IdleScreenAppDelegate.self)' "$project_root/IdleScreenApp/IdleScreenStudio.swift" ||
   ! grep -Fq 'NSHostingController' "$project_root/IdleScreenApp/IdleScreenAppDelegate.swift" ||
   ! grep -Fq 'showMainWindow()' "$project_root/IdleScreenApp/IdleScreenAppDelegate.swift" ||
   ! grep -Fq 'makeKeyAndOrderFront' "$project_root/IdleScreenApp/IdleScreenAppDelegate.swift" ||
   grep -Fq 'WindowGroup(' "$project_root/IdleScreenApp/IdleScreenStudio.swift"; then
  echo "FAIL: The menu-bar resident app must explicitly reveal its main window after launch." >&2
  exit 1
fi

echo "PASS: IdleScreenApp presents a visible main window on launch."

companion_launch_policy_test="$project_root/scripts/test-companion-launch-policy.sh"
if ! grep -Fq -- '--idlescreen-lifecycle-probe=' "$project_root/IdleScreenApp/IdleScreenLaunchPolicy.swift" ||
   ! grep -Fq 'IdleScreenLaunchPolicy.shouldShowMainWindow' "$project_root/IdleScreenApp/IdleScreenAppDelegate.swift" ||
   ! grep -Fq 'ProcessInfo.processInfo.arguments' "$project_root/IdleScreenApp/IdleScreenAppDelegate.swift" ||
   [[ ! -x "$companion_launch_policy_test" ]] ||
   ! grep -Fq 'test-companion-launch-policy.sh' "$project_root/scripts/test-phase1.sh"; then
  echo "FAIL: background companion lifecycle probes must not activate or reveal the main window." >&2
  exit 1
fi

echo "PASS: automated companion lifecycle probes preserve user focus."

if ! grep -Fq -- '--idlescreen-configuration-probe-contrast=' "$project_root/IdleScreenApp/IdleScreenLaunchPolicy.swift" ||
   ! grep -Fq 'IdleScreenLaunchPolicy.backgroundProbe' "$project_root/IdleScreenApp/IdleScreenAppDelegate.swift" ||
   ! grep -Fq 'updateContrast(contrast)' "$project_root/IdleScreenApp/IdleScreenAppDelegate.swift"; then
  echo "FAIL: background configuration probes must use the real companion update path without revealing a window." >&2
  exit 1
fi

echo "PASS: automated configuration delivery uses a focus-free real companion edit."

live_configuration_runner="$project_root/scripts/test-live-configuration-delivery.sh"
live_configuration_guard="$project_root/scripts/test-live-configuration-delivery-guard.sh"
if [[ ! -x "$live_configuration_runner" ]] ||
   [[ ! -x "$live_configuration_guard" ]] ||
   ! grep -Fq 'test-live-configuration-delivery-guard.sh' "$project_root/scripts/test-phase1.sh" ||
   ! grep -Fq 'IDLESCREEN_ALLOW_PHYSICAL_TESTS' "$live_configuration_runner" ||
   ! grep -Fq 'restore_original_configuration_best_effort' "$live_configuration_runner" ||
   ! grep -Fq 'extension survived companion quit' "$live_configuration_runner"; then
  echo "FAIL: exact-Release live delivery must be guarded, recoverable, and verify companion independence." >&2
  exit 1
fi

echo "PASS: exact-Release live delivery is guarded and restores temporary edits on failure."

if ! grep -Fq 'ScreenSaverSelectionClient' "$project_root/IdleScreenApp/IdleScreenAppModel.swift" ||
   ! grep -Fq 'startIdleScreen(selection:' "$project_root/IdleScreenApp/IdleScreenAppModel.swift" ||
   grep -Rqs 'startCurrentScreenSaver()' "$project_root/IdleScreenApp"; then
  echo "FAIL: the companion must read selection and guard activation before starting IdleScreen." >&2
  exit 1
fi

for selection_surface in \
  "$project_root/IdleScreenApp/IdleScreenStudio.swift" \
  "$project_root/IdleScreenApp/IdleScreenMenuBar.swift" \
  "$project_root/IdleScreenApp/SystemViews.swift"; do
  if ! grep -Fq 'model.selection?.isSelectedEverywhere' "$selection_surface"; then
    echo "FAIL: $(basename "$selection_surface") must disable activation until IdleScreen is selected." >&2
    exit 1
  fi
done

echo "PASS: every companion activation surface is guarded by read-only selection state."

if ! grep -Fq 'registrationClient.assessment(' "$project_root/IdleScreenApp/IdleScreenAppModel.swift" ||
   ! grep -Fq 'registrationClient.repair(' "$project_root/IdleScreenApp/IdleScreenAppModel.swift" ||
   ! grep -Fq 'registrationClient.forceRepair(' "$project_root/IdleScreenApp/IdleScreenAppModel.swift" ||
   ! grep -Fq 'registrationAssessment.location' "$project_root/IdleScreenApp/SystemViews.swift" ||
   ! grep -Fq 'Repair Screen Saver' "$project_root/IdleScreenApp/SystemViews.swift" ||
   ! grep -Fq 'Different copy' "$project_root/IdleScreenApp/SystemViews.swift"; then
  echo "FAIL: the companion must diagnose and repair a stale screen saver registration." >&2
  exit 1
fi

if grep -Fq 'model.registration.isRegistered || model.isRegistering' \
  "$project_root/IdleScreenApp/IdleScreenMenuBar.swift"; then
  echo "FAIL: a stale registration must keep the menu-bar repair action enabled." >&2
  exit 1
fi

echo "PASS: companion registration surfaces distinguish and repair stale app copies."

core_target_block="$({
  awk '
    /^targets:$/ { in_targets = 1; next }
    in_targets && /^  IdleScreenCore:$/ { in_core = 1; next }
    in_core && /^  [[:alnum:]_]+:$/ { exit }
    in_core { print }
  ' "$project_file"
})"

if [[ -z "$core_target_block" ]]; then
  echo "FAIL: project.yml must define the shared IdleScreenCore target." >&2
  exit 1
fi

if ! grep -Fq 'type: framework.static' <<<"$core_target_block" ||
   ! grep -Fq 'path: IdleScreenCore' <<<"$core_target_block"; then
  echo "FAIL: IdleScreenCore must be an isolated static framework target." >&2
  exit 1
fi

echo "PASS: IdleScreenCore is an isolated shared static framework target."

core_tests_target_block="$({
  awk '
    /^  IdleScreenCoreTests:$/ { in_core_tests = 1; next }
    in_core_tests && /^  [[:alnum:]_]+:$/ { exit }
    in_core_tests { print }
  ' "$project_file"
})"

if [[ -z "$core_tests_target_block" ]] ||
   ! grep -Fq 'type: bundle.unit-test' <<<"$core_tests_target_block" ||
   ! grep -Fq 'target: IdleScreenCore' <<<"$core_tests_target_block"; then
  echo "FAIL: IdleScreenCore must have an isolated unit-test target." >&2
  exit 1
fi

echo "PASS: IdleScreenCore has an isolated unit-test target."

display_target_block="$({
  awk '
    /^targets:$/ { in_targets = 1; next }
    in_targets && /^  IdleScreenDisplay:$/ { in_display = 1; next }
    in_display && /^  [[:alnum:]_]+:$/ { exit }
    in_display { print }
  ' "$project_root/project.yml"
})"
display_tests_target_block="$({
  awk '
    /^  IdleScreenDisplayTests:$/ { in_display_tests = 1; next }
    in_display_tests && /^  [[:alnum:]_]+:$/ { exit }
    in_display_tests { print }
  ' "$project_root/project.yml"
})"
if [[ -z "$display_target_block" ]] ||
   ! grep -Fq 'type: framework.static' <<<"$display_target_block" ||
   ! grep -Fq 'path: IdleScreenDisplay' <<<"$display_target_block" ||
   ! grep -Fq 'APPLICATION_EXTENSION_API_ONLY: YES' <<<"$display_target_block" ||
   ! grep -Fq 'target: IdleScreenCore' <<<"$display_target_block" ||
   ! grep -Fq 'AppKit.framework' <<<"$display_target_block" ||
   ! grep -Fq 'ColorSync.framework' <<<"$display_target_block" ||
   [[ -z "$display_tests_target_block" ]] ||
   ! grep -Fq 'path: IdleScreenDisplayTests' <<<"$display_tests_target_block" ||
   ! grep -Fq 'target: IdleScreenDisplay' <<<"$display_tests_target_block"; then
  echo "FAIL: live display observation must stay in one tested, extension-safe shared module." >&2
  exit 1
fi

echo "PASS: live display observation is isolated in a tested extension-safe shared module."

system_target_block="$({
  awk '
    /^targets:$/ { in_targets = 1; next }
    in_targets && /^  IdleScreenSystem:$/ { in_system = 1; next }
    in_system && /^  [[:alnum:]_]+:$/ { exit }
    in_system { print }
  ' "$project_file"
})"

system_tests_target_block="$({
  awk '
    /^  IdleScreenSystemTests:$/ { in_system_tests = 1; next }
    in_system_tests && /^  [[:alnum:]_]+:$/ { exit }
    in_system_tests { print }
  ' "$project_file"
})"

if ! grep -Fq 'type: framework.static' <<<"$system_target_block" ||
   ! grep -Fq 'path: IdleScreenSystem' <<<"$system_target_block" ||
   ! grep -Fq 'target: IdleScreenSystem' <<<"$system_tests_target_block"; then
  echo "FAIL: pluginkit and host operations must live in a tested IdleScreenSystem boundary." >&2
  exit 1
fi

echo "PASS: IdleScreenSystem isolates and tests host-only operations."

extension_target_block="$({
  awk '
    /^targets:$/ { in_targets = 1; next }
    in_targets && /^  IdleScreenScreenSaver:$/ { in_extension = 1; next }
    in_extension && /^  [[:alnum:]_]+:$/ { exit }
    in_extension { print }
  ' "$project_file"
})"

if [[ -z "$extension_target_block" ]]; then
  echo "FAIL: project.yml must define the embedded IdleScreenScreenSaver target." >&2
  exit 1
fi

if ! grep -Fq 'type: app-extension' <<<"$extension_target_block" ||
   ! grep -Fq 'path: IdleScreenScreenSaver' <<<"$extension_target_block" ||
   ! grep -Fq 'path: IdleScreenScreenSaver/Info.plist' <<<"$extension_target_block" ||
   ! grep -Fq 'CODE_SIGN_ENTITLEMENTS: IdleScreenScreenSaver/IdleScreenScreenSaver.entitlements' <<<"$extension_target_block"; then
  echo "FAIL: IdleScreenScreenSaver must own an app-extension target, plist, and entitlements." >&2
  exit 1
fi

if ! grep -Eq 'PRODUCT_BUNDLE_IDENTIFIER: com\.idlescreen\.app\.dev\.screensaver$' <<<"$extension_target_block" ||
   ! grep -Eq 'PRODUCT_BUNDLE_IDENTIFIER: com\.idlescreen\.app\.screensaver$' <<<"$extension_target_block" ||
   ! grep -Fq 'configs:' <<<"$extension_target_block"; then
  echo "FAIL: IdleScreenScreenSaver must use separate Debug and Release bundle identifiers." >&2
  exit 1
fi

if grep -Fq 'NSCameraUsageDescription' <<<"$extension_target_block"; then
  echo "FAIL: The Phase 1 screen saver shell must not request camera access." >&2
  exit 1
fi

if ! grep -Fq 'IDLESCREEN_APP_GROUP_IDENTIFIER: group.com.idlescreen.dev.shared' <<<"$extension_target_block" ||
   ! grep -Fq 'IDLESCREEN_APP_GROUP_IDENTIFIER: group.com.idlescreen.shared' <<<"$extension_target_block" ||
   ! grep -Fq 'CODE_SIGN_ENTITLEMENTS: IdleScreenScreenSaver/IdleScreenScreenSaver-Debug.entitlements' <<<"$extension_target_block" ||
   ! grep -Fq 'IDLESCREEN_SHARED_CONTAINER_ENABLED: NO' <<<"$extension_target_block" ||
   ! grep -Fq 'IDLESCREEN_SHARED_CONTAINER_ENABLED: YES' <<<"$extension_target_block" ||
   ! plutil -convert json -o - "$project_root/IdleScreenScreenSaver/IdleScreenScreenSaver.entitlements" | grep -Fq 'com.apple.security.application-groups'; then
  echo "FAIL: IdleScreenScreenSaver must share the versioned app-group container." >&2
  exit 1
fi

echo "PASS: IdleScreenScreenSaver has an isolated camera-free extension boundary."

for release_target_block in "$companion_target_block" "$extension_target_block"; do
  if ! grep -Fq 'DEVELOPMENT_TEAM: 3524374A2S' <<<"$release_target_block" ||
     ! grep -Fq 'CODE_SIGN_STYLE: Automatic' <<<"$release_target_block" ||
     ! grep -Fq 'CODE_SIGN_IDENTITY: "Apple Development"' <<<"$release_target_block" ||
     ! grep -Fq 'REGISTER_APP_GROUPS: YES' <<<"$release_target_block"; then
    echo "FAIL: both Release products must automatically provision the shared App Group with the same development team." >&2
    exit 1
  fi
done

echo "PASS: both Release products declare the same automatic App Group development-provisioning contract."

console_lock_state_probe="$project_root/scripts/read-console-lock-state.sh"
console_lock_state_test="$project_root/scripts/test-console-lock-state.sh"
if [[ ! -x "$console_lock_state_probe" ]] ||
   ! bash -n "$console_lock_state_probe" ||
   ! grep -Fq 'IOConsoleLocked' "$console_lock_state_probe" ||
   ! grep -Fq -- '-expect bool' "$console_lock_state_probe" ||
   [[ ! -x "$console_lock_state_test" ]] ||
   ! bash -n "$console_lock_state_test"; then
  echo "FAIL: physical workflows need one fail-closed, fixture-tested console lock-state probe." >&2
  exit 1
fi

echo "PASS: physical workflows share a fail-closed console lock-state probe."

release_signing_verifier="$project_root/scripts/verify-release-signing.sh"
if [[ ! -x "$release_signing_verifier" ]] ||
   ! bash -n "$release_signing_verifier" ||
   ! grep -Fq 'TeamIdentifier=' "$release_signing_verifier" ||
   ! grep -Fq 'group.com.idlescreen.shared' "$release_signing_verifier" ||
   ! grep -Fq 'embedded.provisionprofile' "$release_signing_verifier" ||
   ! grep -Fq 'codesign --verify --deep --strict' "$release_signing_verifier"; then
  echo "FAIL: provisioned Release evidence needs one read-only nested-signing verifier." >&2
  exit 1
fi

echo "PASS: Release provisioning has a read-only nested-signing verifier."

camera_agent_product_verifier="$project_root/scripts/test-camera-agent-product.sh"
camera_agent_profile_policy="$project_root/scripts/camera-agent-profile-policy.sh"
camera_agent_profile_policy_test="$project_root/scripts/test-camera-agent-profile-policy.sh"
if [[ ! -x "$camera_agent_product_verifier" ]] ||
   ! bash -n "$camera_agent_product_verifier" ||
   [[ ! -x "$camera_agent_profile_policy" ]] ||
   ! bash -n "$camera_agent_profile_policy" ||
   ! grep -Fq 'ExpirationDate' "$camera_agent_profile_policy" ||
   ! grep -Fq 'DeveloperCertificates' "$camera_agent_profile_policy" ||
   ! grep -Fq -- '--extract-certificates=' "$camera_agent_product_verifier" ||
   [[ ! -x "$camera_agent_profile_policy_test" ]] ||
   ! bash -n "$camera_agent_profile_policy_test" ||
   ! grep -Fq 'test-camera-agent-profile-policy.sh' "$project_root/scripts/test-phase1.sh"; then
  echo "FAIL: the Release camera-agent verifier must bind a current profile to the helper signing certificate." >&2
  exit 1
fi

echo "PASS: Release camera-agent evidence binds profile validity and signer membership."

synthetic_gate_contracts="$project_root/scripts/test-synthetic-gate-contracts.sh"
if [[ ! -x "$synthetic_gate_contracts" ]] ||
   ! bash -n "$synthetic_gate_contracts" ||
   ! grep -Fq 'test-synthetic-gate-contracts.sh' "$project_root/scripts/test-phase1.sh"; then
  echo "FAIL: the signed synthetic gate needs an isolated deterministic contract gate." >&2
  exit 1
fi

synthetic_gate_fixtures="$project_root/scripts/test-synthetic-gate-product-fixtures.sh"
if [[ ! -x "$synthetic_gate_fixtures" ]] ||
   ! bash -n "$synthetic_gate_fixtures" ||
   ! grep -Fq 'test-synthetic-gate-product-fixtures.sh' "$project_root/scripts/test-phase1.sh"; then
  echo "FAIL: the synthetic gate needs fail-closed product fixtures in Phase 1." >&2
  exit 1
fi

echo "PASS: the signed synthetic gate has an isolated deterministic contract gate."

c2_headless_gate="$project_root/scripts/test-camera-gate-c2.sh"
if [[ ! -x "$c2_headless_gate" ]] ||
   ! bash -n "$c2_headless_gate"; then
  echo "FAIL: C2 needs one executable headless aggregate." >&2
  exit 1
fi
for c2_gate in \
  test-repository-layout.sh \
  test-project-contracts.sh \
  test-camera-agent-product-fixtures.sh \
  test-synthetic-gate-contracts.sh \
  test-synthetic-gate-product-fixtures.sh \
  test-synthetic-gate-transaction.sh \
  test-camera-gate-a1-config.sh \
  test-camera-gate-a1-runner.sh; do
  grep -Fq "$c2_gate" "$c2_headless_gate" || {
    echo "FAIL: the C2 headless aggregate omits $c2_gate." >&2
    exit 1
  }
done
grep -Fq 'IdleScreenSyntheticGateTests' "$c2_headless_gate" || {
  echo "FAIL: the C2 headless aggregate omits synthetic-helper unit tests." >&2
  exit 1
}
grep -Fq 'IdleScreenSyntheticHostedGateViewControllerTests' "$c2_headless_gate" || {
  echo "FAIL: the C2 headless aggregate omits hosted-gate factory tests." >&2
  exit 1
}
if grep -Eq 'xcodebuild[[:space:]]+build([[:space:]]|$)|pluginkit[[:space:]]+(-a|-r)|run-camera-gate-a1\.sh|install-phase1' \
  "$c2_headless_gate"; then
  echo "FAIL: the C2 headless aggregate contains an app build, registration, install, or physical runner action." >&2
  exit 1
fi

physical_opt_in_line="$(grep -nF 'IDLESCREEN_ALLOW_PHYSICAL_TESTS' "$project_root/scripts/test-phase1.sh" | head -1 | cut -d: -f1)"
phase1_generation_line="$(grep -nF 'xcodegen generate' "$project_root/scripts/test-phase1.sh" | head -1 | cut -d: -f1)"
if [[ ! "$physical_opt_in_line" =~ ^[1-9][0-9]*$ ||
      ! "$phase1_generation_line" =~ ^[1-9][0-9]*$ ]] ||
   ((physical_opt_in_line >= phase1_generation_line)); then
  echo "FAIL: the stateful Phase 1 aggregate must require physical authorization before any build workflow." >&2
  exit 1
fi

echo "PASS: C2 has a dedicated headless aggregate and the stateful Phase 1 suite is opt-in."

c3_scheme_block="$({
  awk '
    /^  IdleScreenC3ReleaseArchive:$/ { in_scheme = 1; print; next }
    in_scheme && /^  [[:alnum:]_]+:$/ { exit }
    in_scheme { print }
  ' "$project_file"
})"
c3_scheme_file="$project_root/IdleScreen.xcodeproj/xcshareddata/xcschemes/IdleScreenC3ReleaseArchive.xcscheme"
c3_builder="$project_root/scripts/build-camera-gate-c3-release.sh"
c3_aggregate="$project_root/scripts/test-camera-gate-c3.sh"
c3_verifier="$project_root/scripts/verify-release-archive-provenance.sh"
c3_fixtures="$project_root/scripts/test-release-archive-provenance-fixtures.sh"

if [[ -z "$c3_scheme_block" ]] ||
   ! grep -Fq 'IdleScreenC3ArchiveBundle: [archive]' <<<"$c3_scheme_block" ||
   ! grep -Fq 'config: Release' <<<"$c3_scheme_block" ||
   [[ ! -f "$c3_scheme_file" ]] ||
   ! grep -Fq 'buildForArchiving = "YES"' "$c3_scheme_file" ||
   ! grep -Fq 'buildForRunning = "NO"' "$c3_scheme_file" ||
   ! grep -Fq '<ArchiveAction' "$c3_scheme_file" ||
   ! grep -Fq 'buildConfiguration = "Release"' "$c3_scheme_file" ||
   ! grep -Fq 'revealArchiveInOrganizer = "NO"' "$c3_scheme_file"; then
  echo "FAIL: C3 needs one explicit Release Archive action whose application-shaped bundle is not built for running." >&2
  exit 1
fi

if ! grep -Fq 'IdleScreenC3ArchiveBundle:' "$project_file" ||
   ! grep -Fq 'IdleScreenC3CameraAgentArchiveBundle:' "$project_file" ||
   ! grep -Fq 'WRAPPER_EXTENSION: app' "$project_file" ||
   ! grep -Fq 'MACH_O_TYPE: mh_execute' "$project_file" ||
   ! grep -Fq 'IDLESCREEN_C3_APP_PROVISIONING_PROFILE_PATH' "$project_file" ||
   ! grep -Fq 'IDLESCREEN_C3_HELPER_PROVISIONING_PROFILE_PATH' "$project_file"; then
  echo "FAIL: C3 archive products must be application-shaped bundle targets with explicit embedded profiles." >&2
  exit 1
fi

c3_identity_preflight_line="$(grep -nF '/usr/bin/security find-identity' "$c3_builder" | head -1 | cut -d: -f1)"
c3_evidence_create_line="$(grep -nF '/bin/mkdir "$output_root"' "$c3_builder" | head -1 | cut -d: -f1)"

if [[ ! -x "$c3_builder" ]] ||
   ! bash -n "$c3_builder" ||
   ! grep -Fq '/usr/bin/xcodebuild archive' "$c3_builder" ||
   ! grep -Fq -- '-scheme "$scheme"' "$c3_builder" ||
   ! grep -Fq 'IdleScreenC3ReleaseArchive' "$c3_builder" ||
   ! grep -Fq -- "-destination 'generic/platform=macOS'" "$c3_builder" ||
   ! grep -Fq -- '-archivePath "$archive_path"' "$c3_builder" ||
   ! grep -Fq -- '-allowProvisioningUpdates' "$c3_builder" ||
   ! grep -Fq 'IDLESCREEN_ALLOW_SIGNING_CREDENTIAL_UPDATES' "$c3_builder" ||
   ! grep -Fq 'developer account, local profile store, or Keychain' "$c3_builder" ||
   grep -Fq '"$project_root/release"/*' "$c3_builder" ||
   grep -Fxq 'release/' "$project_root/.gitignore" ||
   ! grep -Fq 'C3 evidence must be written outside the source repository' "$c3_builder" ||
   ! grep -Fq 'test-camera-gate-c3.sh' "$c3_builder" ||
   ! grep -Fq 'no usable Apple Development signing identity is visible' "$c3_builder" ||
   ! grep -Fq 'Exact Team identity is enforced on the completed archive' "$c3_builder" ||
   ! grep -Fq 'camera_agent_profile_is_development "$decoded_profile"' "$c3_builder" ||
   ! grep -Fq 'IDLESCREEN_PROVENANCE_FIXTURE_MODE' "$c3_builder" ||
   ! grep -Fq 'IDLESCREEN_PROVENANCE_CODESIGN' "$c3_builder" ||
   ! grep -Fq 'IDLESCREEN_PROVENANCE_SECURITY' "$c3_builder" ||
   ! grep -Fq "grep -Fxc 'verification_mode=release'" "$c3_builder" ||
   ! grep -Fq "grep -Ec '^verification_mode='" "$c3_builder" ||
   [[ ! "$c3_identity_preflight_line" =~ ^[1-9][0-9]*$ ]] ||
   [[ ! "$c3_evidence_create_line" =~ ^[1-9][0-9]*$ ]] ||
   ((c3_identity_preflight_line >= c3_evidence_create_line)) ||
   ! grep -Fq 'RegisterWithLaunchServices' "$c3_builder" ||
   ! grep -Fq 'refusing to replace existing C3 evidence' "$c3_builder"; then
  echo "FAIL: C3 needs a non-overwriting provisioned archive builder with clear credential and LaunchServices guards." >&2
  exit 1
fi

if grep -Eq 'xcodebuild[[:space:]]+build([[:space:]]|$)|pluginkit[[:space:]]+(-a|-r)|launchctl[[:space:]]+(bootstrap|bootout|kickstart)|(^|[[:space:]])(/usr/bin/)?open[[:space:]]|tccutil[[:space:]]|run-camera-gate-a1\.sh|install-phase1' \
  "$c3_builder"; then
  echo "FAIL: the C3 archive builder contains an install, registration, launch, TCC, camera, or non-archive app-build action." >&2
  exit 1
fi

if [[ ! -x "$c3_aggregate" ]] ||
   ! bash -n "$c3_aggregate" ||
   ! grep -Fq 'test-camera-gate-c2.sh' "$c3_aggregate" ||
   ! grep -Fq 'test-release-archive-provenance-fixtures.sh' "$c3_aggregate" ||
   ! grep -Fq 'verify-release-archive-provenance.sh' "$c3_aggregate" ||
   ! grep -Fq 'supplied archive exactly reproduces its recorded C3 provenance manifest' "$c3_aggregate" ||
   ! grep -Fq 'C3 needs one supplied, provisioned Release .xcarchive' "$c3_aggregate" ||
   ! grep -Fq 'IDLESCREEN_ALLOW_SIGNING_CREDENTIAL_UPDATES=YES' "$c3_aggregate" ||
   ! grep -Fq 'IDLESCREEN_PROVENANCE_FIXTURE_MODE' "$c3_aggregate" ||
   ! grep -Fq 'IDLESCREEN_PROVENANCE_CODESIGN' "$c3_aggregate" ||
   ! grep -Fq 'IDLESCREEN_PROVENANCE_SECURITY' "$c3_aggregate" ||
   ! grep -Fq 'require_release_manifest "$manifest_path"' "$c3_aggregate" ||
   ! grep -Fq 'require_release_manifest "$replay_manifest"' "$c3_aggregate" ||
   ! grep -Fq "grep -Fxc 'verification_mode=release'" "$c3_aggregate" ||
   ! grep -Fq "grep -Ec '^verification_mode='" "$c3_aggregate" ||
   [[ ! -x "$c3_verifier" ]] ||
   ! bash -n "$c3_verifier" ||
   [[ ! -x "$c3_fixtures" ]] ||
   ! bash -n "$c3_fixtures"; then
  echo "FAIL: C3 needs one safe aggregate with fixture, artifact, and manifest-replay gates." >&2
  exit 1
fi

if grep -Eq 'xcodebuild[[:space:]]+(archive|build)([[:space:]]|$)|pluginkit[[:space:]]+(-a|-r)|launchctl[[:space:]]+(bootstrap|bootout|kickstart)|run-camera-gate-a1\.sh|install-phase1' \
  "$c3_aggregate"; then
  echo "FAIL: the C3 verification aggregate must remain read-only and camera-free." >&2
  exit 1
fi

echo "PASS: C3 invokes only the Release Archive action and requires replayable release-mode provenance."

c4_preparer="$project_root/scripts/prepare-camera-gate-c4.sh"
c4_helper_scheme_file="$project_root/IdleScreen.xcodeproj/xcshareddata/xcschemes/IdleScreenC4SyntheticHelperArchive.xcscheme"
c4_extension_scheme_file="$project_root/IdleScreen.xcodeproj/xcshareddata/xcschemes/IdleScreenC4SyntheticHostedExtensionArchive.xcscheme"
c4_helper_target_block="$({
  awk '
    /^  IdleScreenC4SyntheticHelperArchiveBundle:$/ { in_target = 1; print; next }
    in_target && /^  [[:alnum:]_]+:$/ { exit }
    in_target { print }
  ' "$project_file"
})"
c4_extension_target_block="$({
  awk '
    /^  IdleScreenC4SyntheticHostedExtensionArchiveBundle:$/ { in_target = 1; print; next }
    in_target && /^  [[:alnum:]_]+:$/ { exit }
    in_target { print }
  ' "$project_file"
})"

for c4_scheme_contract in \
  'IdleScreenC4SyntheticHelperArchive:IdleScreenC4SyntheticHelperArchiveBundle' \
  'IdleScreenC4SyntheticHostedExtensionArchive:IdleScreenC4SyntheticHostedExtensionArchiveBundle'; do
  c4_scheme_name="${c4_scheme_contract%%:*}"
  c4_target_name="${c4_scheme_contract##*:}"
  c4_scheme_block="$({
    awk -v scheme="$c4_scheme_name" '
      $0 == "  " scheme ":" { in_scheme = 1; print; next }
      in_scheme && /^  [[:alnum:]_]+:$/ { exit }
      in_scheme { print }
    ' "$project_file"
  })"
  if [[ -z "$c4_scheme_block" ]] ||
     ! grep -Fq "$c4_target_name: [archive]" <<<"$c4_scheme_block" ||
     ! grep -Fq 'config: Release' <<<"$c4_scheme_block" ||
     ! grep -Fq 'revealArchiveInOrganizer: false' <<<"$c4_scheme_block"; then
    echo "FAIL: $c4_scheme_name must archive only its dedicated C4 bundle target." >&2
    exit 1
  fi
done

for c4_scheme_file in "$c4_helper_scheme_file" "$c4_extension_scheme_file"; do
  if [[ ! -f "$c4_scheme_file" ]] ||
     ! grep -Fq 'buildForArchiving = "YES"' "$c4_scheme_file" ||
     ! grep -Fq 'buildForRunning = "NO"' "$c4_scheme_file" ||
     ! grep -Fq 'buildForProfiling = "NO"' "$c4_scheme_file" ||
     ! grep -Fq '<ArchiveAction' "$c4_scheme_file" ||
     ! grep -Fq 'buildConfiguration = "Release"' "$c4_scheme_file"; then
    echo "FAIL: C4 bundle schemes must be shared Archive-only Release actions." >&2
    exit 1
  fi
done

if [[ -z "$c4_helper_target_block" ]] ||
   ! grep -Fq 'type: bundle' <<<"$c4_helper_target_block" ||
   ! grep -Fq 'path: IdleScreenSyntheticGate/Executable' <<<"$c4_helper_target_block" ||
   ! grep -Fq 'CFBundlePackageType: APPL' <<<"$c4_helper_target_block" ||
   ! grep -Fq 'WRAPPER_EXTENSION: app' <<<"$c4_helper_target_block" ||
   ! grep -Fq 'MACH_O_TYPE: mh_execute' <<<"$c4_helper_target_block" ||
   ! grep -Fq 'INSTALL_PATH: /Applications' <<<"$c4_helper_target_block" ||
   ! grep -Fq 'SKIP_INSTALL: NO' <<<"$c4_helper_target_block" ||
   ! grep -Fq 'IdleScreenCameraSyntheticAgentC4Archive.entitlements' <<<"$c4_helper_target_block" ||
   ! grep -Fq 'IDLESCREEN_C4_HELPER_PROVISIONING_PROFILE_PATH' <<<"$c4_helper_target_block"; then
  echo "FAIL: the C4 synthetic helper archive must be an app-shaped generic bundle with explicit identity/profile inputs." >&2
  exit 1
fi

if [[ -z "$c4_extension_target_block" ]] ||
   ! grep -Fq 'type: bundle' <<<"$c4_extension_target_block" ||
   ! grep -Fq 'path: IdleScreenSyntheticHostedGateExtension' <<<"$c4_extension_target_block" ||
   ! grep -Fq 'CFBundlePackageType: XPC!' <<<"$c4_extension_target_block" ||
   ! grep -Fq 'WRAPPER_EXTENSION: appex' <<<"$c4_extension_target_block" ||
   ! grep -Fq 'MACH_O_TYPE: mh_bundle' <<<"$c4_extension_target_block" ||
   ! grep -Fq 'INSTALL_PATH: /Applications' <<<"$c4_extension_target_block" ||
   ! grep -Fq 'SKIP_INSTALL: NO' <<<"$c4_extension_target_block" ||
   ! grep -Fq 'IdleScreenSyntheticHostedGateExtensionC4Archive.entitlements' <<<"$c4_extension_target_block" ||
   ! grep -Fq 'IDLESCREEN_C4_EXTENSION_PROVISIONING_PROFILE_PATH' <<<"$c4_extension_target_block"; then
  echo "FAIL: the C4 hosted extension archive must be an appex-shaped generic bundle with explicit identity/profile inputs." >&2
  exit 1
fi

c4_helper_entitlements="$project_root/IdleScreenSyntheticGate/IdleScreenCameraSyntheticAgentC4Archive.entitlements"
c4_extension_entitlements="$project_root/IdleScreenSyntheticHostedGateExtension/IdleScreenSyntheticHostedGateExtensionC4Archive.entitlements"
if [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$c4_helper_entitlements" 2>/dev/null || true)" != '3524374A2S.com.idlescreen.camera-agent' ]] ||
   [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$c4_helper_entitlements" 2>/dev/null || true)" != 3524374A2S ]] ||
   [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$c4_extension_entitlements" 2>/dev/null || true)" != '3524374A2S.com.idlescreen.app.screensaver' ]] ||
   [[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.team-identifier' "$c4_extension_entitlements" 2>/dev/null || true)" != 3524374A2S ]] ||
   /usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.camera' "$c4_helper_entitlements" >/dev/null 2>&1 ||
   /usr/libexec/PlistBuddy -c 'Print :com.apple.security.device.camera' "$c4_extension_entitlements" >/dev/null 2>&1; then
  echo "FAIL: C4 generic bundles require explicit exact Team/application entitlements and no camera entitlement." >&2
  exit 1
fi

c4_archive_line="$(grep -nF '/usr/bin/xcodebuild archive' "$c4_preparer" | head -1 | cut -d: -f1)"
c4_registration_guard_line="$(grep -nF 'archive attempted LaunchServices registration' "$c4_preparer" | head -1 | cut -d: -f1)"
c4_status_branch_line="$(grep -nF 'if ((archive_status != 0))' "$c4_preparer" | head -1 | cut -d: -f1)"
if [[ ! -x "$c4_preparer" ]] ||
   ! bash -n "$c4_preparer" ||
   ! grep -Fq 'IdleScreenC4SyntheticHelperArchive' "$c4_preparer" ||
   ! grep -Fq 'IdleScreenC4SyntheticHostedExtensionArchive' "$c4_preparer" ||
   grep -Fq 'IdleScreenCameraSyntheticAgentArchive|' "$c4_preparer" ||
   grep -Fq 'IdleScreenSyntheticHostedGateExtensionArchive|' "$c4_preparer" ||
   ! grep -Fq 'IDLESCREEN_C4_HELPER_PROVISIONING_PROFILE_PATH="$production_helper_profile"' "$c4_preparer" ||
   ! grep -Fq 'IDLESCREEN_C4_EXTENSION_PROVISIONING_PROFILE_PATH="$production_extension_profile"' "$c4_preparer" ||
   [[ "$(grep -Fc '/usr/bin/cmp -s "$production_' "$c4_preparer")" != 2 ]] ||
   [[ ! "$c4_archive_line" =~ ^[1-9][0-9]*$ ]] ||
   [[ ! "$c4_registration_guard_line" =~ ^[1-9][0-9]*$ ]] ||
   [[ ! "$c4_status_branch_line" =~ ^[1-9][0-9]*$ ]] ||
   ((c4_archive_line >= c4_registration_guard_line)) ||
   ((c4_registration_guard_line >= c4_status_branch_line)); then
  echo "FAIL: C4 preparation must archive only C4 bundles, replay both exact C3 profiles, and scan registration before interpreting archive status." >&2
  exit 1
fi

if grep -Eq 'xcodebuild[[:space:]]+build([[:space:]]|$)|pluginkit[[:space:]]+(-a|-r)|launchctl[[:space:]]+(bootstrap|bootout|kickstart)|(^|[[:space:]])(/usr/bin/)?open[[:space:]]|tccutil[[:space:]]' \
  "$c4_preparer"; then
  echo "FAIL: C4 preparation contains a non-archive app build, registration, launch, or TCC action." >&2
  exit 1
fi

echo "PASS: C4 preparation uses only LaunchServices-clean generic bundle archives with exact C3 profile replay."

release_candidate_builder="$project_root/scripts/build-phase1-release.sh"
if [[ ! -x "$release_candidate_builder" ]] ||
   ! bash -n "$release_candidate_builder" ||
   ! grep -Fq -- '-configuration Release' "$release_candidate_builder" ||
   ! grep -Fq -- '-allowProvisioningUpdates' "$release_candidate_builder" ||
   ! grep -Fq 'verify-release-signing.sh' "$release_candidate_builder" ||
   ! grep -Fq 'test-camera-agent-product.sh' "$release_candidate_builder" ||
   ! grep -Fq 'test-modern-product.sh' "$release_candidate_builder" ||
   ! grep -Fq 'ScreenSaverSelectionProbe.swift' "$release_candidate_builder" ||
   ! grep -Fq 'restore_preflight_registration' "$release_candidate_builder" ||
   ! grep -Fq 'CRITICAL: Release registration restoration failed' "$release_candidate_builder" ||
   ! grep -Fq 'System Settings is open' "$release_candidate_builder" ||
   ! grep -Fq 'console_is_locked' "$release_candidate_builder" ||
   ! grep -Fq 'read-console-lock-state.sh' "$release_candidate_builder" ||
   ! grep -Fq 'the console is locked' "$release_candidate_builder" ||
   ! grep -Fq 'WallpaperAgent' "$release_candidate_builder" ||
   ! grep -Fq 'new WallpaperAgent PID' "$release_candidate_builder" ||
   ! grep -Fq 'ScreenSaverEngine is active' "$release_candidate_builder"; then
  echo "FAIL: the provisioned Release build must preserve physical registration state." >&2
  exit 1
fi

echo "PASS: the provisioned Release builder is registration-preserving and saver-aware."

release_candidate_installer="$project_root/scripts/install-phase1-release.sh"
if [[ ! -x "$release_candidate_installer" ]] ||
   ! bash -n "$release_candidate_installer" ||
   ! grep -Fq '/Applications/idlescreen.app' "$release_candidate_installer" ||
   ! grep -Fq 'verify-release-signing.sh' "$release_candidate_installer" ||
   ! grep -Fq 'test-camera-agent-product.sh' "$release_candidate_installer" ||
   ! grep -Fq 'ScreenSaverSelectionProbe.swift' "$release_candidate_installer" ||
   ! grep -Fq 'capture-phase1-physical-state.sh' "$release_candidate_installer" ||
   ! grep -Fq 'rollback_install' "$release_candidate_installer" ||
   ! grep -Fq 'CRITICAL: automatic Release rollback failed' "$release_candidate_installer" ||
   ! grep -Fq 'CRITICAL: Release staging cleanup failed' "$release_candidate_installer" ||
   ! grep -Fq 'rollback did not restore the production provider set' "$release_candidate_installer" ||
   ! grep -Fq 'canonical companion is active' "$release_candidate_installer" ||
   ! grep -Fq 'WallpaperAgent' "$release_candidate_installer" ||
   ! grep -Fq 'read-console-lock-state.sh' "$release_candidate_installer" ||
   ! grep -Fq 'new WallpaperAgent PID' "$release_candidate_installer" ||
   ! grep -Fq '.Trash' "$release_candidate_installer"; then
  echo "FAIL: canonical Release updates need recoverable install and rollback semantics." >&2
  exit 1
fi

builder_camera_gate_line="$(grep -nF '"$camera_product_verifier" "$candidate_app" Release' "$release_candidate_builder" | head -1 | cut -d: -f1)"
builder_success_line="$(grep -nF 'PASS: provisioned Phase 1 Release candidate built and verified.' "$release_candidate_builder" | head -1 | cut -d: -f1)"
installer_camera_gate_line="$(grep -nF '"$camera_product_verifier" "$candidate_app" Release' "$release_candidate_installer" | head -1 | cut -d: -f1)"
installer_first_install_line="$(grep -nF '/usr/bin/ditto "$candidate_app" "$staging_app"' "$release_candidate_installer" | head -1 | cut -d: -f1)"
if [[ ! "$builder_camera_gate_line" =~ ^[1-9][0-9]*$ ||
      ! "$builder_success_line" =~ ^[1-9][0-9]*$ ||
      ! "$installer_camera_gate_line" =~ ^[1-9][0-9]*$ ||
      ! "$installer_first_install_line" =~ ^[1-9][0-9]*$ ]] ||
   ((builder_camera_gate_line >= builder_success_line)) ||
   ((installer_camera_gate_line >= installer_first_install_line)); then
  echo "FAIL: the signed camera-agent product gate must run before builder success and before installer staging." >&2
  exit 1
fi

echo "PASS: canonical Release updates are verification-first and recoverable."

release_installer_registration_test="$project_root/scripts/test-install-phase1-release-registration.sh"
if [[ ! -x "$release_installer_registration_test" ]] ||
   ! bash -n "$release_installer_registration_test" ||
   ! grep -Fq 'test-install-phase1-release-registration.sh' "$project_root/scripts/test-phase1.sh"; then
  echo "FAIL: the Phase 1 gate must exercise deterministic Tahoe registration convergence tests." >&2
  exit 1
fi

echo "PASS: the Phase 1 gate covers Tahoe registration convergence without mutating PlugInKit."

product_identity_test="$project_root/scripts/test-product-identity-verifier.sh"
product_identity_verifier="$project_root/scripts/verify-product-identity.sh"
if [[ ! -x "$product_identity_test" ]] ||
   [[ ! -x "$product_identity_verifier" ]] ||
   ! bash -n "$product_identity_test" "$product_identity_verifier" ||
   ! grep -Fq 'test-product-identity-verifier.sh' "$project_root/scripts/test-phase1.sh"; then
  echo "FAIL: the Phase 1 gate must reject evidence from a different product binary." >&2
  exit 1
fi

echo "PASS: Phase 1 evidence is bound to exact companion and extension identities."

if grep -Fq 'representedView' \
  "$project_root/IdleScreenScreenSaver/IdleScreenScreenSaverViewController.swift" \
  "$project_root/IdleScreenScreenSaver/Private/ScreenSaverPrivate.h"; then
  echo "FAIL: macOS 26 ScreenSaverViewController does not implement representedView." >&2
  exit 1
fi

if grep -Fq 'loadView(forFrame' \
  "$project_root/IdleScreenScreenSaver/IdleScreenScreenSaverViewController.swift" ||
   grep -Fq 'loadViewForFrame' \
  "$project_root/IdleScreenScreenSaver/Private/ScreenSaverPrivate.h"; then
  echo "FAIL: macOS 26 ScreenSaverViewController does not implement loadViewForFrame:isPreview:." >&2
  exit 1
fi

echo "PASS: the extension controller uses selectors implemented by the macOS 26 host runtime."

if ! grep -Fq 'class_getInstanceMethod' "$project_root/IdleScreenSystem/ScreenSaverCompatibility.swift" ||
   ! grep -Fq 'class_getInstanceMethod' "$project_root/IdleScreenScreenSaver/ScreenSaverCompatibility.swift" ||
   ! grep -Fq 'missingSelectorNames' "$project_root/IdleScreenApp/SystemViews.swift"; then
  echo "FAIL: compatibility diagnostics must probe and display required private-runtime selectors." >&2
  exit 1
fi

echo "PASS: compatibility diagnostics cover private runtime classes and selectors."

host_activity_shim="$project_root/IdleScreenScreenSaver/Private/IdleScreenSaverHostActivity.m"
if [[ ! -f "$host_activity_shim" ]] ||
   ! grep -Fq '@try' "$host_activity_shim" ||
   ! grep -Fq 'screenSaverIsRunning' "$host_activity_shim" ||
   ! grep -Fq 'screenSaverIsRunningInBackground' "$host_activity_shim" ||
   grep -Eq 'screenSaver(Start|Stop)' "$host_activity_shim" ||
   ! grep -Fq 'cameraDemand=' "$project_root/IdleScreenScreenSaver/IdleScreenSaverView.swift" ||
   ! grep -Fq 'IdleScreenSaverHostActivity.m' "$project_root/project.yml"; then
  echo "FAIL: Tahoe host-activity diagnostics must be exception-safe, read-only, explicit about camera demand, and test-built." >&2
  exit 1
fi

echo "PASS: Tahoe host activity is a read-only diagnostic and cannot mutate or authorize the saver."

host_lifecycle_test="$project_root/scripts/test-host-lifecycle.sh"
if [[ ! -x "$host_lifecycle_test" ]] ||
   ! bash -n "$host_lifecycle_test" ||
   ! grep -Fq 'ScreenSaverSelectionProbe.swift' "$host_lifecycle_test" ||
   ! grep -Fq 'read-console-lock-state.sh' "$host_lifecycle_test" ||
   ! grep -Fq 'verify-host-lifecycle-log.sh' "$host_lifecycle_test" ||
   ! grep -Fq '/usr/bin/open -a ScreenSaverEngine' "$host_lifecycle_test" ||
   ! grep -Fq '/usr/bin/log stream' "$host_lifecycle_test" ||
   ! grep -Fq 'log_stream_pid' "$host_lifecycle_test" ||
   grep -Fq '/usr/bin/log show' "$host_lifecycle_test"; then
  echo "FAIL: physical host verification must preflight selection and lock state, then require lifecycle logs." >&2
  exit 1
fi

if grep -Eq '(killall|pkill|kill[^\n]*(ScreenSaverEngine|WallpaperAgent|IdleScreenScreenSaver|legacyScreenSaver|IdlescreenHelper))' "$host_lifecycle_test" ||
   grep -Eq '(defaults write|Index\.plist.*(write|replace|insert))' "$host_lifecycle_test"; then
  echo "FAIL: physical host verification must not kill the host or mutate macOS selection state." >&2
  exit 1
fi

echo "PASS: physical host verification preserves selection and the authentication boundary."

host_cycle_matrix="$project_root/scripts/test-host-lifecycle-matrix.sh"
host_cycle_recorder="$project_root/scripts/record-host-lifecycle-matrix-cycle.sh"
idle_lifecycle_test="$project_root/scripts/test-idle-lifecycle.sh"
if ! grep -Fq 'invalidation_timeout_seconds="${3:-0}"' "$host_lifecycle_test" ||
   ! grep -Fq 'minimum_sustain_seconds="${4:-5}"' "$host_lifecycle_test" ||
   ! grep -Fq 'verify-host-lifecycle-cycle-log.sh' "$host_lifecycle_test" ||
   ! grep -Fq '/Applications/idlescreen.app' "$host_lifecycle_test" ||
   ! grep -Fq 'legacyScreenSaver' "$host_lifecycle_test" ||
   ! grep -Fq 'IdlescreenHelper' "$host_lifecycle_test" ||
   ! grep -Fq 'selection changed while the screen saver was running' "$host_lifecycle_test" ||
   ! grep -Fq 'stopped before the sustained-animation gate completed' "$host_lifecycle_test" ||
   ! grep -Fq 'animation_stopped_after_latest_start "$extension_pid"' "$host_lifecycle_test" ||
   ! grep -Fq '! /bin/ps -p "$extension_pid"' "$host_lifecycle_test" ||
   ! grep -Fq 'log_predicate=' "$host_lifecycle_test" ||
   ! grep -Fq 'launchservicesd' "$host_lifecycle_test" ||
   ! grep -Fq 'display slept before normal unlock' "$host_lifecycle_test" ||
   [[ ! -x "$host_cycle_matrix" ]] ||
   ! bash -n "$host_cycle_matrix" ||
   ! grep -Fq 'cycles="${2:-1}"' "$host_cycle_matrix" ||
   ! grep -Fq 'test-host-lifecycle.sh' "$host_cycle_matrix" ||
   ! grep -Fq 'verify-host-lifecycle-matrix-evidence.sh' "$host_cycle_matrix" ||
   ! grep -Fq 'registered_extension_paths' "$host_cycle_matrix" ||
   ! grep -Fq 'extension_process_is_running' "$host_cycle_matrix"; then
  echo "FAIL: repeated host verification must explicitly wait for invalidation and preserve registration state." >&2
  exit 1
fi

if [[ ! -x "$host_cycle_recorder" ]] ||
   ! bash -n "$host_cycle_recorder" ||
   ! grep -Fq 'verify-host-lifecycle-cycle-log.sh' "$host_cycle_recorder" ||
   ! grep -Fq 'verify-host-lifecycle-matrix-evidence.sh' "$host_cycle_recorder"; then
  echo "FAIL: separately authorized host cycles must accumulate through independent evidence verification." >&2
  exit 1
fi

if ! grep -Fq 'IDLESCREEN_ALLOW_PHYSICAL_TESTS' "$host_lifecycle_test" ||
   ! grep -Fq 'IDLESCREEN_ALLOW_PHYSICAL_TESTS' "$host_cycle_matrix" ||
   ! grep -Fq 'IDLESCREEN_ALLOW_PHYSICAL_TESTS' "$idle_lifecycle_test"; then
  echo "FAIL: every focus-changing physical runner must require explicit opt-in." >&2
  exit 1
fi

echo "PASS: physical host runners require explicit focus-changing-test authorization."

if [[ ! -x "$idle_lifecycle_test" ]] ||
   ! bash -n "$idle_lifecycle_test" ||
   ! grep -Fq 'IDLESCREEN_HOST_ACTIVATION=idle' "$idle_lifecycle_test" ||
   ! grep -Fq 'verify-idle-activation-log.sh' "$host_lifecycle_test" ||
   ! grep -Fq 'kLWLockFromScreenSaver' "$host_lifecycle_test" ||
   ! grep -Fq 'activation_mode" == manual || "$activation_mode" == idle' "$host_lifecycle_test" ||
   grep -Fq '/usr/bin/open' "$idle_lifecycle_test"; then
  echo "FAIL: unattended idle verification must wait for macOS activation without launching the saver." >&2
  exit 1
fi

echo "PASS: the idle gate observes macOS activation without launching or reconfiguring it."

physical_state_capture="$project_root/scripts/capture-phase1-physical-state.sh"
physical_state_verifier="$project_root/scripts/verify-phase1-state-transition.sh"
physical_state_verifier_test="$project_root/scripts/test-physical-state-transition.sh"
if [[ ! -x "$physical_state_capture" ]] ||
   ! bash -n "$physical_state_capture" ||
   ! grep -Fq 'SPDisplaysDataType' "$physical_state_capture" ||
   ! grep -Fq 'ScreenSaverSelectionProbe.swift' "$physical_state_capture" ||
   ! grep -Fq 'pluginkit' "$physical_state_capture" ||
   ! grep -Fq 'kern.bootsessionuuid' "$physical_state_capture" ||
   ! grep -Fq 'online-displays.tsv' "$physical_state_capture" ||
   ! grep -Fq 'current-spaces.tsv' "$physical_state_capture" ||
   ! grep -Fq 'power-history.txt' "$physical_state_capture" ||
   ! grep -Fq 'read-console-lock-state.sh' "$physical_state_capture" ||
   ! grep -Fq 'one or more snapshot commands failed' "$physical_state_capture"; then
  echo "FAIL: the physical matrix needs a read-only before/after state recorder." >&2
  exit 1
fi

if grep -Eq '(/usr/bin/open|osascript|killall|pkill|pmset[[:space:]]+(sleepnow|displaysleepnow|schedule|repeat))' "$physical_state_capture"; then
  echo "FAIL: the state recorder must not change focus, processes, power, or UI state." >&2
  exit 1
fi

echo "PASS: physical matrix snapshots are reproducible and read-only."

if [[ ! -x "$physical_state_verifier" ]] ||
   ! bash -n "$physical_state_verifier" ||
   [[ ! -x "$physical_state_verifier_test" ]] ||
   ! bash -n "$physical_state_verifier_test" ||
   ! grep -Fq 'product-sha256.txt' "$physical_state_verifier" ||
   ! grep -Fq 'kern.bootsessionuuid' "$physical_state_capture" ||
   ! grep -Fq 'online-displays.tsv' "$physical_state_verifier" ||
   ! grep -Fq 'current-spaces.tsv' "$physical_state_verifier" ||
   ! grep -Fq 'system-cycle' "$physical_state_verifier" ||
   ! grep -Fq 'display-cycle' "$physical_state_verifier" ||
   ! grep -Fq 'screen-saver or legacy-helper processes remain' "$physical_state_verifier" ||
   ! grep -Fq 'test-physical-state-transition.sh' "$project_root/scripts/test-phase1.sh"; then
  echo "FAIL: disruptive physical rows need a deterministic before/after verifier." >&2
  exit 1
fi

echo "PASS: physical state transitions have deterministic invariant verification."

if ! grep -Fq 'Animation stopped preview=' "$project_root/IdleScreenScreenSaver/IdleScreenSaverView.swift"; then
  echo "FAIL: physical invalidation evidence must identify the preview or full-screen surface." >&2
  exit 1
fi

if ! grep -Fq 'NSWindow.didChangeScreenNotification' "$project_root/IdleScreenScreenSaver/IdleScreenSaverView.swift" ||
   ! grep -Fq 'CGDisplayBounds' "$project_root/IdleScreenScreenSaver/IdleScreenSaverView.swift"; then
  echo "FAIL: display identity must be resolved after Tahoe migrates each hosted saver window off the main display." >&2
  exit 1
fi

if ! grep -Fq 'instanceIdentifier' "$project_root/IdleScreenCore/Health.swift" ||
   ! grep -Fq 'displayIdentifier' "$project_root/IdleScreenCore/Health.swift" ||
   ! grep -Fq 'instanceIdentifier: instanceIdentifier' "$project_root/IdleScreenScreenSaver/IdleScreenSaverView.swift" ||
   ! grep -Fq 'displayIdentifier: displayIdentifier' "$project_root/IdleScreenScreenSaver/IdleScreenSaverView.swift" ||
   ! grep -Fq 'Display \(displayIdentifier)' "$project_root/IdleScreenApp/SystemViews.swift" ||
   ! grep -Fq 'IdleScreenHealthSelection.preferredReport' "$project_root/IdleScreenApp/IdleScreenAppModel.swift" ||
   [[ ! -x "$project_root/scripts/verify-multidisplay-lifecycle-log.sh" ]] ||
   ! bash -n "$project_root/scripts/verify-multidisplay-lifecycle-log.sh" ||
   ! grep -Fq 'independent hosted-view lifecycle' "$project_root/scripts/verify-multidisplay-lifecycle-log.sh" ||
   ! grep -Fq 'IDLESCREEN_MINIMUM_DISPLAY_SUSTAIN_SECONDS' "$project_root/scripts/verify-multidisplay-lifecycle-log.sh" ||
   ! grep -Fq "grep -F 'IdleScreenScreenSaver['" "$project_root/scripts/verify-host-lifecycle-log.sh" ||
   ! grep -Fq 'process_prefix="IdleScreenScreenSaver[$extension_pid:' "$project_root/scripts/verify-host-lifecycle-cycle-log.sh"; then
  echo "FAIL: concurrent display views must have independent health and same-process lifecycle evidence." >&2
  exit 1
fi

echo "PASS: concurrent display views publish independent, PID-correlated lifecycle evidence."

echo "PASS: repeated physical host cycles are explicit, invalidation-aware, and registration-preserving."

if ! grep -Fq 'IdleScreenConfigurationMonitor' "$project_root/IdleScreenScreenSaver/IdleScreenSaverView.swift" ||
   ! grep -Fq 'refreshConfiguration(at:' "$project_root/IdleScreenScreenSaver/IdleScreenSaverView.swift" ||
   ! grep -Fq 'configurationRevision: configuration.revision' "$project_root/IdleScreenScreenSaver/IdleScreenSaverView.swift" ||
   ! grep -Fq 'configurationRevision: configuration.revision' "$project_root/IdleScreenApp/IdleScreenAppModel.swift" ||
   ! grep -Fq 'report.configurationRevision' "$project_root/IdleScreenApp/SystemViews.swift"; then
  echo "FAIL: running configuration delivery must be revision-monitored and visible in per-instance health." >&2
  exit 1
fi

echo "PASS: running configuration delivery publishes an observable per-instance revision."

if ! grep -Fq 'isProcessReportLive' "$project_root/IdleScreenApp/IdleScreenAppModel.swift" ||
   ! grep -Fq 'proc_pidpath' "$project_root/IdleScreenApp/IdleScreenAppModel.swift" ||
   ! grep -Fq 'matchesExecutablePath' "$project_root/IdleScreenCore/Health.swift" ||
   ! grep -Fq 'isLive: model.isProcessReportLive(report)' "$project_root/IdleScreenApp/SystemViews.swift" ||
   ! grep -Fq 'Text(isLive ? report.lifecycle.rawValue.capitalized : "Exited")' "$project_root/IdleScreenApp/SystemViews.swift" ||
   ! grep -Fq 'wrong executable identity' "$project_root/scripts/verify-shared-state.sh"; then
  echo "FAIL: companion diagnostics must not present exited process reports as live." >&2
  exit 1
fi

echo "PASS: companion diagnostics distinguish live process health from stale files."

if ! grep -Fq './scripts/test-host-lifecycle-log.sh' "$project_root/scripts/test-phase1.sh" ||
   ! grep -Fq './scripts/test-selection-probe.sh' "$project_root/scripts/test-phase1.sh"; then
  echo "FAIL: the Phase 1 gate must run deterministic host-log and live-selection probe tests." >&2
  exit 1
fi

echo "PASS: deterministic physical-host support tests run in the complete Phase 1 gate."

if ! grep -Fq 'launch_cycles="${1:-1}"' "$project_root/scripts/test-phase1.sh" ||
   ! grep -Fq 'launch_cycles="${2:-1}"' "$project_root/scripts/test-modern-product.sh" ||
   ! grep -Fq '/usr/bin/open -g -j -n' "$project_root/scripts/test-modern-product.sh"; then
  echo "FAIL: routine verification must run one background companion launch unless repeated UI cycles are explicit." >&2
  exit 1
fi

echo "PASS: repeated visible companion launch cycles require explicit opt-in."

if ! grep -Fq 'wait_for_registered_extension_paths' "$project_root/scripts/test-modern-product.sh" ||
   ! grep -Fq 'wait_for_selected_extension_path' "$project_root/scripts/test-phase1.sh"; then
  echo "FAIL: physical registration and restoration must wait for asynchronous pluginkit state." >&2
  exit 1
fi

echo "PASS: product gates wait for asynchronous pluginkit registration before asserting paths."

extension_tests_target_block="$({
  awk '
    /^targets:$/ { in_targets = 1; next }
    in_targets && /^  IdleScreenScreenSaverTests:$/ { in_extension_tests = 1; next }
    in_extension_tests && /^  [[:alnum:]_]+:$/ { exit }
    in_extension_tests { print }
  ' "$project_file"
})"

if ! grep -Fq 'type: bundle.unit-test' <<<"$extension_tests_target_block" ||
   ! grep -Fq 'path: IdleScreenScreenSaver/IdleScreenSaverView.swift' <<<"$extension_tests_target_block" ||
   ! grep -Fq 'target: IdleScreenCore' <<<"$extension_tests_target_block"; then
  echo "FAIL: the production saver view must have a dedicated lifecycle/render test target." >&2
  exit 1
fi

echo "PASS: the production saver view has an isolated lifecycle/render test target."

extension_info="$project_root/IdleScreenScreenSaver/Info.plist"
extension_entitlements="$project_root/IdleScreenScreenSaver/IdleScreenScreenSaver.entitlements"

if [[ "$(plutil -extract NSExtension.NSExtensionPointIdentifier raw "$extension_info")" != "com.apple.screensaver" ]] ||
   [[ "$(plutil -extract NSExtension.NSExtensionPointVersion raw "$extension_info")" != "1.0" ]] ||
   [[ "$(plutil -extract CFBundlePackageType raw "$extension_info")" != "XPC!" ]]; then
  echo "FAIL: IdleScreenScreenSaver must declare the modern screen-saver extension point." >&2
  exit 1
fi

if [[ "$(plutil -extract SSEHasConfigureSheet raw "$extension_info")" != "true" ]] ||
   [[ "$(plutil -extract SSENeedsAnimationTimer raw "$extension_info")" != "true" ]]; then
  echo "FAIL: The screen-saver extension must expose its configuration sheet and remain host-timer driven." >&2
  exit 1
fi

for mach_service in com.apple.CARenderServer com.apple.CoreDisplay.master com.apple.ViewBridgeAuxiliary; do
  if ! plutil -convert json -o - "$extension_entitlements" | grep -Fq "$mach_service"; then
    echo "FAIL: IdleScreenScreenSaver is missing required host service $mach_service." >&2
    exit 1
  fi
done

echo "PASS: The extension plist and sandbox boundary match the Phase 1 host contract."

thumbnail_1x="$project_root/IdleScreenScreenSaver/Assets.xcassets/thumbnail.imageset/thumbnail.png"
thumbnail_2x="$project_root/IdleScreenScreenSaver/Assets.xcassets/thumbnail.imageset/thumbnail@2x.png"

if [[ ! -f "$thumbnail_1x" || ! -f "$thumbnail_2x" ]] ||
   [[ "$(sips -g pixelWidth "$thumbnail_1x" | awk '/pixelWidth/ { print $2 }')" != "107" ]] ||
   [[ "$(sips -g pixelHeight "$thumbnail_1x" | awk '/pixelHeight/ { print $2 }')" != "65" ]] ||
   [[ "$(sips -g pixelWidth "$thumbnail_2x" | awk '/pixelWidth/ { print $2 }')" != "214" ]] ||
   [[ "$(sips -g pixelHeight "$thumbnail_2x" | awk '/pixelHeight/ { print $2 }')" != "130" ]]; then
  echo "FAIL: System Settings thumbnails must be 107x65 and 214x130 pixels." >&2
  exit 1
fi

echo "PASS: the modern System Settings thumbnail has both required scales."

if ! awk '
  /^  IdleScreenApp:$/ { in_app = 1 }
  in_app && /^      - target: IdleScreenScreenSaver$/ { found_target = 1; next }
  found_target && /^        embed: true$/ { found_embed = 1 }
  in_app && /^  [[:alnum:]_]+:$/ && $1 != "IdleScreenApp:" { exit }
  END { exit !(found_target && found_embed) }
' "$project_file"; then
  echo "FAIL: IdleScreenApp must embed IdleScreenScreenSaver explicitly." >&2
  exit 1
fi

for shared_target in IdleScreenCore IdleScreenDisplay; do
  if ! grep -Fq "target: $shared_target" <<<"$companion_target_block" ||
     ! grep -Fq "target: $shared_target" <<<"$extension_target_block"; then
    echo "FAIL: The companion and extension must both depend on $shared_target." >&2
    exit 1
  fi

  for target_name in IdleScreenApp IdleScreenScreenSaver; do
    if ! awk -v target_name="$target_name" -v shared_target="$shared_target" '
    /^targets:$/ { in_targets = 1; next }
    in_targets && $0 == "  " target_name ":" { in_target = 1 }
    in_target && $0 == "      - target: " shared_target { found_target = 1; next }
    found_target && /^        embed: false$/ { found_no_embed = 1 }
    in_target && /^  [[:alnum:]_]+:$/ && $1 != target_name ":" { exit }
    END { exit !(found_target && found_no_embed) }
  ' "$project_file"; then
      echo "FAIL: $target_name must link, but not embed, the static $shared_target archive." >&2
      exit 1
    fi
  done
done

echo "PASS: IdleScreenApp embeds the extension and both hosts share Core and display observation."

materials_configuration="$project_root/IdleScreenCore/PixelMaterialsConfiguration.swift"
materials_reference="$project_root/IdleScreenRenderer/PixelMaterialsReference.swift"
materials_coordinator="$project_root/IdleScreenRenderer/PixelMaterialsSceneCoordinator.swift"
materials_bridge="IdleScreenProduct/RendererConfigurationBridge.swift"
materials_shader="$project_root/IdleScreenRenderer/IdleScreenRendererShaders.metal"

if [[ ! -f "$materials_configuration" ||
      ! -f "$materials_reference" ||
      ! -f "$materials_coordinator" ]] ||
   ! grep -Fq 'case pixelMaterials' "$project_root/IdleScreenCore/CreativeConfiguration.swift" ||
   ! grep -Fq 'idleScreenPixelMaterialInstances' "$materials_shader"; then
  echo "FAIL: Pixel Materials requires versioned Core controls, a renderer-owned oracle/coordinator, and its Metal compute entry point." >&2
  exit 1
fi

for target_name in IdleScreenApp IdleScreenScreenSaver IdleScreenAppCompileGateTests IdleScreenScreenSaverTests; do
  target_block="$({
    awk -v target_name="$target_name" '
      /^targets:$/ { in_targets = 1; next }
      in_targets && $0 == "  " target_name ":" { in_target = 1 }
      in_target && /^  [[:alnum:]_]+:$/ && $1 != target_name ":" { exit }
      in_target { print }
    ' "$project_file"
  })"
  if ! grep -Fq "path: $materials_bridge" <<<"$target_block"; then
    echo "FAIL: $target_name must compile the one shared Core-to-renderer configuration bridge." >&2
    exit 1
  fi
done

if grep -RqsE '(IdleScreenCamera|AVFoundation|AVCapture)' \
  "$materials_reference" "$materials_coordinator"; then
  echo "FAIL: Pixel Materials must remain camera-independent and renderer-owned." >&2
  exit 1
fi

echo "PASS: Pixel Materials shares one versioned product bridge, deterministic oracle/coordinator, bounded Metal compute path, and no camera dependency."

c4_evidence_verifier="$project_root/scripts/verify-camera-gate-c4-evidence.py"
c4_evidence_fixtures="$project_root/scripts/test-camera-gate-c4-evidence-fixtures.py"
if [[ ! -x "$c4_evidence_verifier" || ! -x "$c4_evidence_fixtures" ]]; then
  echo "FAIL: C4 requires an executable aggregate evidence verifier and deterministic fixture matrix." >&2
  exit 1
fi
for c4_contract in \
  'IdleScreenC4GateBinding/v1' \
  'IdleScreenC4ProductionInstall/v1' \
  'restored_production_tree_inventory' \
  'IdleScreenCameraGateC4RuntimeEntitlementsV1' \
  'marker_processes_absent' \
  'a1.verify(mode'; do
  if ! grep -Fq "$c4_contract" "$c4_evidence_verifier"; then
    echo "FAIL: C4 aggregate verification is missing contract $c4_contract." >&2
    exit 1
  fi
done
"$c4_evidence_fixtures" >/dev/null || {
  echo "FAIL: deterministic C4 evidence fixtures failed." >&2
  exit 1
}

echo "PASS: C4 evidence is bound from exact C3 install trees through ordered A1T/A1TR restoration."

r1_builder="$project_root/scripts/build-r1-release-candidate.sh"
r1_verifier="$project_root/scripts/verify-r1-release-candidate.sh"
r1_fixtures="$project_root/scripts/test-r1-release-candidate-fixtures.sh"
r1_common="$project_root/scripts/r1-release-candidate-common.sh"
for r1_script in "$r1_builder" "$r1_verifier" "$r1_fixtures"; do
  if [[ ! -x "$r1_script" ]]; then
    echo "FAIL: R1.2a requires executable release-candidate entry points." >&2
    exit 1
  fi
done
for r1_script in "$r1_builder" "$r1_verifier" "$r1_fixtures" "$r1_common"; do
  if ! bash -n "$r1_script"; then
    echo "FAIL: R1.2a release-candidate scripts must parse." >&2
    exit 1
  fi
done

if [[ "$(grep -Fc './scripts/test-r1-release-candidate-fixtures.sh' "$ci_workflow" || true)" -ne 1 ]]; then
  echo "FAIL: CI must run the R1.2a fixture matrix exactly once." >&2
  exit 1
fi

for r1_entitlements in \
  "$project_root/IdleScreenApp/IdleScreenDeveloperID.entitlements" \
  "$project_root/IdleScreenScreenSaver/IdleScreenScreenSaverDeveloperID.entitlements" \
  "$project_root/IdleScreenCameraAgent/IdleScreenCameraAgentDeveloperID.entitlements" \
  "$project_root/IdleScreenAgentExecutable/idlescreenctl-DeveloperID.entitlements"; do
  if ! plutil -lint "$r1_entitlements" >/dev/null; then
    echo "FAIL: R1.2a Developer ID entitlements must be explicit valid plists." >&2
    exit 1
  fi
done

r1_renderer_sign_line="$(grep -nF 'sign_product "$distribution_renderer"' "$r1_builder" | head -1 | cut -d: -f1)"
r1_extension_sign_line="$(grep -nF 'sign_product "$distribution_extension"' "$r1_builder" | head -1 | cut -d: -f1)"
r1_helper_sign_line="$(grep -nF 'sign_product "$distribution_helper"' "$r1_builder" | head -1 | cut -d: -f1)"
r1_control_sign_line="$(grep -nF 'sign_product "$distribution_control_tool"' "$r1_builder" | head -1 | cut -d: -f1)"
r1_app_sign_line="$(grep -nF 'sign_product "$distribution_app"' "$r1_builder" | head -1 | cut -d: -f1)"
if ! grep -Fq 'IDLESCREEN_ALLOW_REAL_DISTRIBUTION:-' "$r1_builder" ||
   ! grep -Fq 'build-camera-gate-c3-release.sh' "$r1_builder" ||
   ! grep -Fq 'verify-release-archive-provenance.sh' "$r1_builder" ||
   ! grep -Fq 'IDLESCREEN_ALLOW_SIGNING_CREDENTIAL_UPDATES=NO' "$r1_builder" ||
   ! grep -Fq 'forbids inherited nested C3 provenance command overrides' "$r1_builder" ||
   ! grep -Fq 'distribution_app="$distribution_stage/IdleScreen.app"' "$r1_builder" ||
   ! grep -Fq 'IdleScreenReleaseProvenance.plist' "$r1_builder" ||
   ! grep -Fq 'BuildEnvironmentSHA256' "$r1_builder" ||
   ! grep -Fq 'greater than baseline build 60' "$r1_builder" ||
   ! grep -Fq "'.sha256 // empty'" "$r1_builder" ||
   ! grep -Fq 'local arguments=(--force --sign "$identity_sha1" --timestamp --options runtime)' "$r1_builder" ||
   ! grep -Fq '"$codesign_command" --force --sign "$identity_sha1" --timestamp' "$r1_builder" ||
   grep -Fq 'arguments+=(--deep)' "$r1_builder" ||
   ! grep -Fq '/usr/bin/xattr -px' "$r1_common" ||
   ! grep -Fq '/bin/realpath "$candidate"' "$r1_common" ||
   ! grep -Fq 'IDLESCREEN_NOTARY_KEYCHAIN_PROFILE' "$r1_builder" ||
   ! grep -Fq 'create -srcfolder "$package_root" -format UDZO' "$r1_builder" ||
   ! grep -Fq 'staple "$dmg_path"' "$r1_builder" ||
   ! grep -Fq 'context:primary-signature' "$r1_verifier" ||
   ! grep -Fq -- '-a -t exec -vv "$mounted_app"' "$r1_verifier" ||
   grep -Eq 'store-credentials|--apple-id|--password' "$r1_builder" ||
   [[ ! "$r1_renderer_sign_line" =~ ^[1-9][0-9]*$ ]] ||
   [[ ! "$r1_extension_sign_line" =~ ^[1-9][0-9]*$ ]] ||
   [[ ! "$r1_helper_sign_line" =~ ^[1-9][0-9]*$ ]] ||
   [[ ! "$r1_control_sign_line" =~ ^[1-9][0-9]*$ ]] ||
   [[ ! "$r1_app_sign_line" =~ ^[1-9][0-9]*$ ]] ||
   ((r1_renderer_sign_line >= r1_extension_sign_line)) ||
   ((r1_extension_sign_line >= r1_helper_sign_line)) ||
   ((r1_helper_sign_line >= r1_control_sign_line)) ||
   ((r1_control_sign_line >= r1_app_sign_line)); then
  echo "FAIL: R1.2a must freeze C3 provenance, sign inside-out, use a keychain profile, and verify the final UDZO DMG fail closed." >&2
  exit 1
fi

echo "PASS: R1.2a has one consent-gated, provenance-bound, fixture-tested Developer ID signing, notarization, stapling, and Gatekeeper authority."
