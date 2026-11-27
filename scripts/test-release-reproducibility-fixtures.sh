#!/bin/bash
# Fixture test for the comparison logic in check-release-reproducibility.sh.
# No build, no network, no signing credentials.
set -euo pipefail

script_root="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib/release-reproducibility.sh
source "$script_root/lib/release-reproducibility.sh"

scratch="$(mktemp -d /tmp/idlescreen-repro-fixtures.XXXXXX)"
trap '/bin/rm -rf "${scratch:?}"' EXIT

cat >"$scratch/manifest.txt" <<'M'
schema=IdleScreenR1ReleaseCandidate/v1
verification_mode=release
source_commit=4eeb36c0340d7a4c9d028131adf2d4e0c630017e
source_tree=b806ecc3d25fcc987efb5653237ce6ff2ab8e57b
project_yml_sha256=aaaa
project_pbxproj_sha256=bbbb
bundle_short_version=0.4.0
bundle_version=67
app_cdhash=429c85cd11c32a17395dc97f02b4babc110b0c79
distribution_app_tree_sha256=9bba15c5
notary_status=Accepted
M

write_observed() {
  cat >"$scratch/observed.txt" <<O
source_commit=${1:-4eeb36c0340d7a4c9d028131adf2d4e0c630017e}
source_tree=${2:-b806ecc3d25fcc987efb5653237ce6ff2ab8e57b}
project_yml_sha256=${3:-aaaa}
project_pbxproj_sha256=${4:-bbbb}
bundle_short_version=${5:-0.4.0}
bundle_version=${6:-67}
O
}

failures=0
expect() {
  local name="$1" want_rc="$2" want_text="$3" rc=0 out
  out="$(rr_compare "$scratch/manifest.txt" "$scratch/observed.txt" 2>&1)" || rc=$?
  if [[ "$rc" != "$want_rc" ]] || ! grep -Fq -- "$want_text" <<<"$out"; then
    echo "FAIL: $name (rc=$rc, wanted rc=$want_rc and '$want_text')" >&2
    echo "$out" >&2
    failures=$((failures + 1))
    return
  fi
  echo "PASS: $name"
}

write_observed
expect "all comparable fields match" 0 "MATCH project_pbxproj_sha256"
expect "signature-bound fields are reported, not compared" 0 "NOT-COMPARABLE app_cdhash"
expect "notarization is reported as not comparable" 0 "NOT-COMPARABLE notary_status"
expect "summary counts matches" 0 "RESULT: 6 matched, 0 mismatched"

write_observed deadbeef
expect "source commit mismatch fails" 1 "MISMATCH source_commit"

write_observed "" "" "" cccc
expect "regenerated pbxproj drift fails" 1 "MISMATCH project_pbxproj_sha256"

write_observed "" "" "" "" 0.4.1
expect "bundle version mismatch fails" 1 "MISMATCH bundle_short_version"

write_observed "" "" "" "" "" 68
expect "bundle build mismatch fails" 1 "MISMATCH bundle_version"

grep -v '^bundle_version=' "$scratch/observed.txt" >"$scratch/o2" && mv "$scratch/o2" "$scratch/observed.txt"
expect "observed value missing fails" 1 "MISSING-OBSERVED bundle_version"

write_observed
grep -v '^project_yml_sha256=' "$scratch/manifest.txt" >"$scratch/m2" && mv "$scratch/m2" "$scratch/manifest.txt"
expect "manifest value missing fails" 1 "MISSING-MANIFEST project_yml_sha256"

[[ "$failures" == 0 ]] || { echo "FAIL: $failures release reproducibility fixture(s) failed" >&2; exit 1; }
echo "PASS: release reproducibility comparison fixtures"
