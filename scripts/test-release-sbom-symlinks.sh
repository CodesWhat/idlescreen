#!/bin/bash

set -euo pipefail

script_root="$(cd "$(dirname "$0")" && pwd)"
generator="$script_root/generate-release-sbom.sh"
[[ -x "$generator" ]] || {
  echo "FAIL: missing executable SBOM generator." >&2
  exit 1
}

# The snapshot lives under /tmp, a symlink to /private/tmp on macOS. The
# symlink check must canonicalise it, or every in-tree symlink looks like an escape.
scratch_root="$(mktemp -d /tmp/idlescreen-sbom-symlinks.XXXXXX)"
trap '/bin/rm -rf "${scratch_root:?}"' EXIT

verifier="$scratch_root/verifier.sh"
printf '#!/bin/bash\nexit 73\n' >"$verifier"
/bin/chmod +x "$verifier"

make_candidate() {
  local root="$1"
  /bin/mkdir -p "$root/Framework.framework/Versions/A"
  : >"$root/Framework.framework/Versions/A/Framework"
  /bin/ln -s A "$root/Framework.framework/Versions/Current"
  /bin/ln -s Versions/Current/Framework "$root/Framework.framework/Framework"
  : >"$root/manifest.txt"
}

run_generator() {
  local root="$1"
  local status=0
  IDLESCREEN_SBOM_FIXTURE_MODE=YES IDLESCREEN_SBOM_CANDIDATE_VERIFIER="$verifier" \
    "$generator" "$root/manifest.txt" "$scratch_root/out.spdx.json" \
    >"$scratch_root/stdout" 2>"$scratch_root/stderr" || status=$?
  echo "$status"
}

good="$scratch_root/good"
make_candidate "$good"
status="$(run_generator "$good")"
# 73 is the stub verifier, reached only after the symlink check passes.
[[ "$status" -eq 73 ]] || {
  echo "FAIL: in-tree framework symlinks were rejected under a /tmp snapshot (exit $status)." >&2
  cat "$scratch_root/stderr" >&2
  exit 1
}
echo "PASS: in-tree symlinks pass the snapshot check under /tmp."

bad="$scratch_root/bad"
make_candidate "$bad"
/bin/ln -s /etc/hosts "$bad/escape"
status="$(run_generator "$bad")"
[[ "$status" -eq 66 ]] && grep -Fq 'escaping symlink' "$scratch_root/stderr" || {
  echo "FAIL: an escaping symlink was not rejected (exit $status)." >&2
  exit 1
}
echo "PASS: escaping symlinks are still rejected."
