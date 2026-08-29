#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
project_file="$project_root/project.yml"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

target_block() {
  local target="$1"
  awk -v header="  $target:" '
    /^targets:$/ { in_targets = 1; next }
    in_targets && $0 == header { in_target = 1; next }
    in_target && /^  [[:alnum:]_]+:$/ { exit }
    in_target { print }
  ' "$project_file"
}

scheme_block() {
  local scheme="$1"
  awk -v header="  $scheme:" '
    /^schemes:$/ { in_schemes = 1; next }
    /^targets:$/ { exit }
    in_schemes && $0 == header { in_scheme = 1; next }
    in_scheme && /^  [[:alnum:]_]+:$/ { exit }
    in_scheme { print }
  ' "$project_file"
}

source_excludes() {
  local target="$1"
  local source_path="$2"
  awk -v header="      - path: $source_path" '
    $0 == header { in_source = 1; next }
    in_source && /^      - path:/ { exit }
    in_source && $0 == "        excludes:" { in_excludes = 1; next }
    in_excludes && /^          - / {
      value = $0
      sub(/^          - /, "", value)
      print value
      next
    }
    in_excludes { exit }
  ' <<<"$target"
}

production_core="$(target_block IdleScreenCameraAgentCore)"
synthetic_core="$(target_block IdleScreenCameraSyntheticAgentCore)"
synthetic_helper="$(target_block IdleScreenCameraSyntheticAgent)"
synthetic_extension="$(target_block IdleScreenSyntheticHostedGateExtension)"
synthetic_app="$(target_block IdleScreenSyntheticGateApp)"
production_app="$(target_block IdleScreenApp)"
production_extension="$(target_block IdleScreenScreenSaver)"
production_scheme="$(scheme_block IdleScreenApp)"
synthetic_scheme="$(scheme_block IdleScreenSyntheticGate)"
synthetic_helper_archive_scheme="$(scheme_block IdleScreenCameraSyntheticAgentArchive)"
synthetic_extension_archive_scheme="$(scheme_block IdleScreenSyntheticHostedGateExtensionArchive)"

for neutral_source in \
  CameraAgentService.swift \
  CameraAgentDiagnostics.swift \
  CameraCaptureSessionController.swift \
  CameraFrameMailboxWriter.swift \
  CameraAgentXPCListener.swift \
  CameraAgentRuntimeDriver.swift \
  CameraAgentProcessRuntime.swift \
  CameraDeviceInventory.swift; do
  grep -Fq "Sources/IdleScreenCameraAgent/$neutral_source" <<<"$production_core" ||
    fail "production core does not compile neutral source $neutral_source"
  grep -Fq "Sources/IdleScreenCameraAgent/$neutral_source" <<<"$synthetic_core" ||
    fail "synthetic core does not reuse neutral production source $neutral_source"
done

for production_source in \
  AVFoundationCameraCaptureComposition.swift \
  AVFoundationCameraAgentComposition.swift \
  AVFoundationCameraDeviceInventory.swift; do
  grep -Fq "Sources/IdleScreenCameraAgent/$production_source" <<<"$production_core" ||
    fail "production core does not explicitly compile $production_source"
  if grep -Fq "$production_source" <<<"$synthetic_core"; then
    fail "synthetic core compiles production-only source $production_source"
  fi
done

for neutral_path in \
  "$project_root/Sources/IdleScreenCameraAgent/CameraCaptureSessionController.swift" \
  "$project_root/Sources/IdleScreenCameraAgent/CameraAgentRuntimeDriver.swift" \
  "$project_root/Sources/IdleScreenCameraAgent/CameraAgentProcessRuntime.swift"; do
  if grep -Eq '(import AVFoundation|AVCapture|requestAccess\(|AVFoundationErrorDomain|IdleScreenSyntheticGate)' \
    "$neutral_path"; then
    fail "neutral production runtime still owns AVFoundation or a synthetic switch: $neutral_path"
  fi
done

[[ -n "$synthetic_core" && -n "$synthetic_helper" && -n "$synthetic_extension" && -n "$synthetic_app" ]] ||
  fail "synthetic gate targets are missing"
grep -Fq 'path: Support/IdleScreenSyntheticGate' <<<"$synthetic_core" ||
  fail "synthetic core has no separate gate-only composition"
grep -Fq 'IdleScreenSyntheticGateVersion: "1"' <<<"$synthetic_helper" ||
  fail "synthetic helper lacks the unmistakable version-1 marker"
grep -Fq 'target: IdleScreenCameraSyntheticAgentCore' <<<"$synthetic_helper" ||
  fail "synthetic helper does not use the synthetic composition"
grep -Fq 'CODE_SIGN_ENTITLEMENTS: Support/IdleScreenSyntheticGate/IdleScreenCameraSyntheticAgent.entitlements' \
  <<<"$synthetic_helper" || fail "synthetic helper has no dedicated camera-free entitlement file"
grep -Fq 'aggregateTargets:' "$project_file" ||
  fail "gate product must compose archived products rather than recompile the outer app"
grep -Fq 'target: IdleScreenCameraSyntheticAgent' <<<"$synthetic_app" ||
  fail "gate aggregate does not include the synthetic helper"
grep -Fq 'target: IdleScreenApp' <<<"$synthetic_app" ||
  fail "gate aggregate does not reuse the production app, extension, and LaunchAgent graph"
grep -Fq 'target: IdleScreenSyntheticHostedGateExtension' <<<"$synthetic_app" ||
  fail "gate aggregate does not archive the isolated hosted-gate extension"

grep -Fq 'path: Products/IdleScreenScreenSaver' <<<"$synthetic_extension" ||
  fail "hosted-gate extension does not reuse the production saver view/client/core sources"
grep -Fq 'IdleScreenScreenSaverViewController.swift' <<<"$synthetic_extension" ||
  fail "hosted-gate extension does not explicitly exclude the shipping principal controller"
grep -Fq 'path: Support/IdleScreenSyntheticHostedGateExtension' <<<"$synthetic_extension" ||
  fail "hosted-gate extension has no separate gate-only principal-controller source"
grep -Fq 'IdleScreenSyntheticHostedGateVersion: "1"' <<<"$synthetic_extension" ||
  fail "hosted-gate extension lacks the unmistakable version-1 marker"
grep -Fq 'ScreenSaverViewControllerClass: $(PRODUCT_MODULE_NAME).IdleScreenSyntheticHostedGateViewController' \
  <<<"$synthetic_extension" || fail "hosted-gate extension does not select the gate-only controller"
grep -Fq 'PRODUCT_NAME: IdleScreenScreenSaver' <<<"$synthetic_extension" ||
  fail "hosted-gate extension does not preserve the production extension product path"
grep -Fq 'PRODUCT_MODULE_NAME: IdleScreenScreenSaver' <<<"$synthetic_extension" ||
  fail "hosted-gate extension does not preserve the production extension module identity"
for tuple_value in \
  'PRODUCT_BUNDLE_IDENTIFIER: com.idlescreen.app.screensaver' \
  'IDLESCREEN_APP_GROUP_IDENTIFIER: group.com.idlescreen.shared' \
  'IDLESCREEN_CAMERA_AGENT_MACH_SERVICE_NAME: group.com.idlescreen.shared.camera-agent' \
  'DEVELOPMENT_TEAM: 3524374A2S' \
  'NSExtensionPointIdentifier: com.apple.screensaver'; do
  grep -Fq "$tuple_value" <<<"$synthetic_extension" ||
    fail "hosted-gate extension does not preserve Release tuple value: $tuple_value"
done

expected_production_source_excludes="$({
  printf '%s\n' \
    IdleScreenScreenSaver-Debug.entitlements \
    IdleScreenScreenSaver.entitlements \
    IdleScreenScreenSaverViewController.swift \
    Info.plist
} | LC_ALL=C /usr/bin/sort)"
actual_production_source_excludes="$(source_excludes "$synthetic_extension" Products/IdleScreenScreenSaver | LC_ALL=C /usr/bin/sort)"
[[ "$actual_production_source_excludes" == "$expected_production_source_excludes" ]] ||
  fail "hosted-gate extension must use the exact production-source exclude set"
[[ "$(source_excludes "$synthetic_extension" Support/IdleScreenSyntheticHostedGateExtension)" == Info.plist ]] ||
  fail "hosted-gate source path may exclude only its Info.plist"
grep -Fq 'path: Products/IdleScreenScreenSaver' <<<"$production_extension" ||
  fail "production extension no longer resolves the canonical saver source directory"
while IFS= read -r production_source; do
  [[ -n "$production_source" ]] || continue
  relative_source="${production_source#"$project_root/Products/IdleScreenScreenSaver/"}"
  [[ "$relative_source" == IdleScreenScreenSaverViewController.swift ]] && continue
  if grep -Fxq "$relative_source" <<<"$actual_production_source_excludes"; then
    fail "hosted gate excludes resolved production saver/client source: $relative_source"
  fi
done < <(/usr/bin/find "$project_root/Products/IdleScreenScreenSaver" -type f \
  \( -name '*.swift' -o -name '*.m' -o -name '*.h' \) | LC_ALL=C /usr/bin/sort)

gate_controller="$project_root/Support/IdleScreenSyntheticHostedGateExtension/IdleScreenSyntheticHostedGateViewController.swift"
[[ -f "$gate_controller" ]] || fail "gate-only hosted principal controller source is missing"
grep -Fq 'cameraHostContext: .explicitlyVerifiedFullScreen' "$gate_controller" ||
  fail "gate-only hosted controller does not inject explicit full-screen test provenance"
grep -Fq 'diagnosticState.instanceIdentifier' "$gate_controller" ||
  fail "gate-only hosted controller does not bind its topology marker to the saver instance"
grep -Fq 'instance=\(instanceIdentifier, privacy: .public)' "$gate_controller" ||
  fail "gate-only hosted controller log omits the saver instance identifier"
for preflight_contract in \
  CameraAgentControlClient \
  diagnosticSnapshot \
  'matches(remoteProcessIdentifier:' \
  'activeLeaseCount == 0' \
  '!snapshot.captureActive' \
  'Synthetic hosted gate preflight helper_pid='; do
  grep -Fq "$preflight_contract" "$gate_controller" ||
    fail "gate-only hosted controller lacks authenticated idle preflight: $preflight_contract"
done
preflight_log_line="$(grep -nF 'Synthetic hosted gate preflight helper_pid=' "$gate_controller" | head -1 | cut -d: -f1)"
topology_log_line="$(grep -nF 'Synthetic hosted gate loaded topology-equivalent=true' "$gate_controller" | head -1 | cut -d: -f1)"
[[ "$preflight_log_line" =~ ^[1-9][0-9]*$ &&
   "$topology_log_line" =~ ^[1-9][0-9]*$ &&
   "$preflight_log_line" -lt "$topology_log_line" ]] ||
  fail "authenticated idle preflight marker must precede the topology marker"
if grep -Fq 'explicitlyVerifiedFullScreen' \
  "$project_root/Products/IdleScreenScreenSaver/IdleScreenScreenSaverViewController.swift"; then
  fail "shipping principal controller gained a hosted-gate capability"
fi
saver_view="$project_root/Products/IdleScreenScreenSaver/IdleScreenSaverView.swift"
if grep -Fq 'return configuration.source == .camera' "$saver_view"; then
  fail "the shipping saver bypasses the generated activation decision"
fi
grep -Fq 'IdleScreenC7GeneratedActivationDecision.input' "$saver_view" ||
  fail "the shipping saver does not consume the generated activation decision"
grep -Fq 'IdleScreenShippingSaverCameraDemandPolicy' "$saver_view" ||
  fail "the shipping saver does not evaluate the generated activation policy"
[[ "$(grep -Fc 'return IdleScreenSaverShippingCameraDemand.permitsCamera(' "$saver_view")" == 1 ]] ||
  fail "the shipping demand branch does not call the generated-policy helper exactly once"
[[ "$(grep -Fc 'syntheticCameraHostContext = cameraHostContext' "$saver_view")" == 1 ]] ||
  fail "the synthetic initializer must keep its explicit target-gated host context"
grep -Fq 'IDLESCREEN_SYNTHETIC_HOSTED_GATE' <<<"$synthetic_extension" ||
  fail "synthetic hosted-gate capability is not target-gated"
if grep -Fq 'IDLESCREEN_SYNTHETIC_HOSTED_GATE' <<<"$production_extension"; then
  fail "shipping screen saver target can compile the synthetic hosted-gate seam"
fi

if grep -Eq '(AVFoundation|com\.apple\.security\.device\.camera|NSCameraUsageDescription)' \
  <<<"$synthetic_core$synthetic_helper$synthetic_extension"; then
  fail "synthetic helper or hosted-gate extension target carries camera linkage, entitlement, or purpose text"
fi
if rg -n '(import AVFoundation|AVCapture|requestAccess\(|NSCameraUsageDescription|com\.apple\.security\.device\.camera)' \
  "$project_root/Support/IdleScreenSyntheticGate" \
  "$project_root/Support/IdleScreenSyntheticHostedGateExtension" >/dev/null; then
  fail "gate-only sources contain a camera API, purpose string, or entitlement"
fi

if grep -Eq 'SyntheticHostedGate|IdleScreenSyntheticGateVersion|IdleScreenSyntheticHostedGateVersion' \
  <<<"$production_app$production_extension$production_scheme"; then
  fail "normal IdleScreenApp build graph contains a synthetic target"
fi
grep -Fq 'IdleScreenSyntheticGateApp' <<<"$synthetic_scheme" ||
  fail "synthetic scheme does not isolate the gate app"
grep -Fq 'IdleScreenCameraSyntheticAgentArchiveProduct: [archive]' <<<"$synthetic_helper_archive_scheme" ||
  fail "synthetic helper archive scheme is not archive-only"
grep -Fq 'IdleScreenCameraSyntheticAgent: [archive]' <<<"$synthetic_helper_archive_scheme" ||
  fail "synthetic helper product is not explicitly archived"
grep -Fq 'IdleScreenSyntheticHostedGateExtensionArchiveProduct: [archive]' \
  <<<"$synthetic_extension_archive_scheme" ||
  fail "synthetic hosted-gate extension archive scheme is not archive-only"
grep -Fq 'IdleScreenSyntheticHostedGateExtension: [archive]' \
  <<<"$synthetic_extension_archive_scheme" ||
  fail "synthetic hosted-gate extension product is not explicitly archived"
for archive_scheme in IdleScreenSyntheticGate IdleScreenCameraSyntheticAgentArchive IdleScreenSyntheticHostedGateExtensionArchive; do
  gate_scheme_file="$project_root/IdleScreen.xcodeproj/xcshareddata/xcschemes/$archive_scheme.xcscheme"
  [[ -f "$gate_scheme_file" ]] || fail "generated archive-only scheme is missing: $archive_scheme"
  if grep -Fq 'buildForRunning = "YES"' "$gate_scheme_file"; then
    fail "$archive_scheme exposes a runnable Debug build action"
  fi
  if awk '/<LaunchAction/{ in_launch=1 } /<\/LaunchAction>/{ in_launch=0 } in_launch' \
    "$gate_scheme_file" | grep -Eq 'BuildableProductRunnable|Runnable runnableDebuggingMode'; then
    fail "$archive_scheme exposes a runnable LaunchAction"
  fi
done

for shipping_source in \
  "$project_root/Sources/IdleScreenCamera" \
  "$project_root/Sources/IdleScreenCameraAgent" \
  "$project_root/Products/IdleScreenCameraAgentExecutable" \
  "$project_root/Products/IdleScreenApp" \
  "$project_root/Products/IdleScreenScreenSaver"; do
  if rg -n 'IdleScreenSyntheticGateVersion|SyntheticGateVersion|SyntheticHostedGate|SyntheticCamera' \
    "$shipping_source" >/dev/null; then
    fail "shipping source contains a synthetic marker, type, or switch: $shipping_source"
  fi
done

production_product_verifier="$project_root/scripts/test-camera-agent-product.sh"
gate_product_verifier="$project_root/scripts/test-synthetic-gate-product.sh"
gate_manifest_tool="$project_root/scripts/create-synthetic-gate-manifest.sh"
production_installer="$project_root/scripts/install-phase1-release.sh"
gate_installer="$project_root/scripts/install-phase1-synthetic-gate.sh"
gate_builder="$project_root/scripts/build-synthetic-gate-archive.sh"
gate_physical_runner="$project_root/scripts/run-camera-gate-a1.sh"
gate_evidence_verifier="$project_root/scripts/verify-camera-gate-a1-log.sh"
gate_runner_fixtures="$project_root/scripts/test-camera-gate-a1-runner.sh"
gate_process_guard="$project_root/scripts/camera-gate-owned-process.sh"
gate_transaction_library="$project_root/scripts/lib/synthetic-gate-transaction.sh"
gate_transaction_fixtures="$project_root/scripts/test-synthetic-gate-transaction.sh"

for script in \
  "$production_product_verifier" \
  "$gate_product_verifier" \
  "$gate_manifest_tool" \
  "$production_installer" \
  "$gate_installer" \
  "$gate_builder" \
  "$gate_physical_runner" \
  "$gate_evidence_verifier" \
  "$gate_runner_fixtures" \
  "$gate_process_guard" \
  "$gate_transaction_fixtures"; do
  [[ -x "$script" ]] && bash -n "$script" || fail "missing or invalid gate script: $script"
done
[[ -f "$gate_transaction_library" ]] && bash -n "$gate_transaction_library" ||
  fail "missing or invalid synthetic transaction library"

grep -Fq 'IdleScreenSyntheticGateVersion' "$production_product_verifier" ||
  fail "production product verifier does not reject the gate marker"
grep -Fq 'IdleScreenSyntheticHostedGateVersion' "$production_product_verifier" ||
  fail "production product verifier does not reject the hosted-gate extension marker"
grep -Fq 'IdleScreenSyntheticHostedGateViewController' "$production_product_verifier" ||
  fail "production product verifier does not reject the hosted-gate controller symbol"
grep -Fq 'AVFoundation' "$production_product_verifier" ||
  fail "production product verifier does not reject camera linkage outside the helper"
grep -Fq 'enumerate_macho_relative_paths' "$production_product_verifier" ||
  fail "production product verifier does not recursively inventory Mach-O code"
grep -Fq 'IdleScreenSyntheticGateVersion' "$gate_product_verifier" ||
  fail "gate product verifier does not require the gate marker"
grep -Fq 'IdleScreenSyntheticHostedGateVersion' "$gate_product_verifier" ||
  fail "gate product verifier does not require the hosted-gate extension marker"
grep -Fq 'enumerate_macho_relative_paths' "$gate_product_verifier" ||
  fail "gate product verifier does not recursively inventory substituted Mach-O code"
grep -Fq 'test-camera-agent-product.sh' "$production_installer" ||
  fail "production installer lost the production-only product gate"
grep -Fq 'test-synthetic-gate-product.sh' "$gate_installer" ||
  fail "gate installer does not require the synthetic product gate"
grep -Fq 'test-camera-agent-product.sh' "$gate_installer" ||
  fail "gate transaction does not preflight and restore the production product"
grep -Fq 'source "$transaction_library"' "$gate_installer" ||
  fail "gate installer does not source the durable transaction library"
grep -Fq 'synthetic_gate_transaction_run' "$gate_installer" ||
  fail "gate installer does not delegate to the durable transaction"
grep -Fq 'synthetic_txn_write_journal' "$gate_transaction_library" ||
  fail "gate transaction has no durable journal"
grep -Fq '/usr/bin/lockf -s -t 0' "$gate_transaction_library" ||
  fail "gate transaction has no exclusive BSD lock"
grep -Fq 'synthetic_txn_processes_are_gone' "$gate_transaction_library" ||
  fail "gate transaction has no exact-path live-helper restoration barrier"
grep -Fq 'IDLESCREEN_SYNTHETIC_TXN_COMPLETION_EVIDENCE_DIR' "$gate_transaction_library" ||
  fail "gate transaction has no opt-in durable completion evidence export"
grep -Fq 'synthetic_txn_preserve_completion_evidence' "$gate_transaction_library" ||
  fail "gate transaction cleanup omits its completion evidence hook"
grep -Fq 'IDLESCREEN_ALLOW_WALLPAPER_AGENT_RESTART' "$gate_installer" ||
  fail "gate installer does not require exact WallpaperAgent restart authorization"
grep -Fq 'synthetic_physical_text_executable_for_pid' "$gate_installer" ||
  fail "gate installer does not fail closed on process text-executable ownership"
grep -Fq '"$process_guard" cleanup' "$gate_installer" ||
  fail "gate installer does not identity-guard WallpaperAgent termination"
if grep -Fq '/usr/bin/killall WallpaperAgent' "$gate_installer"; then
  fail "gate installer still contains broad WallpaperAgent termination"
fi
grep -Fq 'test-synthetic-gate-transaction.sh' "$project_root/scripts/test-phase1.sh" ||
  fail "focused synthetic transaction fixtures are not wired into Phase 1"
grep -Fq 'archive' "$gate_builder" || fail "gate builder does not use an archive workflow"
if grep -Eq '(^|[[:space:]])xcodebuild build([[:space:]]|$)' "$gate_builder"; then
  fail "gate builder uses the Launch-Services-registering build action"
fi
grep -Fq 'production_extension_relative="Contents/PlugIns/IdleScreenScreenSaver.appex"' "$gate_manifest_tool" ||
  fail "gate manifest has no explicit hosted-extension substitution whitelist"
grep -Fq 'Contents/Library/LaunchAgents' "$gate_manifest_tool" ||
  fail "gate manifest does not preserve the exact LaunchAgent plist"
grep -Fq 'production_helper_relative="Contents/Helpers/IdleScreenCameraAgent.app"' "$gate_manifest_tool" ||
  fail "gate manifest has no explicit helper-substitution whitelist"
grep -Fq "/usr/bin/stat -f '%Lp'" "$gate_manifest_tool" ||
  fail "gate manifest inventory omits filesystem modes"
grep -Fq 'Contents/_CodeSignature/CodeResources' "$gate_manifest_tool" ||
  fail "gate manifest does not narrowly allow outer resealing"
grep -Fq 'Contents/MacOS/IdleScreen' "$gate_manifest_tool" ||
  fail "gate manifest does not identify the outer signature envelope"
grep -Fq 'codesign --remove-signature' "$gate_manifest_tool" ||
  fail "gate manifest does not compare signature-stripped outer code"
grep -Fq 'productionExtensionCDHash=' "$gate_manifest_tool" ||
  fail "gate manifest does not record the production extension CDHash"
grep -Fq 'syntheticExtensionCDHash=' "$gate_manifest_tool" ||
  fail "gate manifest does not record the hosted-gate extension CDHash"
grep -Fq 'write_xattr_inventory' "$gate_manifest_tool" ||
  fail "gate manifest does not compare extended-attribute names and values"
grep -Fq 'outerCodeDirectoryFlags=' "$gate_manifest_tool" ||
  fail "gate manifest does not record outer CodeDirectory flags"
grep -Fq 'synthetic_extension=' "$gate_builder" ||
  fail "gate builder does not build a separate hosted-gate extension archive"
grep -Fq '/bin/rm -rf "$gate_extension"' "$gate_builder" ||
  fail "gate builder does not explicitly replace the production extension"
grep -Fq 'production_code_directory_flags' "$gate_builder" ||
  fail "gate builder does not capture production CodeDirectory flags"
grep -Fq 'gate_code_directory_flags' "$gate_builder" ||
  fail "gate builder does not verify resealed gate CodeDirectory flags"
grep -Fq -- '--preserve-metadata=identifier,requirements,flags' "$gate_builder" ||
  fail "gate builder does not preserve the outer hardened-runtime flags"
if grep -Eq 'byte-identical production extension|production extension is byte-identical|exact production extension' \
  "$gate_builder" "$gate_product_verifier" "$gate_manifest_tool"; then
  fail "synthetic hosted evidence overclaims byte-identical production-extension proof"
fi

echo 'PASS: synthetic gate is isolated at the capture boundary and shipping graphs remain synthetic-free.'
