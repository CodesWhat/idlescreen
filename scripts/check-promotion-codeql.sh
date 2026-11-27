#!/bin/bash
# Gate for the promotion PR into main: main's code_scanning ruleset blocks on
# open errors / high_or_higher alerts for the PR merge ref, so check the same
# thing before merging. Usage: check-promotion-codeql.sh <pr-number> [repo]
# Exit: 0 clean, 1 blocking alerts, 2 no CodeQL analysis for the current merge
# commit, 3 usage or API/state error. IDLESCREEN_GH overrides the gh binary.
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 || ! "$1" =~ ^[0-9]+$ ]]; then
  echo "usage: check-promotion-codeql.sh <pr-number> [repo]" >&2
  exit 3
fi
pr="$1"
repo="${2:-CodesWhat/idlescreen}"
gh_bin="${IDLESCREEN_GH:-gh}"
ref="refs/pull/$pr/merge"

merge_sha="$("$gh_bin" api "repos/$repo/pulls/$pr" --jq '.merge_commit_sha // empty')" || {
  echo "FAIL: could not read PR #$pr in $repo" >&2
  exit 3
}
if [[ -z "$merge_sha" ]]; then
  echo "FAIL: PR #$pr has no merge_commit_sha yet (not mergeable, or GitHub is still computing it); retry shortly" >&2
  exit 3
fi

analyses="$("$gh_bin" api --paginate \
  "repos/$repo/code-scanning/analyses?ref=$ref&per_page=100")" || {
  echo "FAIL: could not list code-scanning analyses for $ref" >&2
  exit 3
}
matching="$(jq -r --arg sha "$merge_sha" \
  '.[] | select(.commit_sha == $sha and (.tool.name // "CodeQL") == "CodeQL") | .id' <<<"$analyses" | wc -l | tr -d ' ')"
if [[ "$matching" -eq 0 ]]; then
  echo "no CodeQL analysis for the current merge commit ($merge_sha); wait for security-codeql to finish on the PR" >&2
  exit 2
fi

alerts="$("$gh_bin" api --paginate \
  "repos/$repo/code-scanning/alerts?state=open&ref=$ref&per_page=100")" || {
  echo "FAIL: could not list code-scanning alerts for $ref" >&2
  exit 3
}
# Security severity wins when present (high or critical block); otherwise the
# rule severity decides (error blocks).
blocking="$(jq -r '
  .[]
  | select(
      if (.rule.security_severity_level // null) != null
      then (.rule.security_severity_level == "high" or .rule.security_severity_level == "critical")
      else .rule.severity == "error"
      end)
  | "#\(.number) \(.rule.id) \(.rule.security_severity_level // .rule.severity) \(.most_recent_instance.location.path // "-")"
' <<<"$alerts")"

if [[ -n "$blocking" ]]; then
  count="$(printf '%s\n' "$blocking" | wc -l | tr -d ' ')"
  echo "FAIL: $count blocking code-scanning alert(s) on $ref ($merge_sha):" >&2
  printf '%s\n' "$blocking" >&2
  exit 1
fi
echo "PASS: CodeQL analyzed $merge_sha and $ref has no open error or high-or-higher alerts."
