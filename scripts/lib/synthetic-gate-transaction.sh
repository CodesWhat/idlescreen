#!/bin/bash

# Durable transaction support for temporarily substituting the signed
# synthetic camera helper and topology-gate extension. This file is sourced by
# the public installer so fixture tests can replace physical-state adapters.

synthetic_txn_log_failure() {
  echo "FAIL: $*" >&2
}

synthetic_txn_identity() {
  local product_path="$1"
  local helper_path="$product_path/Contents/Helpers/IdleScreenCameraAgent.app"
  local extension_path="$product_path/Contents/PlugIns/IdleScreenScreenSaver.appex"
  local app_cdhash
  local helper_cdhash
  local extension_cdhash
  app_cdhash="$(/usr/bin/codesign -dv --verbose=4 "$product_path" 2>&1 |
    /usr/bin/awk -F= '$1 == "CDHash" { print $2; exit }')" || return 1
  helper_cdhash="$(/usr/bin/codesign -dv --verbose=4 "$helper_path" 2>&1 |
    /usr/bin/awk -F= '$1 == "CDHash" { print $2; exit }')" || return 1
  extension_cdhash="$(/usr/bin/codesign -dv --verbose=4 "$extension_path" 2>&1 |
    /usr/bin/awk -F= '$1 == "CDHash" { print $2; exit }')" || return 1
  [[ -n "$app_cdhash" && -n "$helper_cdhash" && -n "$extension_cdhash" ]] || return 1
  printf '%s\t%s\t%s\n' "$app_cdhash" "$helper_cdhash" "$extension_cdhash"
}

synthetic_txn_verify_production() {
  synthetic_txn_log_failure "production verifier callback was not installed"
  return 1
}

synthetic_txn_verify_gate() {
  synthetic_txn_log_failure "synthetic verifier callback was not installed"
  return 1
}

synthetic_txn_verify_signature_tree() {
  /usr/bin/codesign --verify --deep --strict "$1"
}

synthetic_txn_before_destructive_transition() {
  return 0
}

synthetic_txn_after_checkpoint() {
  return 0
}

synthetic_txn_capture_external_state() {
  synthetic_txn_log_failure "external-state capture callback was not installed"
  return 1
}

synthetic_txn_validate_external_state_snapshot() {
  synthetic_txn_log_failure "external-state snapshot validator was not installed"
  return 1
}

synthetic_txn_assert_stable_quiescence() {
  synthetic_txn_log_failure "stable-quiescence callback was not installed"
  return 1
}

synthetic_txn_validate_quiescence_inventory() {
  synthetic_txn_log_failure "quiescence-inventory validator was not installed"
  return 1
}

synthetic_txn_retire_production_registration() {
  synthetic_txn_log_failure "production-registration retirement callback was not installed"
  return 1
}

synthetic_txn_verify_production_registration_retired() {
  synthetic_txn_log_failure "production-registration retirement verifier was not installed"
  return 1
}

synthetic_txn_rebind_gate_registration() {
  synthetic_txn_log_failure "gate-registration callback was not installed"
  return 1
}

synthetic_txn_verify_gate_registration() {
  synthetic_txn_log_failure "gate-registration verification callback was not installed"
  return 1
}

synthetic_txn_capture_gate_bound_state() {
  synthetic_txn_log_failure "gate-bound state capture callback was not installed"
  return 1
}

synthetic_txn_validate_gate_bound_state() {
  synthetic_txn_log_failure "gate-bound state validator was not installed"
  return 1
}

synthetic_txn_retire_gate_registration() {
  synthetic_txn_log_failure "gate-registration retirement callback was not installed"
  return 1
}

synthetic_txn_verify_gate_registration_retired() {
  synthetic_txn_log_failure "gate-registration retirement verifier was not installed"
  return 1
}

synthetic_txn_restore_production_registration() {
  synthetic_txn_log_failure "production-registration restore callback was not installed"
  return 1
}

synthetic_txn_verify_production_registration() {
  synthetic_txn_log_failure "production-registration verifier was not installed"
  return 1
}

synthetic_txn_capture_post_restore_state() {
  synthetic_txn_log_failure "post-restore state capture callback was not installed"
  return 1
}

synthetic_txn_validate_post_restore_state() {
  synthetic_txn_log_failure "post-restore state validator was not installed"
  return 1
}

synthetic_txn_process_listing_is_clear() {
  local installed_app="$1"
  local process_listing="$2"
  local lsof_command="$3"
  local helper_executable="$installed_app/Contents/Helpers/IdleScreenCameraAgent.app/Contents/MacOS/IdleScreenCameraAgent"
  local extension_executable="$installed_app/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver"
  local process_id
  local process_command
  local process_executable
  local process_executable_count
  local process_lsof_output
  [[ "$lsof_command" = /* && -x "$lsof_command" ]] || return 1
  while read -r process_id process_command; do
    case "$process_command" in
      *IdleScreenCameraAgent*|*IdleScreenScreenSaver*) ;;
      *) continue ;;
    esac
    process_lsof_output="$("$lsof_command" -a -p "$process_id" -d txt -Fn 2>/dev/null)" ||
      return 1
    process_executable_count="$(/usr/bin/awk \
      'substr($0, 1, 1) == "n" && length($0) > 1 { count += 1 } END { print count + 0 }' \
      <<<"$process_lsof_output")"
    [[ "$process_executable_count" == 1 ]] || return 1
    process_executable="$(/usr/bin/awk \
      'substr($0, 1, 1) == "n" && length($0) > 1 { print substr($0, 2); exit }' \
      <<<"$process_lsof_output")"
    if [[ "$process_executable" == "$helper_executable" ||
          "$process_executable" == "$extension_executable" ]]; then
      return 1
    fi
  done <<<"$process_listing"
  return 0
}

synthetic_txn_processes_are_gone() {
  local installed_app="$1"
  local process_listing
  process_listing="$(/bin/ps -ww -axo pid=,command= 2>/dev/null)" || {
    echo "CRITICAL: could not enumerate processes before retiring the synthetic gate." >&2
    return 1
  }
  synthetic_txn_process_listing_is_clear \
    "$installed_app" "$process_listing" /usr/sbin/lsof
}

synthetic_txn_marker_processes_are_gone() {
  synthetic_txn_processes_are_gone "$1"
}

synthetic_txn_sha256_file() {
  /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{ print $1 }'
}

synthetic_txn_is_cdhash() {
  [[ "$1" =~ ^[[:xdigit:]]{40}$ || "$1" =~ ^[[:xdigit:]]{64}$ ]]
}

synthetic_txn_is_sha256() {
  [[ "$1" =~ ^[[:xdigit:]]{64}$ ]]
}

synthetic_txn_is_safe_absolute_path() {
  [[ "$1" = /* && "$1" != / && "$1" != *$'\t'* && "$1" != *$'\n'* ]]
}

synthetic_txn_configure_completion_evidence() {
  local requested_destination="${IDLESCREEN_SYNTHETIC_TXN_COMPLETION_EVIDENCE_DIR:-}"
  synthetic_txn_completion_evidence_directory=""
  [[ -n "$requested_destination" ]] || return 0
  synthetic_txn_is_safe_absolute_path "$requested_destination" || {
    synthetic_txn_log_failure \
      "completion evidence destination must be a safe absolute non-root path"
    return 64
  }
  local destination_parent
  local destination_leaf
  destination_parent="$(/usr/bin/dirname "$requested_destination")"
  destination_leaf="$(/usr/bin/basename "$requested_destination")"
  [[ -d "$destination_parent" && ! -L "$destination_parent" &&
     -n "$destination_leaf" && "$destination_leaf" != . &&
     "$destination_leaf" != .. ]] || {
    synthetic_txn_log_failure \
      "completion evidence parent must be an existing non-symlink directory"
    return 66
  }
  destination_parent="$(/bin/realpath "$destination_parent")" || return 66
  synthetic_txn_completion_evidence_directory="$destination_parent/$destination_leaf"
  case "$synthetic_txn_completion_evidence_directory" in
    "$synthetic_txn_installed"|"$synthetic_txn_installed"/*|\
    "$synthetic_txn_gate_candidate"|"$synthetic_txn_gate_candidate"/*|\
    "$synthetic_txn_directory"|"$synthetic_txn_directory"/*)
      synthetic_txn_log_failure \
        "completion evidence destination cannot overlap an app or transaction path"
      return 64
      ;;
  esac
  if [[ -e "$synthetic_txn_completion_evidence_directory" ||
        -L "$synthetic_txn_completion_evidence_directory" ]]; then
    [[ -d "$synthetic_txn_completion_evidence_directory" &&
       ! -L "$synthetic_txn_completion_evidence_directory" &&
       -d "$synthetic_txn_directory" && ! -L "$synthetic_txn_directory" ]] || {
      synthetic_txn_log_failure \
        "refusing an existing completion evidence destination for a new transaction"
      return 73
    }
  fi
}

synthetic_txn_completion_evidence_manifest_body() {
  local evidence_directory="$1"
  local journal_sha256 gate_manifest_sha256 pre_state_sha256
  local quiescence_inventory_sha256 gate_bound_state_sha256
  local post_restore_state_sha256
  journal_sha256="$(synthetic_txn_sha256_file \
    "$evidence_directory/transaction-journal.txt")" || return 1
  gate_manifest_sha256="$(synthetic_txn_sha256_file \
    "$evidence_directory/gate-manifest.txt")" || return 1
  pre_state_sha256="$(synthetic_txn_sha256_file \
    "$evidence_directory/pre-state.txt")" || return 1
  quiescence_inventory_sha256="$(synthetic_txn_sha256_file \
    "$evidence_directory/quiescence-inventory.txt")" || return 1
  gate_bound_state_sha256="$(synthetic_txn_sha256_file \
    "$evidence_directory/gate-bound-state.txt")" || return 1
  post_restore_state_sha256="$(synthetic_txn_sha256_file \
    "$evidence_directory/post-restore-state.txt")" || return 1
  local evidence_sha256
  for evidence_sha256 in \
    "$journal_sha256" "$gate_manifest_sha256" "$pre_state_sha256" \
    "$quiescence_inventory_sha256" "$gate_bound_state_sha256" \
    "$post_restore_state_sha256"; do
    synthetic_txn_is_sha256 "$evidence_sha256" || return 1
  done
  printf '%s\n' \
    'format=IdleScreenSyntheticGateTransactionCompletionEvidenceV1' \
    "transaction_id=$synthetic_txn_transaction_id" \
    'transaction_phase=cleanup' \
    "installed_app_path=$synthetic_txn_installed_path" \
    "gate_candidate_path=$synthetic_txn_gate_candidate_path" \
    "production_app_cdhash=$synthetic_txn_production_app" \
    "production_helper_cdhash=$synthetic_txn_production_helper" \
    "production_extension_cdhash=$synthetic_txn_production_extension" \
    "synthetic_app_cdhash=$synthetic_txn_synthetic_app" \
    "synthetic_helper_cdhash=$synthetic_txn_synthetic_helper" \
    "synthetic_extension_cdhash=$synthetic_txn_synthetic_extension" \
    'journal_file=transaction-journal.txt' \
    "journal_sha256=$journal_sha256" \
    'gate_manifest_file=gate-manifest.txt' \
    "gate_manifest_sha256=$gate_manifest_sha256" \
    'pre_state_file=pre-state.txt' \
    "pre_state_sha256=$pre_state_sha256" \
    'quiescence_inventory_file=quiescence-inventory.txt' \
    "quiescence_inventory_sha256=$quiescence_inventory_sha256" \
    'gate_bound_state_file=gate-bound-state.txt' \
    "gate_bound_state_sha256=$gate_bound_state_sha256" \
    'post_restore_state_file=post-restore-state.txt' \
    "post_restore_state_sha256=$post_restore_state_sha256"
}

synthetic_txn_validate_completion_evidence() {
  local evidence_directory="$1"
  [[ -d "$evidence_directory" && ! -L "$evidence_directory" ]] || return 1
  local exported_file
  for exported_file in \
    transaction-journal.txt gate-manifest.txt pre-state.txt \
    quiescence-inventory.txt gate-bound-state.txt post-restore-state.txt \
    completion-manifest.txt; do
    [[ -f "$evidence_directory/$exported_file" &&
       ! -L "$evidence_directory/$exported_file" ]] || return 1
  done
  [[ "$(/usr/bin/grep -Ec \
    '^[a-z_]+_sha256=[[:xdigit:]]{64}$' \
    "$evidence_directory/completion-manifest.txt")" == 6 ]] || return 1
  /usr/bin/cmp -s "$synthetic_txn_journal" \
    "$evidence_directory/transaction-journal.txt" || return 1
  /usr/bin/cmp -s "$synthetic_txn_manifest_snapshot" \
    "$evidence_directory/gate-manifest.txt" || return 1
  /usr/bin/cmp -s "$synthetic_txn_pre_state" \
    "$evidence_directory/pre-state.txt" || return 1
  /usr/bin/cmp -s "$synthetic_txn_quiescence_inventory" \
    "$evidence_directory/quiescence-inventory.txt" || return 1
  /usr/bin/cmp -s "$synthetic_txn_gate_bound_state" \
    "$evidence_directory/gate-bound-state.txt" || return 1
  /usr/bin/cmp -s "$synthetic_txn_post_restore_state" \
    "$evidence_directory/post-restore-state.txt" || return 1
  local expected_manifest
  expected_manifest="$(synthetic_txn_completion_evidence_manifest_body \
    "$evidence_directory")" || return 1
  [[ "$(<"$evidence_directory/completion-manifest.txt")" == "$expected_manifest" ]]
}

# Optional durable completion hook. The default remains a no-op unless the
# caller supplies a new absolute IDLESCREEN_SYNTHETIC_TXN_COMPLETION_EVIDENCE_DIR.
# Adapters may override this function, but cleanup proceeds only after it returns
# success while the cleanup-phase journal and all before/gate/after files exist.
synthetic_txn_preserve_completion_evidence() {
  local evidence_directory="${synthetic_txn_completion_evidence_directory:-}"
  [[ -n "$evidence_directory" ]] || return 0
  if ! synthetic_txn_is_sha256 "$synthetic_txn_quiescence_inventory_sha256" ||
     ! synthetic_txn_is_sha256 "$synthetic_txn_gate_bound_state_sha256" ||
     ! synthetic_txn_is_sha256 "$synthetic_txn_post_restore_state_sha256"; then
    echo "INFO: completion evidence was not exported because the transaction did not reach all before/gate/after evidence boundaries." >&2
    return 0
  fi
  if [[ -e "$evidence_directory" || -L "$evidence_directory" ]]; then
    synthetic_txn_validate_completion_evidence "$evidence_directory" || {
      synthetic_txn_log_failure \
        "existing completion evidence does not match the active transaction"
      return 1
    }
    return 0
  fi

  local staging_parent
  local staging_leaf
  local staging_directory
  staging_parent="$(/usr/bin/dirname "$evidence_directory")" || return 1
  staging_leaf="$(/usr/bin/basename "$evidence_directory")" || return 1
  staging_directory="$staging_parent/.${staging_leaf}.incomplete-$synthetic_txn_transaction_id"
  local exported_file
  [[ ! -e "$staging_directory" && ! -L "$staging_directory" ]] || {
    synthetic_txn_log_failure \
      "completion evidence staging path already exists: $staging_directory"
    return 1
  }
  /bin/mkdir -m 700 "$staging_directory" || return 1
  local copy_failed=0
  /bin/cp "$synthetic_txn_journal" \
    "$staging_directory/transaction-journal.txt" || copy_failed=1
  /bin/cp "$synthetic_txn_manifest_snapshot" \
    "$staging_directory/gate-manifest.txt" || copy_failed=1
  /bin/cp "$synthetic_txn_pre_state" \
    "$staging_directory/pre-state.txt" || copy_failed=1
  /bin/cp "$synthetic_txn_quiescence_inventory" \
    "$staging_directory/quiescence-inventory.txt" || copy_failed=1
  /bin/cp "$synthetic_txn_gate_bound_state" \
    "$staging_directory/gate-bound-state.txt" || copy_failed=1
  /bin/cp "$synthetic_txn_post_restore_state" \
    "$staging_directory/post-restore-state.txt" || copy_failed=1
  if [[ "$copy_failed" == 0 ]]; then
    synthetic_txn_completion_evidence_manifest_body "$staging_directory" \
      >"$staging_directory/completion-manifest.txt" || copy_failed=1
  fi
  if [[ "$copy_failed" != 0 ]] ||
     ! synthetic_txn_validate_completion_evidence "$staging_directory"; then
    for exported_file in \
      transaction-journal.txt gate-manifest.txt pre-state.txt \
      quiescence-inventory.txt gate-bound-state.txt post-restore-state.txt \
      completion-manifest.txt; do
      if [[ -f "$staging_directory/$exported_file" &&
            ! -L "$staging_directory/$exported_file" ]]; then
        /bin/rm "$staging_directory/$exported_file" || return 1
      fi
    done
    /bin/rmdir "$staging_directory" || return 1
    synthetic_txn_log_failure "could not create trustworthy completion evidence"
    return 1
  fi
  /bin/chmod a-w "$staging_directory"/* || return 1
  /bin/sync
  /bin/mv "$staging_directory" "$evidence_directory" || return 1
  /bin/sync
  synthetic_txn_validate_completion_evidence "$evidence_directory"
}

synthetic_txn_split_identity() {
  local product_path="$1"
  local identity
  identity="$(synthetic_txn_identity "$product_path")" || return 1
  [[ "$identity" == *$'\t'*$'\t'* && "$identity" != *$'\n'* ]] || return 1
  synthetic_txn_identity_app="${identity%%$'\t'*}"
  local remainder="${identity#*$'\t'}"
  synthetic_txn_identity_helper="${remainder%%$'\t'*}"
  synthetic_txn_identity_extension="${remainder#*$'\t'}"
  [[ -n "$synthetic_txn_identity_app" &&
     -n "$synthetic_txn_identity_helper" &&
     -n "$synthetic_txn_identity_extension" &&
     "$remainder" == *$'\t'* &&
     "$synthetic_txn_identity_extension" != *$'\t'* ]] || return 1
}

synthetic_txn_identity_equals() {
  local product_path="$1"
  local expected_app="$2"
  local expected_helper="$3"
  local expected_extension="$4"
  [[ -d "$product_path" && ! -L "$product_path" ]] || return 1
  synthetic_txn_split_identity "$product_path" || return 1
  [[ "$synthetic_txn_identity_app" == "$expected_app" &&
     "$synthetic_txn_identity_helper" == "$expected_helper" &&
     "$synthetic_txn_identity_extension" == "$expected_extension" ]]
}

synthetic_txn_verify_owned_production() {
  local product_path="$1"
  synthetic_txn_identity_equals "$product_path" \
    "$synthetic_txn_production_app" "$synthetic_txn_production_helper" \
    "$synthetic_txn_production_extension" || {
    synthetic_txn_log_failure "production CDHash tuple differs from the durable journal: $product_path"
    return 1
  }
  synthetic_txn_verify_signature_tree "$product_path" || {
    synthetic_txn_log_failure "production signature tree failed deep strict verification: $product_path"
    return 1
  }
  synthetic_txn_verify_production "$product_path" Release >/dev/null || {
    synthetic_txn_log_failure "production product/tree verification failed: $product_path"
    return 1
  }
}

synthetic_txn_verify_owned_synthetic() {
  local product_path="$1"
  local production_reference="$2"
  synthetic_txn_verify_owned_production "$production_reference" || return 1
  synthetic_txn_identity_equals "$product_path" \
    "$synthetic_txn_synthetic_app" "$synthetic_txn_synthetic_helper" \
    "$synthetic_txn_synthetic_extension" || {
    synthetic_txn_log_failure "synthetic CDHash tuple differs from the durable journal: $product_path"
    return 1
  }
  synthetic_txn_verify_signature_tree "$product_path" || {
    synthetic_txn_log_failure "synthetic signature tree failed deep strict verification: $product_path"
    return 1
  }
  synthetic_txn_verify_gate "$production_reference" "$product_path" \
    Release "$synthetic_txn_manifest" >/dev/null || {
    synthetic_txn_log_failure "synthetic product/tree manifest verification failed: $product_path"
    return 1
  }
}

synthetic_txn_verify_owned_product() {
  local kind="$1"
  local product_path="$2"
  local production_reference="${3:-}"
  case "$kind" in
    production)
      synthetic_txn_verify_owned_production "$product_path"
      ;;
    synthetic)
      [[ -n "$production_reference" ]] || return 1
      synthetic_txn_verify_owned_synthetic "$product_path" "$production_reference"
      ;;
    *)
      synthetic_txn_log_failure "unknown transaction product kind: $kind"
      return 1
      ;;
  esac
}

synthetic_txn_write_journal_body() {
  local destination="$1"
  local phase="$2"
  {
    printf 'format=4\n'
    printf 'phase=%s\n' "$phase"
    printf 'transaction_id=%s\n' "$synthetic_txn_transaction_id"
    printf 'production_app_cdhash=%s\n' "$synthetic_txn_production_app"
    printf 'production_helper_cdhash=%s\n' "$synthetic_txn_production_helper"
    printf 'production_extension_cdhash=%s\n' "$synthetic_txn_production_extension"
    printf 'synthetic_app_cdhash=%s\n' "$synthetic_txn_synthetic_app"
    printf 'synthetic_helper_cdhash=%s\n' "$synthetic_txn_synthetic_helper"
    printf 'synthetic_extension_cdhash=%s\n' "$synthetic_txn_synthetic_extension"
    printf 'installed_app_path=%s\n' "$synthetic_txn_installed_path"
    printf 'production_helper_path=%s\n' "$synthetic_txn_production_helper_path"
    printf 'production_extension_path=%s\n' "$synthetic_txn_production_extension_path"
    printf 'gate_candidate_path=%s\n' "$synthetic_txn_gate_candidate_path"
    printf 'synthetic_helper_path=%s\n' "$synthetic_txn_synthetic_helper_path"
    printf 'synthetic_extension_path=%s\n' "$synthetic_txn_synthetic_extension_path"
    printf 'manifest_sha256=%s\n' "$synthetic_txn_manifest_sha256"
    printf 'pre_state_sha256=%s\n' "$synthetic_txn_pre_state_sha256"
    printf 'quiescence_inventory_sha256=%s\n' "$synthetic_txn_quiescence_inventory_sha256"
    printf 'gate_bound_state_sha256=%s\n' "$synthetic_txn_gate_bound_state_sha256"
    printf 'post_restore_state_sha256=%s\n' "$synthetic_txn_post_restore_state_sha256"
  } >"$destination"
}

synthetic_txn_write_journal() {
  local phase="$1"
  local next_journal="$synthetic_txn_journal.next"
  synthetic_txn_critical=1
  if ! synthetic_txn_write_journal_body "$next_journal" "$phase"; then
    synthetic_txn_critical=0
    return 1
  fi
  /bin/sync
  if ! /bin/mv "$next_journal" "$synthetic_txn_journal"; then
    synthetic_txn_critical=0
    return 1
  fi
  /bin/sync
  synthetic_txn_phase="$phase"
  synthetic_txn_critical=0
  synthetic_txn_honor_pending_signal
}

synthetic_txn_abandon_unjournaled_transaction() {
  [[ ${synthetic_txn_active:-0} -eq 0 &&
     -d "$synthetic_txn_directory" &&
     ! -L "$synthetic_txn_directory" ]] || return 1
  synthetic_txn_critical=1
  local unjournaled_artifact
  for unjournaled_artifact in \
    "$synthetic_txn_journal.next" "$synthetic_txn_journal" \
    "$synthetic_txn_manifest_snapshot" "$synthetic_txn_pre_state" \
    "$synthetic_txn_quiescence_inventory" "$synthetic_txn_gate_bound_state" \
    "$synthetic_txn_post_restore_state"; do
    if [[ -e "$unjournaled_artifact" || -L "$unjournaled_artifact" ]]; then
      [[ -f "$unjournaled_artifact" && ! -L "$unjournaled_artifact" ]] || {
        synthetic_txn_critical=0
        return 1
      }
      /bin/rm "$unjournaled_artifact" || {
        synthetic_txn_critical=0
        return 1
      }
    fi
  done
  /bin/rmdir "$synthetic_txn_directory" || {
    synthetic_txn_critical=0
    return 1
  }
  /bin/sync
  synthetic_txn_critical=0
  synthetic_txn_honor_pending_signal
}

synthetic_txn_load_journal() {
  [[ -f "$synthetic_txn_journal" && ! -L "$synthetic_txn_journal" ]] || {
    synthetic_txn_log_failure "transaction directory has no trustworthy journal: $synthetic_txn_journal"
    return 1
  }
  local format=""
  local phase=""
  local transaction_id=""
  local production_app=""
  local production_helper=""
  local production_extension=""
  local synthetic_app=""
  local synthetic_helper=""
  local synthetic_extension=""
  local installed_app_path=""
  local production_helper_path=""
  local production_extension_path=""
  local gate_candidate_path=""
  local synthetic_helper_path=""
  local synthetic_extension_path=""
  local manifest_sha256=""
  local pre_state_sha256=""
  local quiescence_inventory_sha256=""
  local gate_bound_state_sha256=""
  local post_restore_state_sha256=""
  local key
  local value
  while IFS='=' read -r key value; do
    case "$key" in
      format) [[ -z "$format" ]] || return 1; format="$value" ;;
      phase) [[ -z "$phase" ]] || return 1; phase="$value" ;;
      transaction_id) [[ -z "$transaction_id" ]] || return 1; transaction_id="$value" ;;
      production_app_cdhash) [[ -z "$production_app" ]] || return 1; production_app="$value" ;;
      production_helper_cdhash) [[ -z "$production_helper" ]] || return 1; production_helper="$value" ;;
      production_extension_cdhash) [[ -z "$production_extension" ]] || return 1; production_extension="$value" ;;
      synthetic_app_cdhash) [[ -z "$synthetic_app" ]] || return 1; synthetic_app="$value" ;;
      synthetic_helper_cdhash) [[ -z "$synthetic_helper" ]] || return 1; synthetic_helper="$value" ;;
      synthetic_extension_cdhash) [[ -z "$synthetic_extension" ]] || return 1; synthetic_extension="$value" ;;
      installed_app_path) [[ -z "$installed_app_path" ]] || return 1; installed_app_path="$value" ;;
      production_helper_path) [[ -z "$production_helper_path" ]] || return 1; production_helper_path="$value" ;;
      production_extension_path) [[ -z "$production_extension_path" ]] || return 1; production_extension_path="$value" ;;
      gate_candidate_path) [[ -z "$gate_candidate_path" ]] || return 1; gate_candidate_path="$value" ;;
      synthetic_helper_path) [[ -z "$synthetic_helper_path" ]] || return 1; synthetic_helper_path="$value" ;;
      synthetic_extension_path) [[ -z "$synthetic_extension_path" ]] || return 1; synthetic_extension_path="$value" ;;
      manifest_sha256) [[ -z "$manifest_sha256" ]] || return 1; manifest_sha256="$value" ;;
      pre_state_sha256) [[ -z "$pre_state_sha256" ]] || return 1; pre_state_sha256="$value" ;;
      quiescence_inventory_sha256) [[ -z "$quiescence_inventory_sha256" ]] || return 1; quiescence_inventory_sha256="$value" ;;
      gate_bound_state_sha256) [[ -z "$gate_bound_state_sha256" ]] || return 1; gate_bound_state_sha256="$value" ;;
      post_restore_state_sha256) [[ -z "$post_restore_state_sha256" ]] || return 1; post_restore_state_sha256="$value" ;;
      *) return 1 ;;
    esac
  done <"$synthetic_txn_journal"
  [[ "$format" == 4 ]] || return 1
  case "$phase" in
    preparing|prepared|production_registration_retire_intent|production_registration_retired|quiescent|install_backup_intent|install_gate_intent|gate_rebind_intent|gate_bound|runner_active|awaiting_runner_cleanup|gate_registration_retire_intent|gate_registration_retired|retire_gate_intent|restore_production_intent|production_rebind_intent|production_rebound|cleanup) ;;
    *) return 1 ;;
  esac
  [[ "$transaction_id" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
  local journal_identity
  for journal_identity in \
    "$production_app" "$production_helper" "$production_extension" \
    "$synthetic_app" "$synthetic_helper" "$synthetic_extension"; do
    synthetic_txn_is_cdhash "$journal_identity" || return 1
  done
  [[ "$production_app" != "$synthetic_app" ||
     "$production_helper" != "$synthetic_helper" ||
     "$production_extension" != "$synthetic_extension" ]] || return 1
  local journal_path
  for journal_path in \
    "$installed_app_path" "$production_helper_path" "$production_extension_path" \
    "$gate_candidate_path" "$synthetic_helper_path" "$synthetic_extension_path"; do
    synthetic_txn_is_safe_absolute_path "$journal_path" || return 1
  done
  [[ "$installed_app_path" == "$synthetic_txn_installed" ]] || return 1
  [[ "$production_helper_path" == "$installed_app_path/Contents/Helpers/IdleScreenCameraAgent.app" ]] || return 1
  [[ "$production_extension_path" == "$installed_app_path/Contents/PlugIns/IdleScreenScreenSaver.appex" ]] || return 1
  [[ "$synthetic_helper_path" == "$gate_candidate_path/Contents/Helpers/IdleScreenCameraAgent.app" ]] || return 1
  [[ "$synthetic_extension_path" == "$gate_candidate_path/Contents/PlugIns/IdleScreenScreenSaver.appex" ]] || return 1
  synthetic_txn_is_sha256 "$manifest_sha256" || return 1
  synthetic_txn_is_sha256 "$pre_state_sha256" || return 1
  local evidence_digest
  for evidence_digest in \
    "$quiescence_inventory_sha256" "$gate_bound_state_sha256" \
    "$post_restore_state_sha256"; do
    [[ "$evidence_digest" == pending ]] || synthetic_txn_is_sha256 "$evidence_digest" || return 1
  done
  synthetic_txn_phase="$phase"
  synthetic_txn_transaction_id="$transaction_id"
  synthetic_txn_production_app="$production_app"
  synthetic_txn_production_helper="$production_helper"
  synthetic_txn_production_extension="$production_extension"
  synthetic_txn_synthetic_app="$synthetic_app"
  synthetic_txn_synthetic_helper="$synthetic_helper"
  synthetic_txn_synthetic_extension="$synthetic_extension"
  synthetic_txn_installed_path="$installed_app_path"
  synthetic_txn_production_helper_path="$production_helper_path"
  synthetic_txn_production_extension_path="$production_extension_path"
  synthetic_txn_gate_candidate_path="$gate_candidate_path"
  synthetic_txn_synthetic_helper_path="$synthetic_helper_path"
  synthetic_txn_synthetic_extension_path="$synthetic_extension_path"
  synthetic_txn_manifest_sha256="$manifest_sha256"
  synthetic_txn_pre_state_sha256="$pre_state_sha256"
  synthetic_txn_quiescence_inventory_sha256="$quiescence_inventory_sha256"
  synthetic_txn_gate_bound_state_sha256="$gate_bound_state_sha256"
  synthetic_txn_post_restore_state_sha256="$post_restore_state_sha256"
  synthetic_txn_preserved_external="$synthetic_txn_parent/.${synthetic_txn_leaf}.external-preserved-${transaction_id}"
  [[ -f "$synthetic_txn_manifest_snapshot" && ! -L "$synthetic_txn_manifest_snapshot" &&
     "$(synthetic_txn_sha256_file "$synthetic_txn_manifest_snapshot")" == "$synthetic_txn_manifest_sha256" ]] || return 1
  [[ -f "$synthetic_txn_pre_state" && ! -L "$synthetic_txn_pre_state" &&
     "$(synthetic_txn_sha256_file "$synthetic_txn_pre_state")" == "$synthetic_txn_pre_state_sha256" ]] || return 1
  synthetic_txn_validate_external_state_snapshot "$synthetic_txn_pre_state" || return 1
  if [[ "$synthetic_txn_quiescence_inventory_sha256" != pending ]]; then
    [[ -f "$synthetic_txn_quiescence_inventory" && ! -L "$synthetic_txn_quiescence_inventory" &&
       "$(synthetic_txn_sha256_file "$synthetic_txn_quiescence_inventory")" == "$synthetic_txn_quiescence_inventory_sha256" ]] || return 1
    synthetic_txn_validate_quiescence_inventory "$synthetic_txn_quiescence_inventory" || return 1
  fi
  if [[ "$synthetic_txn_gate_bound_state_sha256" != pending ]]; then
    [[ -f "$synthetic_txn_gate_bound_state" && ! -L "$synthetic_txn_gate_bound_state" &&
       "$(synthetic_txn_sha256_file "$synthetic_txn_gate_bound_state")" == "$synthetic_txn_gate_bound_state_sha256" ]] || return 1
    synthetic_txn_validate_gate_bound_state "$synthetic_txn_gate_bound_state" || return 1
  fi
  if [[ "$synthetic_txn_post_restore_state_sha256" != pending ]]; then
    [[ -f "$synthetic_txn_post_restore_state" && ! -L "$synthetic_txn_post_restore_state" &&
       "$(synthetic_txn_sha256_file "$synthetic_txn_post_restore_state")" == "$synthetic_txn_post_restore_state_sha256" ]] || return 1
    synthetic_txn_validate_post_restore_state "$synthetic_txn_post_restore_state" || return 1
  fi
  synthetic_txn_manifest="$synthetic_txn_manifest_snapshot"
}

synthetic_txn_validate_owned_paths() {
  if [[ -e "$synthetic_txn_backup" ]] &&
     ! synthetic_txn_verify_owned_production "$synthetic_txn_backup"; then
    synthetic_txn_log_failure "production backup identity is not owned by this journal: $synthetic_txn_backup"
    return 1
  fi
  local production_reference=""
  if [[ -e "$synthetic_txn_backup" ]]; then
    production_reference="$synthetic_txn_backup"
  elif synthetic_txn_identity_equals "$synthetic_txn_installed" \
    "$synthetic_txn_production_app" "$synthetic_txn_production_helper" \
    "$synthetic_txn_production_extension"; then
    production_reference="$synthetic_txn_installed"
  fi
  local gate_path
  for gate_path in "$synthetic_txn_staging" "$synthetic_txn_retired"; do
    if [[ -e "$gate_path" ]] &&
       { [[ -z "$production_reference" ]] ||
         ! synthetic_txn_verify_owned_synthetic "$gate_path" "$production_reference"; }; then
      synthetic_txn_log_failure "synthetic transaction identity is not owned by this journal: $gate_path"
      return 1
    fi
  done
  if [[ -e "$synthetic_txn_preserved_external" ]]; then
    [[ -d "$synthetic_txn_preserved_external" &&
       ! -L "$synthetic_txn_preserved_external" ]] || {
      synthetic_txn_log_failure "preserved external path is not a real app directory"
      return 1
    }
    synthetic_txn_split_identity "$synthetic_txn_preserved_external" || {
      synthetic_txn_log_failure "preserved external app has no readable app/helper/extension identity"
      return 1
    }
  fi
  if [[ -e "$synthetic_txn_journal.next" && ! -f "$synthetic_txn_journal.next" ]]; then
    synthetic_txn_log_failure "journal staging path was replaced externally"
    return 1
  fi
  local evidence_path
  for evidence_path in \
    "$synthetic_txn_quiescence_inventory" "$synthetic_txn_gate_bound_state" \
    "$synthetic_txn_post_restore_state"; do
    if [[ -e "$evidence_path" || -L "$evidence_path" ]]; then
      [[ -f "$evidence_path" && ! -L "$evidence_path" ]] || {
        synthetic_txn_log_failure "transaction evidence path was replaced externally: $evidence_path"
        return 1
      }
    fi
  done
}

synthetic_txn_remove_exact() {
  local product_path="$1"
  local kind="$2"
  local production_reference="${3:-}"
  synthetic_txn_verify_owned_product "$kind" "$product_path" "$production_reference" || {
    synthetic_txn_log_failure "refusing to delete a product without current strict journal-owned verification: $product_path"
    return 1
  }
  synthetic_txn_before_destructive_transition delete "$kind" "$product_path" || return 1
  /bin/rm -rf -- "$product_path"
}

synthetic_txn_move_exact() {
  local source_path="$1"
  local destination_path="$2"
  local kind="$3"
  local production_reference="${4:-}"
  synthetic_txn_verify_owned_product "$kind" "$source_path" "$production_reference" || {
    synthetic_txn_log_failure "refusing to move a product without current strict journal-owned verification: $source_path"
    return 1
  }
  [[ ! -e "$destination_path" && ! -L "$destination_path" ]] || {
    synthetic_txn_log_failure "refusing to overwrite a transaction destination: $destination_path"
    return 1
  }
  synthetic_txn_before_destructive_transition move "$kind" "$source_path" || return 1
  /bin/mv "$source_path" "$destination_path"
  /bin/sync
  [[ ! -e "$source_path" ]] || return 1
  synthetic_txn_verify_owned_product "$kind" "$destination_path" "$production_reference"
}

synthetic_txn_preserve_external_installed() {
  [[ -d "$synthetic_txn_installed" && ! -L "$synthetic_txn_installed" ]] || {
    synthetic_txn_log_failure "external installed replacement is not a real app directory"
    return 1
  }
  synthetic_txn_split_identity "$synthetic_txn_installed" || {
    synthetic_txn_log_failure "external installed replacement has no readable app/helper/extension identity"
    return 1
  }
  [[ ! -e "$synthetic_txn_preserved_external" &&
     ! -L "$synthetic_txn_preserved_external" ]] || {
    synthetic_txn_log_failure "external preservation destination already exists: $synthetic_txn_preserved_external"
    return 1
  }
  synthetic_txn_verify_signature_tree "$synthetic_txn_installed" || {
    synthetic_txn_log_failure "external installed replacement is not a valid strict signature tree; preserving it in place"
    return 1
  }
  synthetic_txn_before_destructive_transition preserve external "$synthetic_txn_installed" || return 1
  /bin/mv "$synthetic_txn_installed" "$synthetic_txn_preserved_external"
  /bin/sync
  synthetic_txn_after_checkpoint after_external_preservation
}

synthetic_txn_installed_gate_is_transaction_owned() {
  case "$synthetic_txn_phase" in
    install_gate_intent|gate_rebind_intent|gate_bound|runner_active|awaiting_runner_cleanup|gate_registration_retire_intent|gate_registration_retired|retire_gate_intent|restore_production_intent|production_rebind_intent|production_rebound|cleanup)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

synthetic_txn_phase_may_have_gate_registration() {
  case "$1" in
    gate_rebind_intent|gate_bound|runner_active|awaiting_runner_cleanup|gate_registration_retire_intent)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

synthetic_txn_phase_may_have_retired_production_registration() {
  case "$1" in
    production_registration_retire_intent|production_registration_retired|quiescent|install_backup_intent|install_gate_intent|gate_rebind_intent|gate_bound|runner_active|awaiting_runner_cleanup|gate_registration_retire_intent|gate_registration_retired|retire_gate_intent|restore_production_intent|production_rebind_intent)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

synthetic_txn_recover_loaded_transaction() {
  synthetic_txn_restoring=1
  local recovery_phase="$synthetic_txn_phase"
  synthetic_txn_validate_owned_paths || {
    synthetic_txn_restoring=0
    return 70
  }

  local installed_kind=missing
  if [[ -e "$synthetic_txn_installed" || -L "$synthetic_txn_installed" ]]; then
    if synthetic_txn_identity_equals "$synthetic_txn_installed" \
      "$synthetic_txn_production_app" "$synthetic_txn_production_helper" \
      "$synthetic_txn_production_extension"; then
      installed_kind=production
    elif synthetic_txn_identity_equals "$synthetic_txn_installed" \
      "$synthetic_txn_synthetic_app" "$synthetic_txn_synthetic_helper" \
      "$synthetic_txn_synthetic_extension"; then
      installed_kind=synthetic
    else
      installed_kind=external
    fi
  fi

  if [[ "$installed_kind" == external ]] ||
     { [[ "$installed_kind" == synthetic ]] &&
       ! synthetic_txn_installed_gate_is_transaction_owned; }; then
    synthetic_txn_preserve_external_installed || {
      synthetic_txn_restoring=0
      return 70
    }
    installed_kind=missing
  fi

  if synthetic_txn_phase_may_have_gate_registration "$recovery_phase"; then
    [[ "$installed_kind" == synthetic && -e "$synthetic_txn_backup" ]] || {
      synthetic_txn_log_failure "gate-registration retirement target is not the journal-owned installed synthetic product"
      synthetic_txn_restoring=0
      return 70
    }
    synthetic_txn_verify_owned_synthetic \
      "$synthetic_txn_installed" "$synthetic_txn_backup" || {
      synthetic_txn_restoring=0
      return 70
    }
    synthetic_txn_write_journal gate_registration_retire_intent || return 70
    synthetic_txn_retire_gate_registration "$synthetic_txn_installed" || {
      synthetic_txn_restoring=0
      return 70
    }
    synthetic_txn_verify_gate_registration_retired "$synthetic_txn_installed" || {
      synthetic_txn_log_failure "gate service/PlugInKit registration did not retire cleanly"
      synthetic_txn_restoring=0
      return 70
    }
    synthetic_txn_write_journal gate_registration_retired || return 70
    synthetic_txn_after_checkpoint after_gate_registration_retire
  fi

  local marker_product
  for marker_product in "$synthetic_txn_installed" "$synthetic_txn_retired"; do
    [[ -d "$marker_product" && ! -L "$marker_product" ]] || continue
    if synthetic_txn_identity_equals "$marker_product" \
         "$synthetic_txn_synthetic_app" "$synthetic_txn_synthetic_helper" \
         "$synthetic_txn_synthetic_extension" &&
       ! synthetic_txn_marker_processes_are_gone "$marker_product"; then
      synthetic_txn_restore_blocked=1
      synthetic_txn_restoring=0
      echo "CRITICAL: a marker-bearing helper or hosted-extension process remains; retaining the signed gate and recovery journal." >&2
      return 70
    fi
  done

  if [[ "$installed_kind" == synthetic ]]; then
    [[ ! -e "$synthetic_txn_retired" ]] || {
      synthetic_txn_log_failure "both installed and retired synthetic products exist; refusing ambiguous cleanup"
      synthetic_txn_restoring=0
      return 70
    }
    synthetic_txn_write_journal retire_gate_intent || return 70
    synthetic_txn_move_exact "$synthetic_txn_installed" "$synthetic_txn_retired" \
      synthetic "$synthetic_txn_backup" || return 70
    synthetic_txn_after_checkpoint after_gate_retire
    installed_kind=missing
  fi

  if [[ "$installed_kind" == missing ]]; then
    [[ -e "$synthetic_txn_backup" ]] || {
      synthetic_txn_log_failure "production is missing and no exact journal-owned backup exists"
      synthetic_txn_restoring=0
      return 70
    }
    synthetic_txn_write_journal restore_production_intent || return 70
    synthetic_txn_move_exact "$synthetic_txn_backup" "$synthetic_txn_installed" \
      production || return 70
    synthetic_txn_after_checkpoint after_production_restore
    installed_kind=production
  fi

  synthetic_txn_verify_owned_production "$synthetic_txn_installed" || {
    synthetic_txn_log_failure "canonical path does not contain the exact pre-transaction production identities"
    synthetic_txn_restoring=0
    return 70
  }
  if synthetic_txn_phase_may_have_retired_production_registration "$recovery_phase"; then
    synthetic_txn_write_journal production_rebind_intent || return 70
    synthetic_txn_restore_production_registration "$synthetic_txn_pre_state" || {
      synthetic_txn_restoring=0
      return 70
    }
    synthetic_txn_verify_production_registration "$synthetic_txn_pre_state" || {
      synthetic_txn_log_failure "production service/PlugInKit/selection state did not reconverge exactly"
      synthetic_txn_restoring=0
      return 70
    }
    synthetic_txn_capture_post_restore_state \
      "$synthetic_txn_post_restore_state" "$synthetic_txn_installed" || {
      synthetic_txn_restoring=0
      return 70
    }
    [[ -f "$synthetic_txn_post_restore_state" &&
       ! -L "$synthetic_txn_post_restore_state" ]] || {
      synthetic_txn_restoring=0
      return 70
    }
    synthetic_txn_validate_post_restore_state "$synthetic_txn_post_restore_state" || {
      synthetic_txn_restoring=0
      return 70
    }
    /usr/bin/cmp -s "$synthetic_txn_pre_state" "$synthetic_txn_post_restore_state" || {
      synthetic_txn_log_failure "post-restore state differs byte-for-byte from the durable pre-state"
      synthetic_txn_restoring=0
      return 70
    }
    synthetic_txn_post_restore_state_sha256="$(synthetic_txn_sha256_file "$synthetic_txn_post_restore_state")" || {
      synthetic_txn_restoring=0
      return 70
    }
    synthetic_txn_is_sha256 "$synthetic_txn_post_restore_state_sha256" || {
      synthetic_txn_restoring=0
      return 70
    }
    synthetic_txn_write_journal production_rebound || return 70
    synthetic_txn_after_checkpoint after_production_rebind
  fi
  synthetic_txn_write_journal cleanup || return 70
  synthetic_txn_preserve_completion_evidence || {
    synthetic_txn_log_failure \
      "completion evidence export failed; retaining the cleanup journal and transaction artifacts"
    return 70
  }
  synthetic_txn_after_checkpoint after_completion_evidence_export
  if [[ -e "$synthetic_txn_backup" ]]; then
    synthetic_txn_remove_exact "$synthetic_txn_backup" production || return 70
  fi
  if [[ -e "$synthetic_txn_staging" ]]; then
    synthetic_txn_remove_exact "$synthetic_txn_staging" synthetic \
      "$synthetic_txn_installed" || return 70
  fi
  if [[ -e "$synthetic_txn_retired" ]]; then
    synthetic_txn_remove_exact "$synthetic_txn_retired" synthetic \
      "$synthetic_txn_installed" || return 70
  fi
  if [[ -e "$synthetic_txn_journal.next" ]]; then
    [[ -f "$synthetic_txn_journal.next" && ! -L "$synthetic_txn_journal.next" ]] || return 70
    /bin/rm "$synthetic_txn_journal.next"
  fi
  local transaction_artifact
  for transaction_artifact in \
    "$synthetic_txn_manifest_snapshot" "$synthetic_txn_pre_state" \
    "$synthetic_txn_quiescence_inventory" "$synthetic_txn_gate_bound_state" \
    "$synthetic_txn_post_restore_state"; do
    if [[ -e "$transaction_artifact" || -L "$transaction_artifact" ]]; then
      [[ -f "$transaction_artifact" && ! -L "$transaction_artifact" ]] || return 70
      /bin/rm "$transaction_artifact" || return 70
    fi
  done
  /bin/rm "$synthetic_txn_journal"
  /bin/rmdir "$synthetic_txn_directory" || return 70
  /bin/sync
  synthetic_txn_active=0
  synthetic_txn_restoring=0
  synthetic_txn_restore_blocked=0
  return 0
}

synthetic_txn_recover_existing_transaction() {
  [[ -d "$synthetic_txn_directory" && ! -L "$synthetic_txn_directory" ]] || {
    synthetic_txn_log_failure "transaction path is not a real directory: $synthetic_txn_directory"
    return 70
  }
  synthetic_txn_load_journal || {
    synthetic_txn_log_failure "transaction journal is malformed; refusing automatic mutation"
    return 70
  }
  synthetic_txn_active=1
  synthetic_txn_recover_loaded_transaction
}

synthetic_txn_honor_pending_signal() {
  if [[ ${synthetic_txn_signal_exit:-0} -ne 0 &&
        ${synthetic_txn_critical:-0} -eq 0 &&
        ${synthetic_txn_restoring:-0} -eq 0 ]]; then
    synthetic_txn_handle_signal "$synthetic_txn_signal_exit"
  fi
}

synthetic_txn_handle_signal() {
  local signal_exit="$1"
  synthetic_txn_signal_exit="$signal_exit"
  if [[ ${synthetic_txn_critical:-0} -eq 1 ||
        ${synthetic_txn_restoring:-0} -eq 1 ]]; then
    return 0
  fi
  if [[ ${synthetic_txn_active:-0} -eq 1 ]]; then
    if ! synthetic_txn_recover_loaded_transaction; then
      synthetic_txn_restore_blocked=1
      exit 70
    fi
  fi
  exit "$signal_exit"
}

synthetic_txn_handle_exit() {
  local original_exit=$?
  trap - EXIT
  if [[ ${synthetic_txn_active:-0} -eq 1 &&
        ${synthetic_txn_restore_blocked:-0} -eq 0 ]]; then
    if ! synthetic_txn_recover_loaded_transaction; then
      exit 70
    fi
  fi
  exit "$original_exit"
}

synthetic_gate_transaction_run() {
  [[ $# -ge 5 ]] || {
    synthetic_txn_log_failure "transaction API requires installed app, gate, manifest, --, and runner"
    return 64
  }
  synthetic_txn_installed="$1"
  synthetic_txn_gate_candidate="$2"
  synthetic_txn_manifest="$3"
  [[ "$4" == -- ]] || return 64
  shift 4
  synthetic_txn_runner=("$@")
  [[ "$synthetic_txn_installed" = /* &&
     "$synthetic_txn_gate_candidate" = /* &&
     "$synthetic_txn_manifest" = /* &&
     "${synthetic_txn_runner[0]}" = /* &&
     -x "${synthetic_txn_runner[0]}" ]] || return 64

  synthetic_txn_parent="$(/bin/realpath "$(/usr/bin/dirname "$synthetic_txn_installed")")" || return 66
  synthetic_txn_leaf="$(/usr/bin/basename "$synthetic_txn_installed")"
  [[ -n "$synthetic_txn_leaf" && "$synthetic_txn_leaf" != . && "$synthetic_txn_leaf" != .. ]] || return 64
  synthetic_txn_installed="$synthetic_txn_parent/$synthetic_txn_leaf"
  [[ -d "$synthetic_txn_gate_candidate" && ! -L "$synthetic_txn_gate_candidate" ]] || return 66
  [[ -f "$synthetic_txn_manifest" && ! -L "$synthetic_txn_manifest" ]] || return 66
  synthetic_txn_requested_gate_candidate="$(/bin/realpath "$synthetic_txn_gate_candidate")" || return 66
  synthetic_txn_requested_manifest="$(/bin/realpath "$synthetic_txn_manifest")" || return 66
  synthetic_txn_gate_candidate="$synthetic_txn_requested_gate_candidate"
  synthetic_txn_manifest="$synthetic_txn_requested_manifest"
  synthetic_txn_directory="$synthetic_txn_parent/.${synthetic_txn_leaf}.synthetic-transaction"
  synthetic_txn_lock="$synthetic_txn_parent/.${synthetic_txn_leaf}.synthetic-transaction.lock"
  synthetic_txn_journal="$synthetic_txn_directory/journal"
  synthetic_txn_backup="$synthetic_txn_directory/production.app"
  synthetic_txn_staging="$synthetic_txn_directory/staging.app"
  synthetic_txn_retired="$synthetic_txn_directory/retired.app"
  synthetic_txn_manifest_snapshot="$synthetic_txn_directory/manifest"
  synthetic_txn_pre_state="$synthetic_txn_directory/pre-state"
  synthetic_txn_quiescence_inventory="$synthetic_txn_directory/quiescence-inventory"
  synthetic_txn_gate_bound_state="$synthetic_txn_directory/gate-bound-state"
  synthetic_txn_post_restore_state="$synthetic_txn_directory/post-restore-state"
  synthetic_txn_active=0
  synthetic_txn_critical=0
  synthetic_txn_restoring=0
  synthetic_txn_restore_blocked=0
  synthetic_txn_signal_exit=0
  synthetic_txn_configure_completion_evidence || return $?

  exec 8>"$synthetic_txn_lock" || return 73
  if ! /usr/bin/lockf -s -t 0 8; then
    exec 8>&-
    synthetic_txn_log_failure "another synthetic gate transaction holds $synthetic_txn_lock"
    return 75
  fi
  trap synthetic_txn_handle_exit EXIT
  trap 'synthetic_txn_handle_signal 130' INT
  trap 'synthetic_txn_handle_signal 143' TERM
  trap 'synthetic_txn_handle_signal 129' HUP

  if [[ -e "$synthetic_txn_directory" || -L "$synthetic_txn_directory" ]]; then
    echo "RECOVERY: durable synthetic transaction journal found; restoring exact production before any new gate run."
    synthetic_txn_recover_existing_transaction || return $?
    synthetic_txn_gate_candidate="$synthetic_txn_requested_gate_candidate"
    synthetic_txn_manifest="$synthetic_txn_requested_manifest"
  fi

  [[ -d "$synthetic_txn_installed" && ! -L "$synthetic_txn_installed" ]] || return 66
  [[ "$synthetic_txn_installed" != "$synthetic_txn_gate_candidate" ]] || return 64
  synthetic_txn_verify_production "$synthetic_txn_installed" Release || return 1
  synthetic_txn_verify_signature_tree "$synthetic_txn_installed" || return 1
  synthetic_txn_verify_gate "$synthetic_txn_installed" "$synthetic_txn_gate_candidate" \
    Release "$synthetic_txn_manifest" || return 1
  synthetic_txn_verify_signature_tree "$synthetic_txn_gate_candidate" || return 1
  synthetic_txn_split_identity "$synthetic_txn_installed" || return 1
  synthetic_txn_production_app="$synthetic_txn_identity_app"
  synthetic_txn_production_helper="$synthetic_txn_identity_helper"
  synthetic_txn_production_extension="$synthetic_txn_identity_extension"
  synthetic_txn_split_identity "$synthetic_txn_gate_candidate" || return 1
  synthetic_txn_synthetic_app="$synthetic_txn_identity_app"
  synthetic_txn_synthetic_helper="$synthetic_txn_identity_helper"
  synthetic_txn_synthetic_extension="$synthetic_txn_identity_extension"
  local transaction_identity
  for transaction_identity in \
    "$synthetic_txn_production_app" "$synthetic_txn_production_helper" \
    "$synthetic_txn_production_extension" "$synthetic_txn_synthetic_app" \
    "$synthetic_txn_synthetic_helper" "$synthetic_txn_synthetic_extension"; do
    synthetic_txn_is_cdhash "$transaction_identity" || {
      synthetic_txn_log_failure "transaction product has a malformed CDHash: $transaction_identity"
      return 1
    }
  done
  [[ "$synthetic_txn_production_app" != "$synthetic_txn_synthetic_app" ||
     "$synthetic_txn_production_helper" != "$synthetic_txn_synthetic_helper" ||
     "$synthetic_txn_production_extension" != "$synthetic_txn_synthetic_extension" ]] || return 1
  synthetic_txn_installed_path="$synthetic_txn_installed"
  synthetic_txn_production_helper_path="$synthetic_txn_installed/Contents/Helpers/IdleScreenCameraAgent.app"
  synthetic_txn_production_extension_path="$synthetic_txn_installed/Contents/PlugIns/IdleScreenScreenSaver.appex"
  synthetic_txn_gate_candidate_path="$synthetic_txn_gate_candidate"
  synthetic_txn_synthetic_helper_path="$synthetic_txn_gate_candidate/Contents/Helpers/IdleScreenCameraAgent.app"
  synthetic_txn_synthetic_extension_path="$synthetic_txn_gate_candidate/Contents/PlugIns/IdleScreenScreenSaver.appex"
  synthetic_txn_transaction_id="$$-$(/bin/date +%s)"
  synthetic_txn_preserved_external="$synthetic_txn_parent/.${synthetic_txn_leaf}.external-preserved-${synthetic_txn_transaction_id}"

  synthetic_txn_critical=1
  /bin/mkdir "$synthetic_txn_directory" || return 1
  if ! /usr/bin/ditto "$synthetic_txn_manifest" "$synthetic_txn_manifest_snapshot"; then
    synthetic_txn_abandon_unjournaled_transaction || return 70
    return 1
  fi
  if ! synthetic_txn_capture_external_state "$synthetic_txn_pre_state"; then
    synthetic_txn_abandon_unjournaled_transaction || return 70
    return 1
  fi
  if [[ ! -f "$synthetic_txn_pre_state" || -L "$synthetic_txn_pre_state" ]] ||
     ! synthetic_txn_validate_external_state_snapshot "$synthetic_txn_pre_state"; then
    synthetic_txn_abandon_unjournaled_transaction || return 70
    return 1
  fi
  if ! synthetic_txn_manifest_sha256="$(synthetic_txn_sha256_file "$synthetic_txn_manifest_snapshot")"; then
    synthetic_txn_abandon_unjournaled_transaction || return 70
    return 1
  fi
  if ! synthetic_txn_pre_state_sha256="$(synthetic_txn_sha256_file "$synthetic_txn_pre_state")"; then
    synthetic_txn_abandon_unjournaled_transaction || return 70
    return 1
  fi
  if ! synthetic_txn_is_sha256 "$synthetic_txn_manifest_sha256" ||
     ! synthetic_txn_is_sha256 "$synthetic_txn_pre_state_sha256"; then
    synthetic_txn_abandon_unjournaled_transaction || return 70
    return 1
  fi
  synthetic_txn_quiescence_inventory_sha256=pending
  synthetic_txn_gate_bound_state_sha256=pending
  synthetic_txn_post_restore_state_sha256=pending
  synthetic_txn_manifest="$synthetic_txn_manifest_snapshot"
  if ! synthetic_txn_write_journal_body "$synthetic_txn_journal" preparing; then
    synthetic_txn_abandon_unjournaled_transaction || return 70
    return 1
  fi
  synthetic_txn_phase=preparing
  synthetic_txn_active=1
  /bin/sync
  synthetic_txn_critical=0
  synthetic_txn_honor_pending_signal

  /usr/bin/ditto "$synthetic_txn_gate_candidate" "$synthetic_txn_staging"
  synthetic_txn_verify_gate "$synthetic_txn_installed" "$synthetic_txn_staging" \
    Release "$synthetic_txn_manifest" || return 1
  synthetic_txn_identity_equals "$synthetic_txn_staging" \
    "$synthetic_txn_synthetic_app" "$synthetic_txn_synthetic_helper" \
    "$synthetic_txn_synthetic_extension" || return 1
  /bin/sync
  synthetic_txn_after_checkpoint after_gate_staging
  synthetic_txn_verify_owned_synthetic "$synthetic_txn_staging" \
    "$synthetic_txn_installed" || return 1
  synthetic_txn_write_journal prepared

  synthetic_txn_write_journal production_registration_retire_intent
  synthetic_txn_retire_production_registration "$synthetic_txn_installed" || return 1
  synthetic_txn_verify_production_registration_retired "$synthetic_txn_installed" || {
    synthetic_txn_log_failure "production service/PlugInKit registration did not retire cleanly"
    return 1
  }
  synthetic_txn_write_journal production_registration_retired
  synthetic_txn_after_checkpoint after_production_registration_retire

  synthetic_txn_assert_stable_quiescence \
    "$synthetic_txn_quiescence_inventory" \
    "$synthetic_txn_installed" "$synthetic_txn_gate_candidate" || {
    synthetic_txn_log_failure "production/gate processes are not stably quiescent before replacement"
    return 65
  }
  [[ -f "$synthetic_txn_quiescence_inventory" &&
     ! -L "$synthetic_txn_quiescence_inventory" ]] || return 1
  synthetic_txn_validate_quiescence_inventory "$synthetic_txn_quiescence_inventory" || return 1
  synthetic_txn_quiescence_inventory_sha256="$(synthetic_txn_sha256_file "$synthetic_txn_quiescence_inventory")" || return 1
  synthetic_txn_is_sha256 "$synthetic_txn_quiescence_inventory_sha256" || return 1
  synthetic_txn_write_journal quiescent
  synthetic_txn_after_checkpoint after_quiescence_evidence

  synthetic_txn_write_journal install_backup_intent
  synthetic_txn_move_exact "$synthetic_txn_installed" "$synthetic_txn_backup" \
    production || return 1
  synthetic_txn_after_checkpoint after_production_backup

  synthetic_txn_write_journal install_gate_intent
  synthetic_txn_move_exact "$synthetic_txn_staging" "$synthetic_txn_installed" \
    synthetic "$synthetic_txn_backup" || return 1
  synthetic_txn_after_checkpoint after_gate_install
  synthetic_txn_verify_gate "$synthetic_txn_backup" "$synthetic_txn_installed" \
    Release "$synthetic_txn_manifest" || return 1
  synthetic_txn_write_journal gate_rebind_intent
  synthetic_txn_rebind_gate_registration "$synthetic_txn_installed" || return 1
  synthetic_txn_verify_gate_registration "$synthetic_txn_installed" || {
    synthetic_txn_log_failure "gate service/PlugInKit registration did not converge"
    return 1
  }
  synthetic_txn_capture_gate_bound_state \
    "$synthetic_txn_gate_bound_state" "$synthetic_txn_installed" || return 1
  [[ -f "$synthetic_txn_gate_bound_state" &&
     ! -L "$synthetic_txn_gate_bound_state" ]] || return 1
  synthetic_txn_validate_gate_bound_state "$synthetic_txn_gate_bound_state" || return 1
  synthetic_txn_gate_bound_state_sha256="$(synthetic_txn_sha256_file "$synthetic_txn_gate_bound_state")" || return 1
  synthetic_txn_is_sha256 "$synthetic_txn_gate_bound_state_sha256" || return 1
  synthetic_txn_write_journal gate_bound
  synthetic_txn_after_checkpoint after_gate_rebind

  echo "PASS: marker-bearing helper and hosted extension installed and rebound transactionally for the explicit runner."
  synthetic_txn_write_journal runner_active
  local runner_exit
  set +e
  ("${synthetic_txn_runner[@]}") 8>&-
  runner_exit=$?
  set -e
  synthetic_txn_write_journal awaiting_runner_cleanup

  synthetic_txn_recover_loaded_transaction || return 70
  local final_exit="$runner_exit"
  if [[ $synthetic_txn_signal_exit -ne 0 ]]; then
    final_exit="$synthetic_txn_signal_exit"
  fi
  trap - EXIT INT TERM HUP
  exec 8>&-
  echo "PASS: exact production app/helper/extension and registration state restored after the synthetic gate run."
  return "$final_exit"
}
