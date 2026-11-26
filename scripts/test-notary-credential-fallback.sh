#!/bin/bash
# Covers r1_resolve_notary_auth with a stub notarytool on PATH: no real
# notarization, no Keychain access.
set -euo pipefail

script_root="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/r1-release-candidate-common.sh
source "$script_root/r1-release-candidate-common.sh"

scratch_root="$(mktemp -d /tmp/idlescreen-notary-fallback.XXXXXX)"
trap '/bin/rm -rf "${scratch_root:?}"' EXIT

stub_bin="$scratch_root/bin"
mkdir "$stub_bin"
cat >"$stub_bin/notarytool" <<'STUB'
#!/bin/bash
# STUB_PROFILE: ok | missing | broken. STUB_KEY: ok | bad.
echo "$*" >>"$STUB_LOG"
[[ "$1" == history ]] || exit 1
case "$2" in
  --keychain-profile)
    case "$STUB_PROFILE" in
      ok) echo '{"history":[]}'; exit 0 ;;
      missing) echo "Error: No Keychain password item found for profile: $3" >&2; exit 1 ;;
      *) echo "Error: network unreachable" >&2; exit 1 ;;
    esac
    ;;
  --key)
    [[ "$STUB_KEY" == ok ]] || { echo "Error: unauthorized" >&2; exit 1; }
    echo '{"history":[]}'
    ;;
  *) exit 1 ;;
esac
STUB
/bin/chmod +x "$stub_bin/notarytool"

key_file="$scratch_root/AuthKey_TESTKEY123.p8"
echo 'not a real key' >"$key_file"
export STUB_LOG="$scratch_root/calls.log"
valid_key_id=TESTKEY123
valid_issuer=11111111-2222-3333-4444-555555555555

failures=0
: >"$scratch_root/all-stderr"
check() {
  local name="$1" expected_rc="$2" expected_auth="$3" rc=0
  shift 3
  : >"$STUB_LOG"
  r1_resolve_notary_auth idlescreen-test "$scratch_root" "$stub_bin/notarytool" 2>"$scratch_root/stderr" || rc=$?
  if [[ "$rc" != "$expected_rc" || "${r1_notary_auth[*]}" != "$expected_auth" ]]; then
    echo "FAIL: $name (rc=$rc auth='${r1_notary_auth[*]}')" >&2
    cat "$scratch_root/stderr" >>"$scratch_root/all-stderr"
    return 1
  fi
  cat "$scratch_root/stderr" >>"$scratch_root/all-stderr"
  echo "PASS: $name"
}

export IDLESCREEN_ASC_KEY_PATH="$key_file" IDLESCREEN_ASC_KEY_ID="$valid_key_id" IDLESCREEN_ASC_ISSUER_ID="$valid_issuer"

STUB_PROFILE=ok STUB_KEY=ok check "profile ok uses the keychain profile" 0 "--keychain-profile idlescreen-test" || failures=$((failures + 1))
grep -q -- '--key ' "$STUB_LOG" && { echo "FAIL: key tried despite working profile" >&2; failures=$((failures + 1)); }

STUB_PROFILE=missing STUB_KEY=ok check "profile missing falls back to the API key" 0 "--key $key_file --key-id $valid_key_id --issuer $valid_issuer" || failures=$((failures + 1))

STUB_PROFILE=broken STUB_KEY=ok check "non-missing profile failure does not fall back" 2 "--keychain-profile idlescreen-test" || failures=$((failures + 1))

STUB_PROFILE=missing STUB_KEY=bad check "profile missing and key rejected fails" 1 "--key $key_file --key-id $valid_key_id --issuer $valid_issuer" || failures=$((failures + 1))
grep -q 'Neither credential is usable' "$scratch_root/stderr" || { echo "FAIL: no clear error for rejected key" >&2; failures=$((failures + 1)); }

(
  unset IDLESCREEN_ASC_KEY_PATH IDLESCREEN_ASC_KEY_ID IDLESCREEN_ASC_ISSUER_ID
  STUB_PROFILE=missing STUB_KEY=ok check "profile missing and no key configured fails" 1 "--keychain-profile idlescreen-test" || exit 1
  grep -q 'IDLESCREEN_ASC_KEY_PATH' "$scratch_root/stderr" || { echo "FAIL: error does not name the env vars" >&2; exit 1; }
) || failures=$((failures + 1))

(
  export IDLESCREEN_ASC_KEY_PATH="$scratch_root/missing.p8"
  STUB_PROFILE=missing STUB_KEY=ok check "profile missing and key file absent fails" 1 "--keychain-profile idlescreen-test" || exit 1
) || failures=$((failures + 1))

# Secrets must never be echoed on stderr.
for secret in "$valid_key_id" "$valid_issuer" "$key_file"; do
  if grep -Fq "$secret" "$scratch_root/all-stderr"; then
    echo "FAIL: stderr leaked a credential value" >&2
    failures=$((failures + 1))
  fi
done

((failures == 0)) || exit 1
echo "PASS: notary credential fallback"
