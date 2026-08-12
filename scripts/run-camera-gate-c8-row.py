#!/usr/bin/env python3
"""Fail-closed C8 row orchestrator skeleton.

Only dry-run plan emission exists. No physical row executor is implemented.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

from camera_gate_c8_schema import (
    AUTHORIZATION_ENVIRONMENT_VARIABLES,
    FINAL_CONSUMER_REASONS,
    FINAL_CONSUMER_ROLES,
    PLAN_SCHEMA,
    PREFLIGHT_CONSOLE_STATE_SCHEMA,
    C8EvidenceError,
    CONSUMER_ID_RE,
    ID_RE,
    ROW_BY_ID,
    load_matrix_definition,
    validate_pending_row,
)


RETAINED_CONSUMER_ENV = "IDLESCREEN_C8_AUTHORIZE_RETAINED_CONSUMER"
CONSOLE_PREFLIGHT_KEYS = frozenset(("schema", "captured_at_utc", "state", "source"))


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description=(
            "Validate one class-scoped C8 authorization and emit an inert plan. "
            "Physical row execution is deliberately unimplemented."
        )
    )
    result.add_argument("matrix", type=Path)
    result.add_argument("row_id", choices=tuple(ROW_BY_ID))
    result.add_argument("--authorization-id", required=True)
    result.add_argument("--console-state-file", required=True, type=Path)
    result.add_argument("--output-plan", required=True, type=Path)
    result.add_argument(
        "--retained-consumer-role", choices=tuple(FINAL_CONSUMER_ROLES), default="none"
    )
    result.add_argument("--retained-consumer-instance-id", default="none")
    result.add_argument(
        "--retained-consumer-reason",
        choices=tuple(FINAL_CONSUMER_REASONS),
        default="none",
    )
    result.add_argument("--dry-run", action="store_true")
    return result


def read_console_state(path: Path) -> tuple[str, str]:
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        raise C8EvidenceError(
            "console state must be an absolute, non-symlink regular preflight file"
        )
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError, UnicodeError) as error:
        raise C8EvidenceError(f"could not read console preflight: {error}") from error
    if not isinstance(value, dict) or set(value) != CONSOLE_PREFLIGHT_KEYS:
        raise C8EvidenceError("console preflight fields are missing or unexpected")
    if (
        value["schema"] != PREFLIGHT_CONSOLE_STATE_SCHEMA
        or value["state"] not in ("locked", "unlocked", "unknown")
        or value["source"] != "read-console-lock-state"
    ):
        raise C8EvidenceError(
            "console preflight is not a supported lock-state observation"
        )
    captured_text = value["captured_at_utc"]
    if not isinstance(captured_text, str) or not captured_text.endswith("Z"):
        raise C8EvidenceError("console preflight timestamp is not UTC")
    try:
        captured = datetime.fromisoformat(captured_text[:-1] + "+00:00")
    except ValueError as error:
        raise C8EvidenceError("console preflight timestamp is malformed") from error
    now = datetime.now(timezone.utc)
    age = (now - captured).total_seconds()
    if age < -2 or age > 60:
        raise C8EvidenceError(
            "console preflight is future-dated or older than 60 seconds"
        )
    return str(value["state"]), captured_text


def write_plan(args: argparse.Namespace) -> Path:
    if not args.dry_run:
        raise C8EvidenceError(
            "physical C8 execution is deliberately unimplemented; pass --dry-run only "
            "to emit an inert plan"
        )
    definition = load_matrix_definition(args.matrix)
    validate_pending_row(definition, args.row_id)
    row = ROW_BY_ID[args.row_id]
    if not ID_RE.fullmatch(args.authorization_id):
        raise C8EvidenceError(
            "authorization ID must be 8-128 safe identifier characters"
        )
    if os.environ.get(row.authorization_environment_variable) != "YES":
        raise C8EvidenceError(
            f"refusing C8 {row.row_id}: set only "
            f"{row.authorization_environment_variable}=YES after class-specific authorization"
        )
    other_opt_ins = sorted(
        name
        for name in AUTHORIZATION_ENVIRONMENT_VARIABLES
        if name != row.authorization_environment_variable and name in os.environ
    )
    if other_opt_ins:
        raise C8EvidenceError(
            "C8 authorization must be class-scoped; unrelated opt-ins are present: "
            + ",".join(other_opt_ins)
        )

    console_state, console_captured_at = read_console_state(args.console_state_file)
    if console_state == "unknown":
        raise C8EvidenceError("console lock state is unknown; refusing C8 preflight")
    if row.requires_unlocked_start and console_state != "unlocked":
        raise C8EvidenceError(
            f"C8 row {row.row_id} must start while the console is unlocked"
        )

    retained_role = args.retained_consumer_role
    retained_instance = args.retained_consumer_instance_id
    retained_reason = args.retained_consumer_reason
    if retained_role == "none":
        if (
            retained_instance != "none"
            or retained_reason != "none"
            or RETAINED_CONSUMER_ENV in os.environ
        ):
            raise C8EvidenceError(
                "empty retained-consumer plan must use the exact none tuple"
            )
        retained_authorized = False
    else:
        if (
            os.environ.get(RETAINED_CONSUMER_ENV) != "YES"
            or CONSUMER_ID_RE.fullmatch(retained_instance) is None
            or retained_reason == "none"
        ):
            raise C8EvidenceError(
                "a named final consumer requires exact identity, reason, and "
                f"{RETAINED_CONSUMER_ENV}=YES"
            )
        retained_authorized = True

    output: Path = args.output_plan
    if (
        not output.is_absolute()
        or output == Path("/")
        or os.path.lexists(output)
        or not output.parent.is_dir()
        or output.parent.is_symlink()
    ):
        raise C8EvidenceError(
            "output plan must be a new absolute file under an existing directory"
        )
    plan = {
        "schema": PLAN_SCHEMA,
        "mode": "dry-run-no-action",
        "matrix_id": definition.matrix_id,
        "row_id": row.row_id,
        "scenario": row.scenario,
        "candidate_provenance_sha256": definition.candidate["provenance_sha256"],
        "candidate_archive_tree_sha256": definition.candidate["archive_tree_sha256"],
        "authorization": {
            "id": args.authorization_id,
            "environment_variable": row.authorization_environment_variable,
            "value": "YES",
            "action_class": row.action_class,
            "scope_statement": row.scope_statement,
        },
        "console": {
            "state": console_state,
            "captured_at_utc": console_captured_at,
            "requires_unlocked_start": row.requires_unlocked_start,
        },
        "retained_consumer": {
            "authorized": retained_authorized,
            "role": retained_role,
            "instance_id": retained_instance,
            "reason_code": retained_reason,
        },
        "executor": "unimplemented",
        "physical_action_performed": False,
    }
    output.write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
    output.chmod(0o400)
    return output


def main() -> int:
    try:
        plan = write_plan(parser().parse_args())
    except (C8EvidenceError, OSError, UnicodeError, ValueError) as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 65
    print(
        "DRY RUN: C8 authorization preflight passed; no physical action was performed."
    )
    print(f"Plan: {plan}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
