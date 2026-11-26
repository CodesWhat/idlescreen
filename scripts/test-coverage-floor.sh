#!/bin/bash

set -euo pipefail

script_root="$(cd "$(dirname "$0")" && pwd)"
checker="$script_root/check_coverage_floor.py"
[[ -f "$checker" ]] || {
  echo "FAIL: missing coverage floor checker." >&2
  exit 1
}

scratch_root="$(mktemp -d /tmp/idlescreen-coverage-floor.XXXXXX)"
trap '/bin/rm -rf "${scratch_root:?}"' EXIT

# write_lcov <path> <found> <hit>: one record whose DA lines match LF/LH.
write_lcov() {
  local path="$1" found="$2" hit="$3" line
  {
    echo "SF:Sources/Example.swift"
    for ((line = 1; line <= found; line++)); do
      if ((line <= hit)); then echo "DA:$line,3"; else echo "DA:$line,0"; fi
    done
    echo "LF:$found"
    echo "LH:$hit"
    echo "end_of_record"
  } >"$path"
}

run_checker() {
  local status=0
  python3 "$checker" "$@" >"$scratch_root/stdout" 2>"$scratch_root/stderr" || status=$?
  echo "$status"
}

expect_status() {
  local expected="$1" label="$2"
  shift 2
  local actual
  actual="$(run_checker "$@")"
  [[ "$actual" == "$expected" ]] || {
    echo "FAIL: $label (expected exit $expected, got $actual)" >&2
    cat "$scratch_root/stdout" "$scratch_root/stderr" >&2
    exit 1
  }
}

# 799/1000 is 79.9%: below the floor. 800/1000 is exactly 80.0%: passes.
write_lcov "$scratch_root/below.lcov" 1000 799
expect_status 1 "79.9% must fail the default floor" "$scratch_root/below.lcov"
grep -Fq 'FAIL: line coverage 79.90% (799/1000)' "$scratch_root/stderr" ||
  { echo "FAIL: failure message does not report the measured coverage." >&2; exit 1; }

write_lcov "$scratch_root/exact.lcov" 1000 800
expect_status 0 "80.0% must pass the default floor" "$scratch_root/exact.lcov"
grep -Fq 'PASS: line coverage 80.00% (800/1000)' "$scratch_root/stdout" ||
  { echo "FAIL: success message does not report the measured coverage." >&2; exit 1; }

# A value that rounds to 80.00 must still fail: 7999/10000 is 79.99%.
write_lcov "$scratch_root/rounds-up.lcov" 10000 7999
expect_status 1 "79.99% must not round up past the floor" "$scratch_root/rounds-up.lcov"

# Totals are summed across records, not averaged per file.
{
  echo "TN:"
  echo "SF:Sources/Big.swift"
  for line in $(seq 1 90); do echo "DA:$line,1"; done
  echo "LF:90"
  echo "LH:90"
  echo "end_of_record"
  echo "SF:Sources/Small.swift"
  for line in $(seq 1 10); do echo "DA:$line,0"; done
  echo "LF:10"
  echo "LH:0"
  echo "end_of_record"
} >"$scratch_root/summed.lcov"
expect_status 1 "90/100 total must fail an explicit 91 floor" --floor 91 "$scratch_root/summed.lcov"
expect_status 0 "90/100 total must pass an explicit 90 floor" --floor 90 "$scratch_root/summed.lcov"

# Everything else fails closed.
: >"$scratch_root/empty.lcov"
expect_status 1 "an empty file must fail closed" "$scratch_root/empty.lcov"

expect_status 1 "a missing file must fail closed" "$scratch_root/does-not-exist.lcov"

printf 'SF:Sources/A.swift\nDA:1,1\nLF:1\nLH:1\n' >"$scratch_root/truncated.lcov"
expect_status 1 "an unterminated record must fail closed" "$scratch_root/truncated.lcov"

printf 'SF:Sources/A.swift\nDA:1,1\nLF:2\nLH:1\nend_of_record\n' >"$scratch_root/mismatch.lcov"
expect_status 1 "LF that disagrees with DA lines must fail closed" "$scratch_root/mismatch.lcov"

printf 'SF:Sources/A.swift\nDA:1,1\nLF:1\nLH:5\nend_of_record\n' >"$scratch_root/overhit.lcov"
expect_status 1 "LH above LF must fail closed" "$scratch_root/overhit.lcov"

printf 'SF:Sources/A.swift\nDA:x,1\nLF:1\nLH:1\nend_of_record\n' >"$scratch_root/badda.lcov"
expect_status 1 "a non-numeric DA line must fail closed" "$scratch_root/badda.lcov"

printf 'SF:Sources/A.swift\nDA:1,-1\nLF:1\nLH:0\nend_of_record\n' >"$scratch_root/negative.lcov"
expect_status 1 "a negative execution count must fail closed" "$scratch_root/negative.lcov"

printf 'this is not lcov\n' >"$scratch_root/garbage.lcov"
expect_status 1 "arbitrary text must fail closed" "$scratch_root/garbage.lcov"

printf 'SF:Sources/A.swift\nLF:0\nLH:0\nend_of_record\n' >"$scratch_root/zero.lcov"
expect_status 1 "a file with no executable lines must fail closed" "$scratch_root/zero.lcov"

expect_status 2 "a non-numeric floor must be rejected" --floor eighty "$scratch_root/exact.lcov"
expect_status 2 "a floor above 100 must be rejected" --floor 101 "$scratch_root/exact.lcov"

# The converter's real output shape passes straight through.
printf '{"%s/Sources/A.swift":[{"line":1,"isExecutable":true,"executionCount":2},{"line":2,"isExecutable":true,"executionCount":0}]}' \
  "$scratch_root" >"$scratch_root/archive.json"
python3 "$script_root/xccov_to_lcov.py" --source-root "$scratch_root" \
  --output "$scratch_root/converted.lcov" "$scratch_root/archive.json"
expect_status 1 "converter output at 50% must fail" "$scratch_root/converted.lcov"
expect_status 0 "converter output at 50% must pass a 50 floor" --floor 50 "$scratch_root/converted.lcov"

echo "PASS: coverage floor gate accepts 80.0%, rejects 79.9%, and fails closed on malformed LCOV."
