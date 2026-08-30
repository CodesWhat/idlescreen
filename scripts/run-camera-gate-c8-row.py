#!/usr/bin/env python3
"""Fail-closed controlled C8 soak planner."""

from __future__ import annotations

import argparse
import ctypes
import errno
import json
import os
import re
import stat
import sys
from datetime import datetime, timedelta, timezone
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
    MatrixDefinition,
    RowDefinition,
    ROW_BY_ID,
    load_matrix_definition,
    validate_pending_row,
)


RETAINED_CONSUMER_ENV = "IDLESCREEN_C8_AUTHORIZE_RETAINED_CONSUMER"
CONSOLE_PREFLIGHT_KEYS = frozenset(("schema", "captured_at_utc", "state", "source"))
UTC_TIMESTAMP_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")
SCHEDULE_TTL_SECONDS = 300
SOAK_MAX_DURATION_SECONDS = 900
ACL_TYPE_EXTENDED = 0x100
ACL_FIRST_ENTRY = 0
ACL_NEXT_ENTRY = -1
ACL_EXTENDED_ALLOW = 1
ACL_EXTENDED_DENY = 2
CLOSE_RETRY_LIMIT = 8


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description=(
            "Validate one class-scoped C8 authorization and emit an inert "
            "controlled soak schedule. Physical execution is unavailable "
            "until a canonical installed-candidate evidence collector exists."
        )
    )
    result.add_argument("matrix", type=Path, nargs="?")
    result.add_argument("row_id", choices=tuple(ROW_BY_ID), nargs="?")
    result.add_argument("--authorization-id", required=True)
    result.add_argument("--console-state-file", type=Path)
    result.add_argument("--output-plan", type=Path)
    result.add_argument(
        "--retained-consumer-role", choices=tuple(FINAL_CONSUMER_ROLES), default="none"
    )
    result.add_argument("--retained-consumer-instance-id", default="none")
    result.add_argument(
        "--retained-consumer-reason",
        choices=tuple(FINAL_CONSUMER_REASONS),
        default="none",
    )
    modes = result.add_mutually_exclusive_group()
    modes.add_argument("--dry-run", action="store_true")
    modes.add_argument("--schedule-soak", action="store_true")
    result.add_argument("--duration-seconds", type=int, default=900)
    result.add_argument("--execute-plan", type=Path)
    result.add_argument("--output-result", type=Path)
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
    if not isinstance(captured_text, str) or not UTC_TIMESTAMP_RE.fullmatch(captured_text):
        raise C8EvidenceError("console preflight timestamp must be exact UTC second syntax")
    try:
        captured = datetime.strptime(captured_text, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as error:
        raise C8EvidenceError("console preflight timestamp is malformed") from error
    now = datetime.now(timezone.utc)
    age = (now - captured).total_seconds()
    if age < -2 or age > 60:
        raise C8EvidenceError(
            "console preflight is future-dated or older than 60 seconds"
        )
    return str(value["state"]), captured_text


def require_new_absolute_file(path: Path, label: str) -> None:
    if (
        not path.is_absolute()
        or path == Path("/")
        or os.path.lexists(path)
        or not path.parent.is_dir()
        or path.parent.is_symlink()
    ):
        raise C8EvidenceError(
            f"{label} must be a new absolute file under an existing directory"
        )


def utc_timestamp(value: datetime) -> str:
    return value.isoformat(timespec="seconds").replace("+00:00", "Z")


def _poison_descriptor(descriptor: int) -> None:
    os.ftruncate(descriptor, 0)
    os.fchmod(descriptor, 0)
    if os.environ.get("IDLESCREEN_C8_INJECT_POISON_FSYNC_FAILURE") == "YES":
        raise OSError("injected poison fsync failure")
    os.fsync(descriptor)


def _directory_flags() -> int:
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    return flags


def _load_acl_api():
    try:
        libc = ctypes.CDLL(None, use_errno=True)
        libc.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
        libc.acl_get_fd_np.restype = ctypes.c_void_p
        libc.acl_get_entry.argtypes = [
            ctypes.c_void_p,
            ctypes.c_int,
            ctypes.POINTER(ctypes.c_void_p),
        ]
        libc.acl_get_entry.restype = ctypes.c_int
        libc.acl_get_tag_type.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(ctypes.c_int),
        ]
        libc.acl_get_tag_type.restype = ctypes.c_int
        libc.acl_free.argtypes = [ctypes.c_void_p]
        libc.acl_free.restype = ctypes.c_int
    except AttributeError as error:
        raise OSError(errno.ENOSYS, "extended ACL API unavailable") from error
    return libc


def _validate_extended_acl(descriptor: int, label: str) -> None:
    try:
        api = _load_acl_api()
        ctypes.set_errno(0)
        acl = api.acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED)
    except (OSError, AttributeError) as error:
        raise C8EvidenceError(f"could not inspect {label} ACL: {error}") from error
    if not acl:
        error_number = ctypes.get_errno()
        if error_number in (errno.ENOENT, getattr(errno, "ENODATA", -1)):
            return
        raise C8EvidenceError(
            f"could not inspect {label} ACL: {os.strerror(error_number or errno.EIO)}"
        )

    failure = None
    try:
        entry_id = ACL_FIRST_ENTRY
        while True:
            entry = ctypes.c_void_p()
            if api.acl_get_entry(acl, entry_id, ctypes.byref(entry)) != 0:
                error_number = ctypes.get_errno()
                if error_number == errno.EINVAL:
                    break
                failure = C8EvidenceError(
                    f"could not inspect {label} ACL entries: "
                    f"{os.strerror(error_number or errno.EIO)}"
                )
                break
            tag_type = ctypes.c_int()
            if api.acl_get_tag_type(entry, ctypes.byref(tag_type)) != 0:
                error_number = ctypes.get_errno()
                failure = C8EvidenceError(
                    f"could not inspect {label} ACL entry tag: "
                    f"{os.strerror(error_number or errno.EIO)}"
                )
                break
            if tag_type.value == ACL_EXTENDED_ALLOW:
                failure = C8EvidenceError(f"{label} has an extended ACL allow entry")
                break
            if tag_type.value != ACL_EXTENDED_DENY:
                failure = C8EvidenceError(f"{label} has an unknown extended ACL entry")
                break
            entry_id = ACL_NEXT_ENTRY
    except (OSError, AttributeError) as error:
        failure = C8EvidenceError(f"could not inspect {label} ACL entries: {error}")
    finally:
        try:
            free_result = api.acl_free(acl)
        except (OSError, AttributeError) as error:
            free_result = -1
            if failure is None:
                failure = C8EvidenceError(f"could not release {label} ACL: {error}")
        if free_result != 0 and failure is None:
            error_number = ctypes.get_errno()
            failure = C8EvidenceError(
                f"could not release {label} ACL: "
                f"{os.strerror(error_number or errno.EIO)}"
            )
    if failure is not None:
        raise failure


def _validate_directory(descriptor: int, label: str) -> None:
    try:
        value = os.fstat(descriptor)
    except BaseException:
        raise
    _validate_extended_acl(descriptor, label)
    if not stat.S_ISDIR(value.st_mode):
        raise C8EvidenceError(f"{label} is not a directory")
    if value.st_uid not in (0, os.getuid()) or value.st_mode & 0o022:
        raise C8EvidenceError(f"{label} is not a trusted private directory")


def _close_descriptor_best_effort(descriptor: int):
    try:
        os.close(descriptor)
    except OSError as error:
        return error
    return None


def _close_descriptors(descriptors: list[int]) -> None:
    first_error = None
    for descriptor in reversed(descriptors):
        error = _close_descriptor_best_effort(descriptor)
        if error is not None and first_error is None:
            first_error = error
    if first_error is not None:
        raise first_error


def _close_output_descriptor(descriptor: int):
    return _close_descriptor_best_effort(descriptor)


def _validate_lexical_ancestors(path: Path) -> None:
    current = Path("/")
    for component in path.parent.parts[1:]:
        current /= component
        value = os.lstat(current)
        if value.st_uid not in (0, os.getuid()):
            raise C8EvidenceError("output ancestor is not owned by root or the current user")
        if not stat.S_ISLNK(value.st_mode) and value.st_mode & 0o022:
            raise C8EvidenceError("output ancestor is writable by another user")


def _open_trusted_parent(path: Path) -> tuple[int, list[int]]:
    descriptors: list[int] = []
    try:
        _validate_lexical_ancestors(path)
        trusted_parent = path.parent.resolve(strict=True)
        descriptor = os.open(Path("/"), _directory_flags())
        descriptors.append(descriptor)
        _validate_directory(descriptor, "output ancestor")
        for component in trusted_parent.parts[1:]:
            descriptor = os.open(
                component, _directory_flags(), dir_fd=descriptor
            )
            descriptors.append(descriptor)
            _validate_directory(descriptor, "output ancestor")
        return descriptor, descriptors
    except BaseException:
        _close_descriptors(descriptors)
        raise


def _require_new_entry(parent_descriptor: int, name: str) -> None:
    try:
        os.stat(name, dir_fd=parent_descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return
    except OSError as error:
        raise C8EvidenceError(f"could not inspect output plan entry: {error}") from error
    raise C8EvidenceError("output plan must be a new absolute file under an existing directory")


def _sync_parent(parent_descriptor: int) -> None:
    os.fsync(parent_descriptor)


def _verify_published_inode(
    parent_descriptor: int, output_name: str, descriptor: int
) -> None:
    entry = os.stat(output_name, dir_fd=parent_descriptor, follow_symlinks=False)
    owned = os.fstat(descriptor)
    if (
        not stat.S_ISREG(entry.st_mode)
        or entry.st_dev != owned.st_dev
        or entry.st_ino != owned.st_ino
    ):
        raise C8EvidenceError("published plan entry is not the written inode")


def _remove_owned_entry(
    parent_descriptor: int, output_name: str, descriptor: int
) -> bool:
    entry = os.stat(output_name, dir_fd=parent_descriptor, follow_symlinks=False)
    owned = os.fstat(descriptor)
    if entry.st_dev != owned.st_dev or entry.st_ino != owned.st_ino:
        return False
    os.unlink(output_name, dir_fd=parent_descriptor)
    _sync_parent(parent_descriptor)
    return True


def _verify_parent_identity(path: Path, parent_descriptors: list[int]) -> None:
    try:
        fresh_descriptor, fresh_ancestors = _open_trusted_parent(path)
    except OSError as error:
        raise C8EvidenceError("requested output parent could not be reopened") from error
    try:
        if len(parent_descriptors) != len(fresh_ancestors):
            raise C8EvidenceError("requested output parent changed during publication")
        for held_descriptor, fresh_descriptor in zip(
            parent_descriptors, fresh_ancestors
        ):
            held = os.fstat(held_descriptor)
            fresh = os.fstat(fresh_descriptor)
            if held.st_dev != fresh.st_dev or held.st_ino != fresh.st_ino:
                raise C8EvidenceError("requested output ancestor changed during publication")
    finally:
        _close_descriptors(fresh_ancestors)


def write_exclusive_json(path: Path, value: object) -> None:
    if os.environ.get("IDLESCREEN_C8_INJECT_SERIALIZATION_FAILURE") == "YES":
        raise C8EvidenceError("injected plan serialization failure")
    try:
        payload = (json.dumps(value, indent=2) + "\n").encode("utf-8")
    except (TypeError, ValueError, UnicodeError) as error:
        raise C8EvidenceError(f"could not serialize plan: {error}") from error
    require_new_absolute_file(path, "output plan")
    parent_descriptor, parent_descriptors = _open_trusted_parent(path)
    descriptor = None
    operation_error = None
    operation_cause = None
    try:
        output_name = path.name
        if output_name in ("", ".", ".."):
            raise C8EvidenceError("output plan name is invalid")
        _require_new_entry(parent_descriptor, output_name)
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(output_name, flags, 0, dir_fd=parent_descriptor)
        if os.environ.get("IDLESCREEN_C8_INJECT_WRITE_FAILURE") == "YES":
            raise OSError("injected plan write failure")
        remaining = memoryview(payload)
        while remaining:
            written = os.write(descriptor, remaining)
            if written <= 0:
                raise OSError("exclusive plan write made no progress")
            remaining = remaining[written:]
        os.fchmod(descriptor, 0)
        if os.environ.get("IDLESCREEN_C8_INJECT_FSYNC_FAILURE") == "YES":
            raise OSError("injected plan fsync failure")
        os.fsync(descriptor)
        _sync_parent(parent_descriptor)
        _verify_published_inode(parent_descriptor, output_name, descriptor)
        _verify_parent_identity(path, parent_descriptors)
        os.fchmod(descriptor, 0o400)
        if os.environ.get("IDLESCREEN_C8_INJECT_FINAL_FSYNC_FAILURE") == "YES":
            raise OSError("injected final plan fsync failure")
        os.fsync(descriptor)
        _verify_parent_identity(path, parent_descriptors)
        _verify_published_inode(parent_descriptor, output_name, descriptor)
    except BaseException as error:
        operation_error = error
        if descriptor is not None:
            try:
                _poison_descriptor(descriptor)
            except OSError as poison_error:
                removed = False
                try:
                    removed = _remove_owned_entry(
                        parent_descriptor, output_name, descriptor
                    )
                except (OSError, C8EvidenceError) as cleanup_error:
                    refusal_error = C8EvidenceError(
                        f"plan refusal cleanup failed: {cleanup_error}"
                    )
                    operation_error = refusal_error
                    operation_cause = error
                else:
                    if not removed:
                        refusal_error = C8EvidenceError(
                            "plan refusal cleanup could not remove owned inode"
                        )
                        refusal_error.__cause__ = error
                        operation_error = refusal_error
    close_error = None
    if descriptor is not None:
        close_error = _close_output_descriptor(descriptor)
    try:
        _close_descriptors(parent_descriptors)
    except OSError as error:
        if close_error is None:
            close_error = error
    if operation_error is not None:
        if close_error is not None:
            raise C8EvidenceError("plan refusal descriptor close failed") from operation_error
        if operation_cause is not None:
            raise operation_error from operation_cause
        raise operation_error
    if close_error is not None:
        raise C8EvidenceError("durable plan committed but descriptor close failed") from close_error


def validate_soak_duration(duration: int) -> None:
    if duration < 10 or duration > SOAK_MAX_DURATION_SECONDS:
        raise C8EvidenceError(
            "scheduled soak duration must be between 10 and 900 seconds"
        )


def validate_authorization(row: RowDefinition, authorization_id: str) -> None:
    if not ID_RE.fullmatch(authorization_id):
        raise C8EvidenceError(
            "authorization ID must be 8-128 safe identifier characters"
        )
    row_authorization = row.authorization_environment_variable
    if os.environ.get(row_authorization) != "YES":
        raise C8EvidenceError(
            f"refusing C8 {row.row_id}: set only "
            f"{row_authorization}=YES after class-specific authorization"
        )
    other_opt_ins = sorted(
        name
        for name in AUTHORIZATION_ENVIRONMENT_VARIABLES
        if name != row_authorization and name in os.environ
    )
    if other_opt_ins:
        raise C8EvidenceError(
            "C8 authorization must be class-scoped; unrelated opt-ins are present: "
            + ",".join(other_opt_ins)
        )


def scheduled_plan(
    args: argparse.Namespace,
    definition: MatrixDefinition,
    row: RowDefinition,
    console_state: str,
    console_captured_at: str,
) -> dict[str, object]:
    validate_soak_duration(args.duration_seconds)
    created = datetime.now(timezone.utc).replace(microsecond=0)
    expires = created + timedelta(seconds=SCHEDULE_TTL_SECONDS)
    return {
        "schema": PLAN_SCHEMA,
        "mode": "scheduled-no-action",
        "matrix_id": definition.matrix_id,
        "matrix_path": str(args.matrix),
        "row_id": row.row_id,
        "scenario": row.scenario,
        "candidate_provenance_sha256": definition.candidate["provenance_sha256"],
        "candidate_archive_tree_sha256": definition.candidate["archive_tree_sha256"],
        "candidate": dict(definition.candidate),
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
        "created_at_utc": utc_timestamp(created),
        "expires_at_utc": utc_timestamp(expires),
        "schedule": [
            {
                "kind": "operator-lifecycle",
                "action": "perform-the-authorized-lifecycle-and-confirm",
                "initiates_physical_action": False,
            },
            {
                "kind": "energy-soak",
                "executor": "unimplemented-installed-candidate-c8-soak",
                "duration_seconds": args.duration_seconds,
                "initiates_physical_action": False,
            },
        ],
        "executor": "unimplemented",
        "execution_available": False,
        "completion_claimable": False,
        "completion_requires_canonical_executor": True,
        "physical_action_performed": False,
    }


def write_plan(args: argparse.Namespace) -> Path:
    if not args.dry_run and not args.schedule_soak:
        raise C8EvidenceError(
            "a C8 plan requires --dry-run or --schedule-soak"
        )
    if args.matrix is None or args.row_id is None or args.console_state_file is None:
        raise C8EvidenceError("matrix, row ID, and console preflight are required to write a plan")
    definition = load_matrix_definition(args.matrix)
    validate_pending_row(definition, args.row_id)
    row = ROW_BY_ID[args.row_id]
    validate_authorization(row, args.authorization_id)

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
    if args.schedule_soak and (
        retained_role != "none"
        or retained_instance != "none"
        or retained_reason != "none"
        or RETAINED_CONSUMER_ENV in os.environ
    ):
        raise C8EvidenceError(
            "scheduled soak requires exact none retained-consumer tuple"
        )
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

    if args.output_plan is None:
        raise C8EvidenceError("--output-plan is required when writing a plan")
    output: Path = args.output_plan
    require_new_absolute_file(output, "output plan")
    if args.schedule_soak:
        if row.row_id != "soak":
            raise C8EvidenceError("controlled soak planning is limited to the C8 soak row")
        plan = scheduled_plan(
            args, definition, row, console_state, console_captured_at
        )
    else:
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
    write_exclusive_json(output, plan)
    return output


def reject_execution() -> None:
    raise C8EvidenceError(
        "no safe canonical installed-candidate executor exists; C8 scheduling is "
        "inert and cannot claim row completion"
    )


def main() -> int:
    try:
        args = parser().parse_args()
        if args.execute_plan is not None:
            reject_execution()
        plan = write_plan(args)
    except (C8EvidenceError, OSError, UnicodeError, ValueError) as error:
        print(f"REFUSED: {error}", file=sys.stderr)
        return 65
    if args.schedule_soak:
        print("SCHEDULED: inert C8 soak plan written; no physical action was performed.")
    else:
        print("DRY RUN: C8 authorization preflight passed; no physical action was performed.")
    print(f"Plan: {plan}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
