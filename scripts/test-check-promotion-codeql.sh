#!/bin/bash
# Covers check-promotion-codeql.sh with a stub gh serving canned JSON,
# including multi-page --paginate output (concatenated arrays).
set -euo pipefail

script_root="$(cd "$(dirname "$0")" && pwd)"
scratch_root="$(mktemp -d /tmp/idlescreen-promotion-codeql.XXXXXX)"
trap '/bin/rm -rf "${scratch_root:?}"' EXIT

stub="$scratch_root/gh"
cat >"$stub" <<'STUB'
#!/bin/bash
# Serves fixtures from $STUB_DIR by endpoint. A --jq argument is applied with jq.
endpoint=""
jq_filter=""
for ((i = 1; i <= $#; i++)); do
  case "${!i}" in
    api | --paginate) ;;
    --jq) j=$((i + 1)); jq_filter="${!j}"; i=$j ;;
    *) endpoint="${!i}" ;;
  esac
done
case "$endpoint" in
  repos/*/pulls/*) file="$STUB_DIR/pull.json" ;;
  repos/*/code-scanning/analyses\?*) file="$STUB_DIR/analyses.json" ;;
  repos/*/code-scanning/alerts\?*) file="$STUB_DIR/alerts.json" ;;
  *) echo "unexpected endpoint: $endpoint" >&2; exit 1 ;;
esac
if [[ -n "$jq_filter" ]]; then jq -r "$jq_filter" "$file"; else cat "$file"; fi
STUB
chmod +x "$stub"

fail() { echo "FAIL: $*" >&2; exit 1; }
sha="1111111111111111111111111111111111111111"
case_dir=""

new_case() {
  case_dir="$(mktemp -d "$scratch_root/case.XXXXXX")"
  echo "{\"merge_commit_sha\": \"$sha\"}" >"$case_dir/pull.json"
  echo "[{\"id\": 1, \"commit_sha\": \"$sha\", \"tool\": {\"name\": \"CodeQL\"}}]" >"$case_dir/analyses.json"
  echo '[]' >"$case_dir/alerts.json"
}

expect() {
  local name="$1" want="$2" got=0
  STUB_DIR="$case_dir" IDLESCREEN_GH="$stub" "$script_root/check-promotion-codeql.sh" 7 Example/repo \
    >"$case_dir/out" 2>"$case_dir/err" || got=$?
  [[ "$got" -eq "$want" ]] || fail "$name: expected exit $want, got $got ($(cat "$case_dir/err"))"
  echo "PASS: $name"
}

alert() { # number severity security_severity(or null)
  local sec="$3"
  [[ "$sec" == null ]] || sec="\"$sec\""
  echo "{\"number\": $1, \"rule\": {\"id\": \"swift/x$1\", \"severity\": \"$2\", \"security_severity_level\": $sec}, \"most_recent_instance\": {\"location\": {\"path\": \"Sources/a.swift\"}}}"
}

new_case
expect "matching analysis and no alerts pass" 0

new_case
echo "[{\"id\": 1, \"commit_sha\": \"2222222222222222222222222222222222222222\", \"tool\": {\"name\": \"CodeQL\"}}]" >"$case_dir/analyses.json"
expect "analysis for a stale commit exits 2" 2
grep -Fq "no CodeQL analysis for the current merge commit" "$case_dir/err" || fail "missing no-analysis message"

new_case
echo '[]' >"$case_dir/analyses.json"
expect "no analyses exits 2" 2

new_case
echo '{"merge_commit_sha": null}' >"$case_dir/pull.json"
got=0
STUB_DIR="$case_dir" IDLESCREEN_GH="$stub" "$script_root/check-promotion-codeql.sh" 7 Example/repo >/dev/null 2>&1 || got=$?
[[ "$got" -ne 0 && "$got" -ne 2 ]] || fail "null merge_commit_sha: expected a state failure, got $got"
echo "PASS: null merge_commit_sha fails"

new_case
echo "[$(alert 3 warning high)]" >"$case_dir/alerts.json"
expect "high security severity blocks" 1
grep -Fq "#3 swift/x3 high Sources/a.swift" "$case_dir/err" || fail "blocking alert not listed"

new_case
echo "[$(alert 4 error medium)]" >"$case_dir/alerts.json"
expect "medium security severity wins over error severity" 0

new_case
echo "[$(alert 5 error null)]" >"$case_dir/alerts.json"
expect "error severity without a security severity blocks" 1

new_case
echo "[$(alert 6 warning null)]" >"$case_dir/alerts.json"
expect "warning without a security severity passes" 0

new_case
printf '[%s]\n[%s]\n' "$(alert 8 warning low)" "$(alert 9 error critical)" >"$case_dir/alerts.json"
expect "alert on page two blocks" 1
grep -Fq "#9 " "$case_dir/err" || fail "page-two alert not listed"

new_case
printf '[%s]\n[%s]\n' "$(alert 8 warning low)" "$(alert 10 error medium)" >"$case_dir/alerts.json"
expect "multi-page output without blocking alerts passes" 0

echo "PASS: promotion CodeQL gate behaves as specified."
