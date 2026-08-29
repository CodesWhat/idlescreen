#!/usr/bin/env python3
"""Plan or run a bounded attended installed-candidate energy observation."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from controlled_physical_soak import (
    ControlledSoakError,
    execute_plan,
    build_plan,
    write_json_atomic,
)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description=(
            "Run only an operator-attended, bounded observation of an already "
            "running installed candidate. This command never starts, stops, "
            "kills, installs, registers, locks, sleeps, reboots, or logs out."
        )
    )
    modes = result.add_mutually_exclusive_group(required=True)
    modes.add_argument("--schedule-plan", type=Path)
    modes.add_argument("--execute-plan", type=Path)
    result.add_argument("--matrix", type=Path)
    result.add_argument("--authorization-id")
    result.add_argument("--duration-seconds", type=int, default=900)
    result.add_argument("--output-plan", type=Path)
    result.add_argument("--output-result", type=Path)
    result.add_argument("--output-energy", type=Path)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        if args.schedule_plan is not None:
            if args.matrix is None or args.authorization_id is None:
                raise ControlledSoakError(
                    "--matrix and --authorization-id are required for planning"
                )
            if args.output_plan is None:
                raise ControlledSoakError("--output-plan is required for planning")
            plan = build_plan(
                args.matrix,
                args.authorization_id,
                args.duration_seconds,
                candidate_path=Path("/Applications/idlescreen.app"),
            )
            write_json_atomic(args.output_plan, plan)
            print("PLANNED: controlled soak plan written; no physical action was performed.")
            return 0
        if args.output_result is None or args.output_energy is None:
            raise ControlledSoakError(
                "--output-result and --output-energy are required for execution"
            )
        result = execute_plan(
            args.execute_plan,
            args.output_result,
            args.output_energy,
            tty_available=sys.stdin.isatty() and sys.stdout.isatty(),
            confirmation=lambda prompt: input(prompt + "\n"),
        )
        print(json.dumps(result, sort_keys=True))
        return 0 if result["status"] == "completed" else 1
    except (ControlledSoakError, OSError, UnicodeError, ValueError) as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 65


if __name__ == "__main__":
    raise SystemExit(main())
