#!/usr/bin/env python3
"""Fail when total line coverage in an LCOV file is below a fixed floor.

The floor applies to the same production LCOV that CI uploads to Codecov. The
file is validated strictly and any malformed input fails closed, so a broken
conversion cannot silently pass the gate.
"""

import argparse
import sys
from fractions import Fraction
from pathlib import Path

DEFAULT_FLOOR = "80.0"


class LcovError(ValueError):
    pass


def parse_count(value, label, line_number):
    if not value.isascii() or not value.isdigit():
        raise LcovError(f"line {line_number}: {label} is not a non-negative integer")
    return int(value)


def total_line_coverage(text):
    """Return (hit, found) summed over every record, cross-checked against DA lines."""
    found_total = 0
    hit_total = 0
    records = 0
    in_record = False
    da_found = da_hit = 0
    declared_found = declared_hit = None

    for number, line in enumerate(text.splitlines(), start=1):
        if not line:
            continue
        key, separator, value = line.partition(":")
        if line == "end_of_record":
            if not in_record:
                raise LcovError(f"line {number}: end_of_record without SF")
            if declared_found is None or declared_hit is None:
                raise LcovError(f"line {number}: record is missing LF or LH")
            if (declared_found, declared_hit) != (da_found, da_hit):
                raise LcovError(
                    f"line {number}: LF/LH ({declared_found}/{declared_hit}) "
                    f"disagree with DA lines ({da_found}/{da_hit})"
                )
            found_total += declared_found
            hit_total += declared_hit
            records += 1
            in_record = False
        elif key == "SF" and separator:
            if in_record:
                raise LcovError(f"line {number}: SF before end_of_record")
            if not value:
                raise LcovError(f"line {number}: empty SF path")
            in_record = True
            da_found = da_hit = 0
            declared_found = declared_hit = None
        elif key == "TN" and separator:
            continue
        elif not in_record:
            raise LcovError(f"line {number}: data outside a record")
        elif key == "DA" and separator:
            fields = value.split(",")
            if len(fields) < 2 or len(fields) > 3:
                raise LcovError(f"line {number}: malformed DA")
            parse_count(fields[0], "DA line", number)
            count = parse_count(fields[1], "DA count", number)
            da_found += 1
            da_hit += count > 0
        elif key == "LF" and separator:
            declared_found = parse_count(value, "LF", number)
        elif key == "LH" and separator:
            declared_hit = parse_count(value, "LH", number)
            if declared_found is not None and declared_hit > declared_found:
                raise LcovError(f"line {number}: LH exceeds LF")
        elif separator and key in {"FN", "FNDA", "FNF", "FNH", "BRDA", "BRF", "BRH"}:
            continue
        else:
            raise LcovError(f"line {number}: unrecognised LCOV line")

    if in_record:
        raise LcovError("file ends inside a record")
    if records == 0 or found_total == 0:
        raise LcovError("no executable lines found")
    if hit_total > found_total:
        raise LcovError("hit lines exceed found lines")
    return hit_total, found_total


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--floor", default=DEFAULT_FLOOR, help="minimum line coverage percent")
    parser.add_argument("lcov", type=Path)
    args = parser.parse_args(argv)

    try:
        floor = Fraction(args.floor)
        if not 0 <= floor <= 100:
            raise ValueError
    except (ValueError, ZeroDivisionError):
        print(f"FAIL: invalid coverage floor: {args.floor}", file=sys.stderr)
        return 2

    try:
        hit, found = total_line_coverage(args.lcov.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, LcovError) as error:
        print(f"FAIL: cannot compute line coverage from {args.lcov}: {error}", file=sys.stderr)
        return 1

    percent = Fraction(hit * 100, found)
    summary = f"line coverage {float(percent):.2f}% ({hit}/{found}) against a floor of {args.floor}%"
    # Exact rational comparison: 79.99 can never round up to pass.
    if percent < floor:
        print(f"FAIL: {summary}", file=sys.stderr)
        return 1
    print(f"PASS: {summary}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
