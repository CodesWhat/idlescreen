#!/usr/bin/env python3

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path


def production_path(value, source_root):
    try:
        relative = Path(value).resolve().relative_to(source_root)
    except ValueError:
        return None
    if not relative.parts or relative.parts[0] not in {"Sources", "Products"}:
        return None
    path = relative.as_posix()
    if "\n" in path or "\r" in path:
        raise ValueError("source path cannot be represented in LCOV")
    return path


def merge_archive(archive, source_root, measurements):
    if not isinstance(archive, dict):
        raise ValueError("expected an xccov archive object")
    executable_lines = 0
    for source, records in archive.items():
        path = production_path(source, source_root)
        if path is None:
            continue
        if not isinstance(records, list):
            raise ValueError(f"invalid line records for {path}")
        for record in records:
            if not isinstance(record, dict):
                raise ValueError(f"invalid line record for {path}")
            line = record.get("line")
            executable = record.get("isExecutable")
            if type(line) is not int or line < 1 or type(executable) is not bool:
                raise ValueError(f"invalid line metadata for {path}")
            if not executable:
                continue
            count = record.get("executionCount")
            if type(count) is not int or count < 0:
                raise ValueError(f"invalid execution count for {path}:{line}")
            lines = measurements.setdefault(path, {})
            lines[line] = max(lines.get(line, 0), count)
            executable_lines += 1
    if not executable_lines:
        raise ValueError("archive contains no executable production lines")


def write_lcov(measurements, output):
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=output.parent,
            prefix=output.name + ".", delete=False,
        ) as stream:
            temporary = Path(stream.name)
            for path, lines in sorted(measurements.items()):
                stream.write(f"SF:{path}\n")
                for line, count in sorted(lines.items()):
                    stream.write(f"DA:{line},{count}\n")
                stream.write(f"LF:{len(lines)}\n")
                stream.write(f"LH:{sum(count > 0 for count in lines.values())}\n")
                stream.write("end_of_record\n")
        os.replace(temporary, output)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description="Export xccov archive JSON to production LCOV")
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("archives", type=Path, nargs="+")
    args = parser.parse_args()
    measurements = {}
    try:
        for archive in args.archives:
            with archive.open(encoding="utf-8") as stream:
                merge_archive(json.load(stream), args.source_root.resolve(), measurements)
        write_lcov(measurements, args.output)
    except (OSError, ValueError) as error:
        print(f"FAIL: coverage export: {error}", file=sys.stderr)
        return 1
    print(f"Exported {len(measurements)} production files to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
