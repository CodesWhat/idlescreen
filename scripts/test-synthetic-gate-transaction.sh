#!/bin/bash

# Fixture callbacks are invoked indirectly by the sourced transaction library.
# shellcheck disable=SC2329
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
transaction_library="$project_root/scripts/lib/synthetic-gate-transaction.sh"

production_app_cdhash=1111111111111111111111111111111111111111
production_helper_cdhash=2222222222222222222222222222222222222222
production_extension_cdhash=3333333333333333333333333333333333333333
synthetic_app_cdhash=4444444444444444444444444444444444444444
synthetic_helper_cdhash=5555555555555555555555555555555555555555
synthetic_extension_cdhash=6666666666666666666666666666666666666666

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_app() {
  local app_path="$1"
  local app_identity="$2"
  local helper_identity="$3"
  local extension_identity="$4"
  /bin/mkdir -p \
    "$app_path/Contents/Helpers/IdleScreenCameraAgent.app/Contents" \
    "$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents"
  printf '%s\n' "$app_identity" >"$app_path/Contents/.fixture-cdhash"
  printf 'clean\n' >"$app_path/Contents/.fixture-tree"
  printf '%s\n' "$helper_identity" \
    >"$app_path/Contents/Helpers/IdleScreenCameraAgent.app/Contents/.fixture-cdhash"
  printf '%s\n' "$extension_identity" \
    >"$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/.fixture-cdhash"
}

fixture_identity() {
  local product_path="$1"
  local app_identity_file="$product_path/Contents/.fixture-cdhash"
  local helper_identity_file="$product_path/Contents/Helpers/IdleScreenCameraAgent.app/Contents/.fixture-cdhash"
  local extension_identity_file="$product_path/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/.fixture-cdhash"
  [[ -f "$app_identity_file" && -f "$helper_identity_file" &&
     -f "$extension_identity_file" ]] || return 1
  printf '%s\t%s\t%s\n' \
    "$(<"$app_identity_file")" \
    "$(<"$helper_identity_file")" \
    "$(<"$extension_identity_file")"
}

assert_production_restored() {
  local installed_app="$1"
  [[ "$(fixture_identity "$installed_app")" == \
     "$production_app_cdhash"$'\t'"$production_helper_cdhash"$'\t'"$production_extension_cdhash" ]] ||
    fail "the exact production app/helper/extension identities were not restored at $installed_app"
}

assert_no_transaction_residue() {
  local installed_app="$1"
  local parent
  local leaf
  parent="$(/usr/bin/dirname "$installed_app")"
  leaf="$(/usr/bin/basename "$installed_app")"
  [[ ! -e "$parent/.${leaf}.synthetic-transaction" ]] ||
    fail "transaction journal or backup/staging/retired residue remains"
}

assert_synthetic_installed() {
  local installed_app="$1"
  [[ "$(fixture_identity "$installed_app")" == \
     "$synthetic_app_cdhash"$'\t'"$synthetic_helper_cdhash"$'\t'"$synthetic_extension_cdhash" ]] ||
    fail "the synthetic app was not retained at $installed_app"
}

write_external_state() {
  local destination="$1"
  local runtime_state="$2"
  local app_path="$3"
  local helper_cdhash="$4"
  local extension_cdhash="$5"
  local extension_path="$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex"
  {
    printf 'format=1\n'
    printf 'service_status=enabled\n'
    printf 'launchd_registration=loaded\n'
    printf 'helper_runtime=%s\n' "$runtime_state"
    printf 'helper_path=%s\n' \
      "$app_path/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent"
    printf 'helper_cdhash=%s\n' "$helper_cdhash"
    printf 'pluginkit_paths=%s\n' "$extension_path"
    printf 'selected_path=%s\n' "$extension_path"
    printf 'extension_cdhash=%s\n' "$extension_cdhash"
  } >"$destination"
}

new_fixture() {
  local fixture_root="$1"
  local runtime_state="${2:-absent}"
  /bin/mkdir -p "$fixture_root/installed" "$fixture_root/artifacts"
  make_app "$fixture_root/installed/IdleScreen.app" \
    "$production_app_cdhash" "$production_helper_cdhash" "$production_extension_cdhash"
  make_app "$fixture_root/artifacts/IdleScreenSyntheticGate.app" \
    "$synthetic_app_cdhash" "$synthetic_helper_cdhash" "$synthetic_extension_cdhash"
  printf 'fixture manifest\n' >"$fixture_root/manifest.txt"
  write_external_state \
    "$fixture_root/registration-state.txt" \
    "$runtime_state" \
    "$fixture_root/installed/IdleScreen.app" \
    "$production_helper_cdhash" \
    "$production_extension_cdhash"
  /bin/cp "$fixture_root/registration-state.txt" \
    "$fixture_root/expected-registration-state.txt"
  : >"$fixture_root/transaction-events.txt"
}

if [[ "${1:-}" == --worker ]]; then
  shift
  [[ $# -eq 7 ]] || fail "worker expects installed, gate, manifest, runner, fault, checkpoint, and mode"
  installed_app="$1"
  gate_candidate="$2"
  manifest="$3"
  runner="$4"
  fault="$5"
  checkpoint="$6"
  mode="$7"
  fixture_case_root="$(/usr/bin/dirname "$manifest")"
  fixture_registration_state="$fixture_case_root/registration-state.txt"
  fixture_expected_registration_state="$fixture_case_root/expected-registration-state.txt"
  fixture_events="$fixture_case_root/transaction-events.txt"

  # The production transaction owns real filesystem moves/copies. Fixtures
  # replace only signed-product verification and CDHash extraction.
  # shellcheck source=/dev/null
  source "$transaction_library"

  synthetic_txn_identity() {
    fixture_identity "$1"
  }

  synthetic_txn_verify_signature_tree() {
    local product_path="$1"
    [[ -f "$product_path/Contents/.fixture-tree" &&
       "$(<"$product_path/Contents/.fixture-tree")" == clean ]] || return 1
    synthetic_txn_last_signature_verification="$product_path"
  }

  synthetic_txn_verify_production() {
    [[ "$(fixture_identity "$1")" == \
       "$production_app_cdhash"$'\t'"$production_helper_cdhash"$'\t'"$production_extension_cdhash" ]]
    [[ "$(<"$1/Contents/.fixture-tree")" == clean ]]
    synthetic_txn_last_product_verification="production:$1"
  }

  synthetic_txn_verify_gate() {
    [[ -f "$4" ]]
    [[ "$(fixture_identity "$2")" == \
       "$synthetic_app_cdhash"$'\t'"$synthetic_helper_cdhash"$'\t'"$synthetic_extension_cdhash" ]]
    [[ "$(<"$2/Contents/.fixture-tree")" == clean ]]
    synthetic_txn_last_product_verification="synthetic:$2"
  }

  synthetic_txn_capture_external_state() {
    local destination="$1"
    printf 'capture\n' >>"$fixture_events"
    case "$mode" in
      fail-capture)
        return 1
        ;;
      malformed-capture)
        printf 'format=1\n' >"$destination"
        ;;
      *)
        /bin/cp "$fixture_registration_state" "$destination"
        ;;
    esac
  }

  synthetic_txn_validate_external_state_snapshot() {
    local snapshot="$1"
    [[ -f "$snapshot" && "$(/usr/bin/wc -l <"$snapshot" | /usr/bin/xargs)" == 9 ]] || return 1
    /usr/bin/grep -Fxq 'format=1' "$snapshot" || return 1
    /usr/bin/grep -Eq '^service_status=(enabled|notRegistered)$' "$snapshot" || return 1
    /usr/bin/grep -Eq '^launchd_registration=(loaded|unbound)$' "$snapshot" || return 1
    /usr/bin/grep -Eq '^helper_runtime=(absent|warm|gate-warm)$' "$snapshot" || return 1
    /usr/bin/grep -Eq '^helper_path=/.+' "$snapshot" || return 1
    /usr/bin/grep -Eq '^helper_cdhash=[[:xdigit:]]{40}$|^helper_cdhash=[[:xdigit:]]{64}$' "$snapshot" || return 1
    /usr/bin/grep -Eq '^pluginkit_paths=.*' "$snapshot" || return 1
    /usr/bin/grep -Eq '^selected_path=/.+' "$snapshot" || return 1
    /usr/bin/grep -Eq '^extension_cdhash=[[:xdigit:]]{40}$|^extension_cdhash=[[:xdigit:]]{64}$' "$snapshot"
  }

  synthetic_txn_assert_stable_quiescence() {
    [[ $# -eq 3 ]] || fail "quiescence callback did not receive its durable inventory path"
    local destination="$1"
    printf 'quiescence\n' >>"$fixture_events"
    [[ "$mode" != block-* ]] || return 1
    /usr/bin/grep -Fxq 'helper_runtime=absent' "$fixture_registration_state" || return 1
    {
      printf 'format=1\n'
      printf 'sample_count=3\n'
      printf 'sample_1_pid_paths=\n'
      printf 'sample_2_pid_paths=\n'
      printf 'sample_3_pid_paths=\n'
    } >"$destination"
  }

  synthetic_txn_validate_quiescence_inventory() {
    local snapshot="$1"
    [[ -f "$snapshot" && "$(/usr/bin/wc -l <"$snapshot" | /usr/bin/xargs)" == 5 ]] || return 1
    /usr/bin/grep -Fxq 'format=1' "$snapshot" || return 1
    /usr/bin/grep -Fxq 'sample_count=3' "$snapshot" || return 1
    local sample
    for sample in 1 2 3; do
      /usr/bin/grep -Eq "^sample_${sample}_pid_paths=([^|[:cntrl:]]+:[^|[:cntrl:]]+([|][^|[:cntrl:]]+:[^|[:cntrl:]]+)*)?$" "$snapshot" || return 1
    done
  }

  synthetic_txn_retire_production_registration() {
    local app_path="$1"
    local extension_path="$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex"
    printf 'production-retire\n' >>"$fixture_events"
    {
      printf 'format=1\n'
      printf 'service_status=enabled\n'
      printf 'launchd_registration=unbound\n'
      printf 'helper_runtime=absent\n'
      printf 'helper_path=%s\n' \
        "$app_path/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent"
      printf 'helper_cdhash=%s\n' "$production_helper_cdhash"
      printf 'pluginkit_paths=\n'
      printf 'selected_path=%s\n' "$extension_path"
      printf 'extension_cdhash=%s\n' "$production_extension_cdhash"
    } >"$fixture_registration_state"
  }

  synthetic_txn_verify_production_registration_retired() {
    printf 'production-retire-verify\n' >>"$fixture_events"
    /usr/bin/grep -Fxq 'launchd_registration=unbound' "$fixture_registration_state" &&
      /usr/bin/grep -Fxq 'helper_runtime=absent' "$fixture_registration_state" &&
      /usr/bin/grep -Fxq 'pluginkit_paths=' "$fixture_registration_state"
  }

  synthetic_txn_rebind_gate_registration() {
    local app_path="$1"
    printf 'gate-rebind\n' >>"$fixture_events"
    [[ "$mode" != fail-gate-rebind ]] || return 1
    write_external_state \
      "$fixture_registration_state" \
      gate-warm \
      "$app_path" \
      "$synthetic_helper_cdhash" \
      "$synthetic_extension_cdhash"
  }

  synthetic_txn_verify_gate_registration() {
    local app_path="$1"
    local expected="$fixture_case_root/gate-registration-expected.txt"
    printf 'gate-verify\n' >>"$fixture_events"
    write_external_state \
      "$expected" \
      gate-warm \
      "$app_path" \
      "$synthetic_helper_cdhash" \
      "$synthetic_extension_cdhash"
    /usr/bin/cmp -s "$expected" "$fixture_registration_state"
  }

  synthetic_txn_capture_gate_bound_state() {
    local destination="$1"
    printf 'gate-evidence\n' >>"$fixture_events"
    /bin/cp "$fixture_registration_state" "$destination"
  }

  synthetic_txn_validate_gate_bound_state() {
    synthetic_txn_validate_external_state_snapshot "$1"
  }

  synthetic_txn_retire_gate_registration() {
    local app_path="$1"
    local extension_path="$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex"
    printf 'gate-retire\n' >>"$fixture_events"
    [[ "$mode" != fail-gate-retire ]] || return 1
    {
      printf 'format=1\n'
      printf 'service_status=enabled\n'
      printf 'launchd_registration=unbound\n'
      printf 'helper_runtime=absent\n'
      printf 'helper_path=%s\n' \
        "$app_path/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent"
      printf 'helper_cdhash=%s\n' "$synthetic_helper_cdhash"
      printf 'pluginkit_paths=\n'
      printf 'selected_path=%s\n' "$extension_path"
      printf 'extension_cdhash=%s\n' "$synthetic_extension_cdhash"
    } >"$fixture_registration_state"
  }

  synthetic_txn_verify_gate_registration_retired() {
    printf 'gate-retire-verify\n' >>"$fixture_events"
    /usr/bin/grep -Fxq 'launchd_registration=unbound' "$fixture_registration_state" &&
      /usr/bin/grep -Fxq 'pluginkit_paths=' "$fixture_registration_state"
  }

  synthetic_txn_marker_processes_are_gone() {
    local fixture_marker_pid_file="$fixture_case_root/live.pid"
    local fixture_marker_pid
    printf 'marker-barrier\n' >>"$fixture_events"
    [[ "$mode" != live-marker-helper && "$mode" != live-marker-extension ]] || return 1
    if [[ -s "$fixture_marker_pid_file" ]]; then
      fixture_marker_pid="$(<"$fixture_marker_pid_file")"
      [[ "$fixture_marker_pid" =~ ^[1-9][0-9]*$ ]] || return 1
      /bin/kill -0 "$fixture_marker_pid" 2>/dev/null && return 1
    fi
    return 0
  }

  synthetic_txn_restore_production_registration() {
    local snapshot="$1"
    printf 'production-rebind\n' >>"$fixture_events"
    [[ "$mode" != fail-production-rebind ]] || return 1
    /bin/cp "$snapshot" "$fixture_registration_state"
  }

  synthetic_txn_verify_production_registration() {
    local snapshot="$1"
    printf 'production-verify\n' >>"$fixture_events"
    /usr/bin/cmp -s "$snapshot" "$fixture_registration_state"
  }

  synthetic_txn_capture_post_restore_state() {
    local destination="$1"
    printf 'production-evidence\n' >>"$fixture_events"
    /bin/cp "$fixture_registration_state" "$destination"
  }

  synthetic_txn_validate_post_restore_state() {
    synthetic_txn_validate_external_state_snapshot "$1"
  }

  synthetic_txn_before_destructive_transition() {
    local operation="$1"
    local kind="$2"
    local product_path="$3"
    [[ "${synthetic_txn_last_signature_verification:-}" == "$product_path" ]] ||
      fail "$operation of $product_path lacked immediate strict tree verification"
    if [[ "$kind" == external ]]; then
      :
    else
      [[ "${synthetic_txn_last_product_verification:-}" == "$kind:$product_path" ]] ||
        fail "$operation of $product_path lacked immediate $kind product verification"
    fi
    printf '%s\t%s\t%s\n' "$operation" "$kind" "$product_path" \
      >>"$manifest.verification-transitions"
    synthetic_txn_last_signature_verification=""
    synthetic_txn_last_product_verification=""
  }

  synthetic_txn_after_checkpoint() {
    local reached="$1"
    [[ "$reached" == "$checkpoint" ]] || return 0
    case "$mode" in
      external)
        make_app "$installed_app" \
          aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
          bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
          cccccccccccccccccccccccccccccccccccccccc
        ;;
      mutate-staging)
        printf 'tampered-with-same-recorded-cdhash\n' \
          >"$installed_app/../.IdleScreen.app.synthetic-transaction/staging.app/Contents/.fixture-tree"
        ;;
      normal|warm|block-*|fail-capture|malformed-capture|fail-gate-rebind|fail-gate-retire|fail-production-rebind|live-marker-helper|live-marker-extension)
        ;;
      *)
        fail "unknown worker mode: $mode"
        ;;
    esac
    case "$fault" in
      INT)
        /bin/kill -INT "$$"
        ;;
      TERM)
        /bin/kill -TERM "$$"
        ;;
      KILL)
        /bin/kill -KILL "$$"
        ;;
      none)
        ;;
      *)
        fail "unknown worker fault: $fault"
        ;;
    esac
  }

  synthetic_gate_transaction_run \
    "$installed_app" "$gate_candidate" "$manifest" -- "$runner"
  exit $?
fi

[[ -f "$transaction_library" ]] || fail "missing transaction library: $transaction_library"
bash -n "$transaction_library"

fixture_root="$(mktemp -d /tmp/idlescreen-synthetic-transaction.XXXXXX)"
trap '/bin/rm -rf "$fixture_root"' EXIT

worker="$0"
runner=/usr/bin/true

for runtime_state in absent warm; do
  case_root="$fixture_root/success-$runtime_state"
  new_fixture "$case_root" "$runtime_state"
  journal_runner="$case_root/assert-journal.sh"
  transaction_dir="$case_root/installed/.IdleScreen.app.synthetic-transaction"
  installed_path="$(/bin/realpath "$case_root/installed/IdleScreen.app")"
  gate_path="$(/bin/realpath "$case_root/artifacts/IdleScreenSyntheticGate.app")"
  printf '#!/bin/bash\nset -euo pipefail\njournal="%s/journal"\n[[ -f "$journal" ]]\ngrep -Fxq "format=4" "$journal"\ngrep -Fxq "production_app_cdhash=%s" "$journal"\ngrep -Fxq "production_helper_cdhash=%s" "$journal"\ngrep -Fxq "production_extension_cdhash=%s" "$journal"\ngrep -Fxq "synthetic_app_cdhash=%s" "$journal"\ngrep -Fxq "synthetic_helper_cdhash=%s" "$journal"\ngrep -Fxq "synthetic_extension_cdhash=%s" "$journal"\ngrep -Fxq "installed_app_path=%s" "$journal"\ngrep -Fxq "production_helper_path=%s/Contents/Helpers/IdleScreenCameraAgent.app" "$journal"\ngrep -Fxq "production_extension_path=%s/Contents/PlugIns/IdleScreenScreenSaver.appex" "$journal"\ngrep -Fxq "gate_candidate_path=%s" "$journal"\ngrep -Eq "^manifest_sha256=[[:xdigit:]]{64}$" "$journal"\ngrep -Eq "^pre_state_sha256=[[:xdigit:]]{64}$" "$journal"\ngrep -Eq "^quiescence_inventory_sha256=[[:xdigit:]]{64}$" "$journal"\ngrep -Eq "^gate_bound_state_sha256=[[:xdigit:]]{64}$" "$journal"\n[[ -f "%s/quiescence-inventory" ]]\n[[ -f "%s/gate-bound-state" ]]\n' \
    "$transaction_dir" \
    "$production_app_cdhash" \
    "$production_helper_cdhash" \
    "$production_extension_cdhash" \
    "$synthetic_app_cdhash" \
    "$synthetic_helper_cdhash" \
    "$synthetic_extension_cdhash" \
    "$installed_path" \
    "$installed_path" \
    "$installed_path" \
    "$gate_path" \
    "$transaction_dir" \
    "$transaction_dir" >"$journal_runner"
  /bin/chmod +x "$journal_runner"

  "$worker" --worker \
    "$installed_path" \
    "$gate_path" \
    "$case_root/manifest.txt" "$journal_runner" none never normal
  assert_production_restored "$installed_path"
  /usr/bin/cmp -s \
    "$case_root/expected-registration-state.txt" \
    "$case_root/registration-state.txt" ||
    fail "$runtime_state pre-state was not restored exactly"
  assert_no_transaction_residue "$installed_path"
  expected_events=$'capture\nproduction-retire\nproduction-retire-verify\nquiescence\ngate-rebind\ngate-verify\ngate-evidence\ngate-retire\ngate-retire-verify\nmarker-barrier\nproduction-rebind\nproduction-verify\nproduction-evidence'
  [[ "$(<"$case_root/transaction-events.txt")" == "$expected_events" ]] ||
    fail "$runtime_state transaction ordering was not exact: $(tr '\n' '|' <"$case_root/transaction-events.txt")"
done

# Successful callers may opt into a durable, hash-bound copy of the cleanup
# journal and all before/gate/after state without changing default cleanup.
case_root="$fixture_root/completion-evidence"
new_fixture "$case_root"
completion_evidence="$case_root/exported-completion"
IDLESCREEN_SYNTHETIC_TXN_COMPLETION_EVIDENCE_DIR="$completion_evidence" \
  "$worker" --worker \
    "$case_root/installed/IdleScreen.app" \
    "$case_root/artifacts/IdleScreenSyntheticGate.app" \
    "$case_root/manifest.txt" "$runner" none never normal
assert_production_restored "$case_root/installed/IdleScreen.app"
assert_no_transaction_residue "$case_root/installed/IdleScreen.app"
[[ -d "$completion_evidence" && ! -L "$completion_evidence" ]] ||
  fail "successful transaction did not preserve the requested completion evidence"
for exported_file in \
  transaction-journal.txt gate-manifest.txt pre-state.txt \
  quiescence-inventory.txt gate-bound-state.txt post-restore-state.txt \
  completion-manifest.txt; do
  [[ -f "$completion_evidence/$exported_file" &&
     ! -L "$completion_evidence/$exported_file" ]] ||
    fail "completion evidence omitted $exported_file"
done
/usr/bin/grep -Fxq 'format=IdleScreenSyntheticGateTransactionCompletionEvidenceV1' \
  "$completion_evidence/completion-manifest.txt" ||
  fail "completion evidence manifest schema is missing"
/usr/bin/grep -Fxq 'transaction_phase=cleanup' \
  "$completion_evidence/completion-manifest.txt" ||
  fail "completion evidence was not captured at the cleanup journal boundary"
/usr/bin/grep -Fxq 'phase=cleanup' "$completion_evidence/transaction-journal.txt" ||
  fail "preserved transaction journal is not the final cleanup phase"
/usr/bin/cmp -s "$completion_evidence/pre-state.txt" \
  "$completion_evidence/post-restore-state.txt" ||
  fail "preserved post-restore state differs from the durable pre-state"
for evidence_record in \
  'transaction-journal.txt:journal_sha256' \
  'gate-manifest.txt:gate_manifest_sha256' \
  'pre-state.txt:pre_state_sha256' \
  'quiescence-inventory.txt:quiescence_inventory_sha256' \
  'gate-bound-state.txt:gate_bound_state_sha256' \
  'post-restore-state.txt:post_restore_state_sha256'; do
  exported_file="${evidence_record%%:*}"
  digest_key="${evidence_record#*:}"
  expected_digest="$(/usr/bin/awk -F= -v key="$digest_key" \
    '$1 == key { print $2; found++ } END { exit(found == 1 ? 0 : 1) }' \
    "$completion_evidence/completion-manifest.txt")" ||
    fail "completion manifest omitted unique $digest_key"
  actual_digest="$(/usr/bin/shasum -a 256 "$completion_evidence/$exported_file" |
    /usr/bin/awk '{ print $1 }')"
  [[ "$actual_digest" == "$expected_digest" ]] ||
    fail "completion manifest does not hash-bind $exported_file"
done

# A pre-existing destination is rejected before the transaction captures or
# mutates external state; recovery is the only path allowed to reuse an export.
case_root="$fixture_root/completion-evidence-collision"
new_fixture "$case_root"
/bin/mkdir "$case_root/existing-export"
set +e
IDLESCREEN_SYNTHETIC_TXN_COMPLETION_EVIDENCE_DIR="$case_root/existing-export" \
  "$worker" --worker \
    "$case_root/installed/IdleScreen.app" \
    "$case_root/artifacts/IdleScreenSyntheticGate.app" \
    "$case_root/manifest.txt" "$runner" none never normal \
    >"$case_root/collision.txt" 2>&1
status=$?
set -e
[[ $status -ne 0 ]] || fail "transaction reused a pre-existing completion destination"
[[ ! -s "$case_root/transaction-events.txt" ]] ||
  fail "completion destination collision was detected after external-state mutation began"
assert_production_restored "$case_root/installed/IdleScreen.app"
assert_no_transaction_residue "$case_root/installed/IdleScreen.app"

# Capture and schema failures happen before an active journal exists. They must
# remove only their known transaction artifacts so the next run is not wedged
# behind an unrecoverable journal-less directory.
for capture_mode in fail-capture malformed-capture; do
  case_root="$fixture_root/$capture_mode"
  new_fixture "$case_root"
  set +e
  "$worker" --worker \
    "$case_root/installed/IdleScreen.app" \
    "$case_root/artifacts/IdleScreenSyntheticGate.app" \
    "$case_root/manifest.txt" "$runner" none never "$capture_mode" \
    >"$case_root/failure.txt" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]] || fail "$capture_mode was accepted"
  assert_production_restored "$case_root/installed/IdleScreen.app"
  /usr/bin/cmp -s \
    "$case_root/expected-registration-state.txt" \
    "$case_root/registration-state.txt" || fail "$capture_mode changed registration state"
  ! /usr/bin/grep -Fq 'production-rebind' "$case_root/transaction-events.txt" ||
    fail "$capture_mode invoked a production rebind before any mutation"
  assert_no_transaction_residue "$case_root/installed/IdleScreen.app"
  "$worker" --worker \
    "$case_root/installed/IdleScreen.app" \
    "$case_root/artifacts/IdleScreenSyntheticGate.app" \
    "$case_root/manifest.txt" "$runner" none never normal
  assert_production_restored "$case_root/installed/IdleScreen.app"
  assert_no_transaction_residue "$case_root/installed/IdleScreen.app"
done

# Every relevant resident process class must stop the transaction before the
# first production rename. The callback models read-only process observations;
# no process is launched or terminated by this fixture.
for blocker in \
  companion \
  production-helper \
  gate-helper \
  production-extension \
  gate-extension \
  screensaver-host; do
  case_root="$fixture_root/pre-swap-$blocker"
  new_fixture "$case_root"
  set +e
  "$worker" --worker \
    "$case_root/installed/IdleScreen.app" \
    "$case_root/artifacts/IdleScreenSyntheticGate.app" \
    "$case_root/manifest.txt" "$runner" none never "block-$blocker" \
    >"$case_root/output.txt" 2>&1
  status=$?
  set -e
  [[ $status -ne 0 ]] || fail "$blocker did not block the pre-swap transaction"
  assert_production_restored "$case_root/installed/IdleScreen.app"
  /usr/bin/cmp -s \
    "$case_root/expected-registration-state.txt" \
    "$case_root/registration-state.txt" ||
    fail "$blocker refusal changed registration state"
  ! /usr/bin/grep -Fq 'gate-rebind' "$case_root/transaction-events.txt" ||
    fail "$blocker was observed only after gate installation"
  assert_no_transaction_residue "$case_root/installed/IdleScreen.app"
done

# A normal nonzero runner result must be preserved only after exact production
# bytes and registration have been restored.
case_root="$fixture_root/nonzero-runner"
new_fixture "$case_root"
set +e
"$worker" --worker \
  "$case_root/installed/IdleScreen.app" \
  "$case_root/artifacts/IdleScreenSyntheticGate.app" \
  "$case_root/manifest.txt" /usr/bin/false none never normal
status=$?
set -e
[[ $status -eq 1 ]] || fail "nonzero runner exited $status instead of preserving status 1"
assert_production_restored "$case_root/installed/IdleScreen.app"
/usr/bin/cmp -s \
  "$case_root/expected-registration-state.txt" \
  "$case_root/registration-state.txt" || fail "nonzero runner did not restore registration"
assert_no_transaction_residue "$case_root/installed/IdleScreen.app"

case_root="$fixture_root/gate-rebind-failure"
new_fixture "$case_root"
set +e
"$worker" --worker \
  "$case_root/installed/IdleScreen.app" \
  "$case_root/artifacts/IdleScreenSyntheticGate.app" \
  "$case_root/manifest.txt" "$runner" none never fail-gate-rebind
status=$?
set -e
[[ $status -ne 0 ]] || fail "gate rebind failure was ignored"
assert_production_restored "$case_root/installed/IdleScreen.app"
/usr/bin/cmp -s \
  "$case_root/expected-registration-state.txt" \
  "$case_root/registration-state.txt" || fail "gate rebind failure did not restore pre-state"
assert_no_transaction_residue "$case_root/installed/IdleScreen.app"

for failure_mode in fail-gate-retire fail-production-rebind; do
  case_root="$fixture_root/$failure_mode"
  new_fixture "$case_root"
  set +e
  "$worker" --worker \
    "$case_root/installed/IdleScreen.app" \
    "$case_root/artifacts/IdleScreenSyntheticGate.app" \
    "$case_root/manifest.txt" "$runner" none never "$failure_mode" \
    >"$case_root/failure.txt" 2>&1
  status=$?
  set -e
  [[ $status -eq 70 ]] || fail "$failure_mode exited $status, expected fail-closed 70"
  [[ -f "$case_root/installed/.IdleScreen.app.synthetic-transaction/journal" ]] ||
    fail "$failure_mode discarded its recovery journal"
  "$worker" --worker \
    "$case_root/installed/IdleScreen.app" \
    "$case_root/artifacts/IdleScreenSyntheticGate.app" \
    "$case_root/manifest.txt" "$runner" none never normal
  assert_production_restored "$case_root/installed/IdleScreen.app"
  /usr/bin/cmp -s \
    "$case_root/expected-registration-state.txt" \
    "$case_root/registration-state.txt" || fail "$failure_mode recovery did not restore pre-state"
  assert_no_transaction_residue "$case_root/installed/IdleScreen.app"
done

for marker_kind in helper extension; do
  case_root="$fixture_root/live-$marker_kind-model"
  new_fixture "$case_root"
  set +e
  "$worker" --worker \
    "$case_root/installed/IdleScreen.app" \
    "$case_root/artifacts/IdleScreenSyntheticGate.app" \
    "$case_root/manifest.txt" "$runner" none never "live-marker-$marker_kind" \
    >"$case_root/live.txt" 2>&1
  status=$?
  set -e
  [[ $status -eq 70 ]] || fail "live marker $marker_kind exited $status, expected 70"
  assert_synthetic_installed "$case_root/installed/IdleScreen.app"
  [[ -f "$case_root/installed/.IdleScreen.app.synthetic-transaction/journal" ]] ||
    fail "live marker $marker_kind discarded its recovery journal"
  "$worker" --worker \
    "$case_root/installed/IdleScreen.app" \
    "$case_root/artifacts/IdleScreenSyntheticGate.app" \
    "$case_root/manifest.txt" "$runner" none never normal
  assert_production_restored "$case_root/installed/IdleScreen.app"
  assert_no_transaction_residue "$case_root/installed/IdleScreen.app"
done

for signal_name in INT TERM; do
  case "$signal_name" in
    INT) expected_status=130 ;;
    TERM) expected_status=143 ;;
  esac
  for checkpoint in \
    after_production_registration_retire \
    after_production_backup \
    after_gate_install \
    after_gate_rebind \
    after_gate_registration_retire \
    after_gate_retire \
    after_production_restore \
    after_production_rebind; do
    case_root="$fixture_root/signal-${signal_name}-${checkpoint}"
    new_fixture "$case_root"
    set +e
    "$worker" --worker \
      "$case_root/installed/IdleScreen.app" \
      "$case_root/artifacts/IdleScreenSyntheticGate.app" \
      "$case_root/manifest.txt" "$runner" "$signal_name" "$checkpoint" normal
    status=$?
    set -e
    [[ $status -eq $expected_status ]] ||
      fail "$signal_name at $checkpoint exited $status, expected $expected_status"
    assert_production_restored "$case_root/installed/IdleScreen.app"
    assert_no_transaction_residue "$case_root/installed/IdleScreen.app"
  done
done

# SIGKILL and power loss cannot run a shell trap. Each durable state left after
# a copy or rename must be recovered safely by the next invocation.
for checkpoint in \
  after_production_registration_retire \
  after_gate_staging \
  after_production_backup \
  after_gate_install \
  after_gate_rebind \
  after_gate_registration_retire \
  after_gate_retire \
  after_production_restore \
  after_production_rebind; do
  case_root="$fixture_root/crash-${checkpoint}"
  new_fixture "$case_root"
  set +e
  {
    "$worker" --worker \
      "$case_root/installed/IdleScreen.app" \
      "$case_root/artifacts/IdleScreenSyntheticGate.app" \
      "$case_root/manifest.txt" "$runner" KILL "$checkpoint" normal
  } >/dev/null 2>&1
  status=$?
  set -e
  [[ $status -eq 137 ]] || fail "SIGKILL at $checkpoint exited $status, expected 137"

  recovery_output="$("$worker" --worker \
    "$case_root/installed/IdleScreen.app" \
    "$case_root/artifacts/IdleScreenSyntheticGate.app" \
    "$case_root/manifest.txt" "$runner" none never normal)"
  [[ "$recovery_output" == *"RECOVERY: durable synthetic transaction journal found"* ]] ||
    fail "stale journal recovery was not explicit at $checkpoint"
  assert_production_restored "$case_root/installed/IdleScreen.app"
  assert_no_transaction_residue "$case_root/installed/IdleScreen.app"
done

# A snapshot whose digest has been maliciously or accidentally recomputed must
# still be rejected when its required registration schema is incomplete.
case_root="$fixture_root/malformed-pre-state"
new_fixture "$case_root"
set +e
{
  "$worker" --worker \
    "$case_root/installed/IdleScreen.app" \
    "$case_root/artifacts/IdleScreenSyntheticGate.app" \
    "$case_root/manifest.txt" "$runner" KILL after_gate_rebind normal
} >/dev/null 2>&1
status=$?
set -e
[[ $status -eq 137 ]] || fail "malformed pre-state setup did not reach gate-bound state"
transaction_dir="$case_root/installed/.IdleScreen.app.synthetic-transaction"
/bin/cp "$transaction_dir/pre-state" "$case_root/pre-state.saved"
printf 'format=1\n' >"$transaction_dir/pre-state"
malformed_sha="$(/usr/bin/shasum -a 256 "$transaction_dir/pre-state" | /usr/bin/awk '{ print $1 }')"
/usr/bin/sed -i '' \
  "s/^pre_state_sha256=.*/pre_state_sha256=$malformed_sha/" \
  "$transaction_dir/journal"
set +e
"$worker" --worker \
  "$case_root/installed/IdleScreen.app" \
  "$case_root/artifacts/IdleScreenSyntheticGate.app" \
  "$case_root/manifest.txt" "$runner" none never normal \
  >"$case_root/malformed-output.txt" 2>&1
status=$?
set -e
[[ $status -eq 70 ]] || fail "well-hashed malformed pre-state exited $status, expected 70"
assert_synthetic_installed "$case_root/installed/IdleScreen.app"
/bin/cp "$case_root/pre-state.saved" "$transaction_dir/pre-state"
restored_sha="$(/usr/bin/shasum -a 256 "$transaction_dir/pre-state" | /usr/bin/awk '{ print $1 }')"
/usr/bin/sed -i '' \
  "s/^pre_state_sha256=.*/pre_state_sha256=$restored_sha/" \
  "$transaction_dir/journal"
"$worker" --worker \
  "$case_root/installed/IdleScreen.app" \
  "$case_root/artifacts/IdleScreenSyntheticGate.app" \
  "$case_root/manifest.txt" "$runner" none never normal
assert_production_restored "$case_root/installed/IdleScreen.app"
assert_no_transaction_residue "$case_root/installed/IdleScreen.app"

# If another actor creates an app after production was moved aside, recovery
# must preserve that external identity and still restore exact production.
case_root="$fixture_root/external-replacement"
new_fixture "$case_root"
set +e
"$worker" --worker \
  "$case_root/installed/IdleScreen.app" \
  "$case_root/artifacts/IdleScreenSyntheticGate.app" \
  "$case_root/manifest.txt" "$runner" TERM after_production_backup external
status=$?
set -e
[[ $status -eq 143 ]] || fail "external replacement signal exited $status, expected 143"
assert_production_restored "$case_root/installed/IdleScreen.app"
preserved_external="$(/usr/bin/find "$case_root/installed" -maxdepth 1 -type d \
  -name '.IdleScreen.app.external-preserved-*' -print)"
[[ -n "$preserved_external" ]] || fail "external replacement was not preserved"
[[ "$(fixture_identity "$preserved_external")" == \
   aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa$'\t'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb$'\t'cccccccccccccccccccccccccccccccccccccccc ]] ||
  fail "preserved external replacement identity changed"
assert_no_transaction_residue "$case_root/installed/IdleScreen.app"

# A held BSD file lock must reject a concurrent transaction before it can
# inspect, recover, or mutate the installed product.
case_root="$fixture_root/concurrent"
new_fixture "$case_root"
hold_runner="$case_root/hold-runner.sh"
release_file="$case_root/release"
started_file="$case_root/started"
# The generated runner intentionally evaluates its own jot command.
# shellcheck disable=SC2016
printf '#!/bin/bash\nset -euo pipefail\nprintf started >"%s"\nfor _ in $(/usr/bin/jot 100); do\n  [[ -e "%s" ]] && exit 0\n  /bin/sleep 0.05\ndone\nexit 1\n' \
  "$started_file" "$release_file" >"$hold_runner"
/bin/chmod +x "$hold_runner"
"$worker" --worker \
  "$case_root/installed/IdleScreen.app" \
  "$case_root/artifacts/IdleScreenSyntheticGate.app" \
  "$case_root/manifest.txt" "$hold_runner" none never normal \
  >"$case_root/first.log" 2>&1 &
first_pid=$!
for _ in $(/usr/bin/jot 100); do
  [[ -e "$started_file" ]] && break
  /bin/sleep 0.05
done
[[ -e "$started_file" ]] || fail "first transaction did not reach its runner"
set +e
"$worker" --worker \
  "$case_root/installed/IdleScreen.app" \
  "$case_root/artifacts/IdleScreenSyntheticGate.app" \
  "$case_root/manifest.txt" "$runner" none never normal \
  >"$case_root/second.log" 2>&1
status=$?
set -e
[[ $status -eq 75 ]] || fail "concurrent transaction exited $status, expected EX_TEMPFAIL (75)"
printf release >"$release_file"
wait "$first_pid" || fail "first transaction failed after concurrent refusal"
assert_production_restored "$case_root/installed/IdleScreen.app"
assert_no_transaction_residue "$case_root/installed/IdleScreen.app"

# The runner owns bounded TERM/KILL cleanup, but the transaction is the final
# barrier: it must never rename production under an exact-path marker helper
# that the runner accidentally left alive.
case_root="$fixture_root/live-marker-postcondition"
new_fixture "$case_root"
marker_executable="$case_root/installed/IdleScreen.app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent"
/bin/mkdir -p "$(/usr/bin/dirname "$marker_executable")"
gate_marker_executable="$case_root/artifacts/IdleScreenSyntheticGate.app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent"
/bin/mkdir -p "$(/usr/bin/dirname "$gate_marker_executable")"
printf '#include <stdio.h>\n#include <unistd.h>\nint main(int argc, char **argv) { if (argc != 2) return 2; pid_t child = fork(); if (child < 0) return 3; if (child > 0) return 0; if (setsid() < 0) return 4; FILE *pid_file = fopen(argv[1], "w"); if (!pid_file) return 5; fprintf(pid_file, "%%d\\n", getpid()); if (fclose(pid_file) != 0) return 6; for (;;) pause(); }\n' >"$case_root/marker.c"
/usr/bin/clang "$case_root/marker.c" -o "$gate_marker_executable"
live_runner="$case_root/live-runner.sh"
live_pid_file="$case_root/live.pid"
printf '#!/bin/bash\nset -euo pipefail\n"%s" "%s"\nexit 42\n' \
  "$marker_executable" "$live_pid_file" >"$live_runner"
/bin/chmod +x "$live_runner"
set +e
"$worker" --worker \
  "$case_root/installed/IdleScreen.app" \
  "$case_root/artifacts/IdleScreenSyntheticGate.app" \
  "$case_root/manifest.txt" "$live_runner" none never normal \
  >"$case_root/live.log" 2>&1
status=$?
set -e
[[ $status -eq 70 ]] || fail "live marker postcondition exited $status, expected 70"
[[ -s "$live_pid_file" ]] || fail "live marker runner did not record its child"
live_pid="$(<"$live_pid_file")"
/bin/kill -0 "$live_pid" 2>/dev/null || fail "marker fixture exited before the postcondition was checked"
assert_synthetic_installed "$case_root/installed/IdleScreen.app"
[[ -f "$case_root/installed/.IdleScreen.app.synthetic-transaction/journal" ]] ||
  fail "live marker refusal did not retain a recoverable journal"
/bin/kill -TERM "$live_pid"
for _ in $(/usr/bin/jot 60); do
  /bin/kill -0 "$live_pid" 2>/dev/null || break
  /bin/sleep 0.05
done
/bin/kill -0 "$live_pid" 2>/dev/null && fail "marker fixture did not exit in its bounded wait"
"$worker" --worker \
  "$case_root/installed/IdleScreen.app" \
  "$case_root/artifacts/IdleScreenSyntheticGate.app" \
  "$case_root/manifest.txt" "$runner" none never normal
assert_production_restored "$case_root/installed/IdleScreen.app"
assert_no_transaction_residue "$case_root/installed/IdleScreen.app"

# Mutation after the gate was initially checked deliberately leaves both fake
# CDHash files unchanged. Immediate strict/tree verification must catch it
# before either production or the staging tree is moved or deleted as owned.
case_root="$fixture_root/mutated-same-cdhash"
new_fixture "$case_root"
set +e
"$worker" --worker \
  "$case_root/installed/IdleScreen.app" \
  "$case_root/artifacts/IdleScreenSyntheticGate.app" \
  "$case_root/manifest.txt" "$runner" none after_gate_staging mutate-staging \
  >"$case_root/mutated.log" 2>&1
status=$?
set -e
[[ $status -ne 0 ]] || fail "mutated same-CDHash gate was accepted"
assert_production_restored "$case_root/installed/IdleScreen.app"
mutated_staging="$case_root/installed/.IdleScreen.app.synthetic-transaction/staging.app"
[[ -d "$mutated_staging" ]] || fail "mutated same-CDHash staging tree was moved or deleted"
[[ "$(fixture_identity "$mutated_staging")" == \
   "$synthetic_app_cdhash"$'\t'"$synthetic_helper_cdhash"$'\t'"$synthetic_extension_cdhash" ]] ||
  fail "mutation fixture unexpectedly changed its recorded fake CDHashes"
[[ "$(<"$mutated_staging/Contents/.fixture-tree")" == tampered-with-same-recorded-cdhash ]] ||
  fail "mutation fixture was not preserved byte-for-byte"

# Recovery must fail closed before moving or deleting a transaction path whose
# identity no longer matches the durable journal.
case_root="$fixture_root/tampered-staging"
new_fixture "$case_root"
set +e
{
  "$worker" --worker \
    "$case_root/installed/IdleScreen.app" \
    "$case_root/artifacts/IdleScreenSyntheticGate.app" \
    "$case_root/manifest.txt" "$runner" KILL after_gate_staging normal
} >/dev/null 2>&1
status=$?
set -e
[[ $status -eq 137 ]] || fail "tampered-staging setup did not stop at its durable state"
transaction_dir="$case_root/installed/.IdleScreen.app.synthetic-transaction"
printf 'dddddddddddddddddddddddddddddddddddddddd\n' \
  >"$transaction_dir/staging.app/Contents/.fixture-cdhash"
set +e
"$worker" --worker \
  "$case_root/installed/IdleScreen.app" \
  "$case_root/artifacts/IdleScreenSyntheticGate.app" \
  "$case_root/manifest.txt" "$runner" none never normal \
  >/dev/null 2>&1
status=$?
set -e
[[ $status -ne 0 ]] || fail "recovery accepted a staging identity not owned by the journal"
[[ -d "$transaction_dir/staging.app" ]] || fail "recovery deleted the external staging replacement"
[[ "$(fixture_identity "$transaction_dir/staging.app")" == \
   dddddddddddddddddddddddddddddddddddddddd$'\t'"$synthetic_helper_cdhash"$'\t'"$synthetic_extension_cdhash" ]] ||
  fail "recovery modified the external staging replacement"
assert_production_restored "$case_root/installed/IdleScreen.app"

# Exercise the production exact-path process-list matcher without depending on
# sandboxed process enumeration. Production still supplies only /usr/sbin/lsof.
process_matcher_root="$fixture_root/process-list-matcher"
/bin/mkdir -p "$process_matcher_root/IdleScreen.app"
process_matcher_lsof="$process_matcher_root/fixture-lsof.sh"
# These literal lines are the generated fixture script.
# shellcheck disable=SC2016
/usr/bin/printf '%s\n' \
  '#!/bin/bash' \
  'set -euo pipefail' \
  '[[ $# -eq 6 && "$1" == -a && "$2" == -p && "$4" == -d && "$5" == txt && "$6" == -Fn ]] || exit 64' \
  'case "$3" in' \
  '  101) /usr/bin/printf "n%s\\n" "$IDLESCREEN_SYNTHETIC_TXN_FIXTURE_HELPER" ;;' \
  '  202) /usr/bin/printf "n%s\\n" "$IDLESCREEN_SYNTHETIC_TXN_FIXTURE_EXTENSION" ;;' \
  '  404) exit 1 ;;' \
  '  405) exit 0 ;;' \
  '  *) /usr/bin/printf "n/usr/bin/other\\n" ;;' \
  'esac' \
  >"$process_matcher_lsof"
/bin/chmod +x "$process_matcher_lsof"
# shellcheck source=/dev/null
source "$transaction_library"
process_matcher_app="$process_matcher_root/IdleScreen.app"
process_matcher_helper="$process_matcher_app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent"
process_matcher_extension="$process_matcher_app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver"
if IDLESCREEN_SYNTHETIC_TXN_FIXTURE_HELPER="$process_matcher_helper" \
   IDLESCREEN_SYNTHETIC_TXN_FIXTURE_EXTENSION="$process_matcher_extension" \
   synthetic_txn_process_listing_is_clear \
     "$process_matcher_app" '101 IdleScreenCameraAgent --fixture' "$process_matcher_lsof"; then
  fail "production process-list matcher accepted the exact helper executable path"
fi
if IDLESCREEN_SYNTHETIC_TXN_FIXTURE_HELPER="$process_matcher_helper" \
   IDLESCREEN_SYNTHETIC_TXN_FIXTURE_EXTENSION="$process_matcher_extension" \
   synthetic_txn_process_listing_is_clear \
     "$process_matcher_app" '202 IdleScreenScreenSaver --fixture' "$process_matcher_lsof"; then
  fail "production process-list matcher accepted the exact extension executable path"
fi
IDLESCREEN_SYNTHETIC_TXN_FIXTURE_HELPER="$process_matcher_helper" \
IDLESCREEN_SYNTHETIC_TXN_FIXTURE_EXTENSION="$process_matcher_extension" \
synthetic_txn_process_listing_is_clear \
  "$process_matcher_app" '303 IdleScreenCameraAgent --external' "$process_matcher_lsof" ||
  fail "production process-list matcher rejected a non-owned executable path"
for unresolved_process_id in 404 405; do
  if IDLESCREEN_SYNTHETIC_TXN_FIXTURE_HELPER="$process_matcher_helper" \
     IDLESCREEN_SYNTHETIC_TXN_FIXTURE_EXTENSION="$process_matcher_extension" \
     synthetic_txn_process_listing_is_clear \
       "$process_matcher_app" "$unresolved_process_id IdleScreenCameraAgent --unresolved" \
       "$process_matcher_lsof"; then
    fail "production process-list matcher accepted unresolved marker ownership"
  fi
done

echo "PASS: synthetic gate transaction restores every rename/signal/crash state and refuses unsafe ownership."
