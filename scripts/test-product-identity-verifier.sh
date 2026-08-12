#!/bin/bash

set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
verifier="$project_root/scripts/verify-product-identity.sh"
fixture_root="$(mktemp -d /tmp/idlescreen-product-identity-tests.XXXXXX)"
trap 'rm -rf "$fixture_root"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

make_product() {
  local app_path="$1"
  local companion_contents="$2"
  local extension_contents="$3"

  mkdir -p "$app_path/Contents/MacOS"
  mkdir -p "$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS"
  printf '%s' "$companion_contents" >"$app_path/Contents/MacOS/IdleScreen"
  printf '%s' "$extension_contents" >"$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver"
}

write_manifest() {
  local app_path="$1"
  local manifest_path="$2"
  local recorded_root="$3"
  local companion_hash
  local extension_hash

  companion_hash="$(/usr/bin/shasum -a 256 "$app_path/Contents/MacOS/IdleScreen" | awk '{ print $1 }')"
  extension_hash="$(/usr/bin/shasum -a 256 "$app_path/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver" | awk '{ print $1 }')"
  printf '%s  %s/Contents/PlugIns/IdleScreenScreenSaver.appex/Contents/MacOS/IdleScreenScreenSaver\n' \
    "$extension_hash" "$recorded_root" >"$manifest_path"
  printf '%s  %s/Contents/MacOS/IdleScreen\n' \
    "$companion_hash" "$recorded_root" >>"$manifest_path"
}

run_verifier() {
  set +e
  verifier_output="$("$verifier" "$1" "$2" 2>&1)"
  verifier_status=$?
  set -e
}

product="$fixture_root/idlescreen.app"
manifest="$fixture_root/product-sha256.txt"
make_product "$product" 'companion-v1' 'extension-v1'
write_manifest "$product" "$manifest" '/different/build/root/idlescreen.app'

[[ -x "$verifier" ]] || fail "missing executable product-identity verifier"

run_verifier "$product" "$manifest"
[[ "$verifier_status" -eq 0 ]] || fail "matching product hashes were rejected: $verifier_output"
grep -Fq 'PASS:' <<<"$verifier_output" || fail "an exact match must be labeled PASS"
grep -Fq 'companion and embedded extension' <<<"$verifier_output" ||
  fail "the exact-match result must name both verified binaries"

run_verifier "$product" "$fixture_root/missing-product-sha256.txt"
[[ "$verifier_status" -eq 1 ]] || fail "missing evidence must be incomplete"
grep -Fq 'INCOMPLETE:' <<<"$verifier_output" || fail "missing evidence must be labeled INCOMPLETE"

printf 'not-a-sha256  /evidence/idlescreen.app/Contents/MacOS/IdleScreen\n' >"$fixture_root/malformed.txt"
run_verifier "$product" "$fixture_root/malformed.txt"
[[ "$verifier_status" -eq 2 ]] || fail "malformed evidence must be fatal"
grep -Fq 'FAIL:' <<<"$verifier_output" || fail "malformed evidence must be labeled FAIL"
grep -Fqi 'malformed' <<<"$verifier_output" || fail "malformed evidence must explain the failure"

cp "$manifest" "$fixture_root/mismatched.txt"
sed -i '' 's/^[0-9a-f]/0/' "$fixture_root/mismatched.txt"
if cmp -s "$manifest" "$fixture_root/mismatched.txt"; then
  sed -i '' 's/^[0-9a-f]/1/' "$fixture_root/mismatched.txt"
fi
run_verifier "$product" "$fixture_root/mismatched.txt"
[[ "$verifier_status" -eq 2 ]] || fail "a product/evidence hash mismatch must be fatal"
grep -Fqi 'does not match' <<<"$verifier_output" || fail "a mismatch must explain the identity failure"

printf '%s\n' "$(head -1 "$manifest")" >"$fixture_root/one-role.txt"
run_verifier "$product" "$fixture_root/one-role.txt"
[[ "$verifier_status" -eq 2 ]] || fail "evidence missing one binary role must be fatal"
grep -Fqi 'malformed' <<<"$verifier_output" || fail "incomplete manifest structure must be labeled malformed"

printf '%s\n%s\n' "$(head -1 "$manifest")" "$(head -1 "$manifest")" >"$fixture_root/duplicate-role.txt"
run_verifier "$product" "$fixture_root/duplicate-role.txt"
[[ "$verifier_status" -eq 2 ]] || fail "duplicate binary evidence must be fatal"
grep -Fqi 'malformed' <<<"$verifier_output" || fail "duplicate evidence must be labeled malformed"

rm "$product/Contents/MacOS/IdleScreen"
run_verifier "$product" "$manifest"
[[ "$verifier_status" -eq 2 ]] || fail "a missing product binary must be fatal"
grep -Fqi 'product binary' <<<"$verifier_output" || fail "a missing product binary must explain the failure"

echo "PASS: product identity evidence is exact, role-aware, and fail-closed."
