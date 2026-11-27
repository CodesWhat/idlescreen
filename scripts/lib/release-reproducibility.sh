#!/bin/bash
# Comparison logic for check-release-reproducibility.sh. Sourced, not executed.

# Manifest keys an unsigned rebuild can be compared on.
rr_comparable_keys=(
  source_commit
  source_tree
  project_yml_sha256
  project_pbxproj_sha256
  bundle_short_version
  bundle_version
)

# Manifest keys that exist only because of signing, notarization or stapling.
# An unsigned build cannot reproduce them, so they are reported, never compared.
rr_signature_bound_keys=(
  developer_id_certificate_sha256
  distribution_app_tree_sha256
  app_cdhash
  extension_cdhash
  helper_cdhash
  renderer_cdhash
  control_tool_cdhash
  submitted_dmg_sha256
  stapled_dmg_sha256
  notary_submission_id
  notary_status
  notary_log_sha256
  stapler_status
  dmg_gatekeeper_status
  mounted_app_gatekeeper_status
)

rr_value() {
  /usr/bin/awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; found = 1; exit } END { exit !found }' "$2"
}

# rr_compare <manifest> <observed key=value file>. Prints one line per key and a
# RESULT line. Returns 1 on any mismatch or missing value.
rr_compare() {
  local manifest="$1" observed="$2" key want got matched=0 bad=0
  for key in "${rr_comparable_keys[@]}"; do
    if ! want="$(rr_value "$key" "$manifest")"; then
      echo "MISSING-MANIFEST $key"; bad=$((bad + 1)); continue
    fi
    if ! got="$(rr_value "$key" "$observed")"; then
      echo "MISSING-OBSERVED $key"; bad=$((bad + 1)); continue
    fi
    if [[ "$want" == "$got" ]]; then
      echo "MATCH $key=$want"; matched=$((matched + 1))
    else
      echo "MISMATCH $key manifest=$want rebuilt=$got"; bad=$((bad + 1))
    fi
  done
  for key in "${rr_signature_bound_keys[@]}"; do
    if rr_value "$key" "$manifest" >/dev/null; then
      echo "NOT-COMPARABLE $key (signature, notarization or distribution bound)"
    fi
  done
  echo "NOT-COMPARABLE per-binary unsigned digests (the manifest records none; only signed cdhashes)"
  echo "RESULT: $matched matched, $bad mismatched"
  [[ "$bad" == 0 ]]
}
