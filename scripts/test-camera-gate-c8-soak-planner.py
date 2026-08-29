#!/usr/bin/env python3
"""Deterministic contract tests for the controlled C8 soak planner."""

from __future__ import annotations

import json
import importlib.util
import ctypes
import errno
import os
import re
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PREPARER = ROOT / "scripts/prepare-camera-gate-c8-evidence.py"
PLANNER = ROOT / "scripts/run-camera-gate-c8-row.py"


def load_planner_module():
    sys.path.insert(0, str(PLANNER.parent))
    spec = importlib.util.spec_from_file_location("c8_planner", PLANNER)
    if spec is None or spec.loader is None:
        raise AssertionError("could not load planner module")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def run(*args: str, env: dict[str, str], expected: int = 0) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [sys.executable, *args],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )
    if result.returncode != expected:
        raise AssertionError(
            f"expected {expected}, got {result.returncode}: {args}\n"
            f"stdout={result.stdout}\nstderr={result.stderr}"
        )
    return result


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="idlescreen-c8-soak-planner-") as value:
        root = Path(value)
        provenance = root / "candidate-provenance.txt"
        provenance.write_text(
            "\n".join(
                (
                    "archive_tree_sha256=" + "a" * 64,
                    "team_identifier=3524374A2S",
                    "app_cdhash=" + "b" * 40,
                    "helper_cdhash=" + "c" * 40,
                    "extension_cdhash=" + "d" * 40,
                )
            )
            + "\n",
            encoding="utf-8",
        )
        matrix_root = root / "matrix"
        base_env = dict(os.environ)
        run(
            str(PREPARER),
            str(matrix_root),
            "--matrix-id",
            "matrix-c8-soak-test",
            "--candidate-provenance",
            str(provenance),
            env=base_env,
        )
        console = root / "console-state.json"
        console.write_text(
            json.dumps(
                {
                    "schema": "IdleScreenC8PreflightConsoleState/v1",
                    "captured_at_utc": datetime.now(timezone.utc)
                    .isoformat(timespec="seconds")
                    .replace("+00:00", "Z"),
                    "state": "unlocked",
                    "source": "read-console-lock-state",
                }
            ),
            encoding="utf-8",
        )
        environment = dict(base_env)
        environment["IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK"] = "YES"
        plan = root / "scheduled-plan.json"
        run(
            str(PLANNER),
            str(matrix_root / "matrix.json"),
            "soak",
            "--authorization-id",
            "authorization-c8-soak-test",
            "--console-state-file",
            str(console),
            "--output-plan",
            str(plan),
            "--schedule-soak",
            "--duration-seconds",
            "30",
            env=environment,
        )
        value = json.loads(plan.read_text(encoding="utf-8"))
        assert value["mode"] == "scheduled-no-action"
        assert value["physical_action_performed"] is False
        assert value["executor"] == "unimplemented"
        assert value["execution_available"] is False
        assert value["completion_claimable"] is False
        assert "deadline_seconds" not in value
        assert stat.S_IMODE(plan.stat().st_mode) == 0o400
        assert [step["kind"] for step in value["schedule"]] == [
            "operator-lifecycle",
            "energy-soak",
        ]
        assert value["schedule"][1]["duration_seconds"] == 30
        assert "run-performance-r1.sh" not in json.dumps(value)
        assert "shutdown" not in json.dumps(value).lower()
        assert "reboot" not in json.dumps(value).lower()
        assert "logout" not in json.dumps(value).lower()
        created = datetime.fromisoformat(value["created_at_utc"].replace("Z", "+00:00"))
        expires = datetime.fromisoformat(value["expires_at_utc"].replace("Z", "+00:00"))
        assert (expires - created).total_seconds() == 300
        assert created <= datetime.now(timezone.utc)

        named_consumer = dict(environment)
        named_consumer["IDLESCREEN_C8_AUTHORIZE_RETAINED_CONSUMER"] = "YES"
        named_plan = root / "named-consumer-plan.json"
        named_refusal = run(
            str(PLANNER),
            str(matrix_root / "matrix.json"),
            "soak",
            "--authorization-id",
            "authorization-c8-soak-test",
            "--console-state-file",
            str(console),
            "--output-plan",
            str(named_plan),
            "--schedule-soak",
            "--duration-seconds",
            "30",
            "--retained-consumer-role",
            "companion",
            "--retained-consumer-instance-id",
            "companion:test",
            "--retained-consumer-reason",
            "authorized-soak-consumer-remains",
            env=named_consumer,
            expected=65,
        )
        assert "scheduled soak requires exact none retained-consumer tuple" in named_refusal.stderr
        assert not named_plan.exists()

        exact_none_refusal = run(
            str(PLANNER),
            str(matrix_root / "matrix.json"),
            "soak",
            "--authorization-id",
            "authorization-c8-soak-test",
            "--console-state-file",
            str(console),
            "--output-plan",
            str(root / "env-consumer-plan.json"),
            "--schedule-soak",
            "--duration-seconds",
            "30",
            env=named_consumer,
            expected=65,
        )
        assert "scheduled soak requires exact none retained-consumer tuple" in exact_none_refusal.stderr

        invalid_timestamp_values = (
            "2026-08-29T12:00:00.123Z",
            "2026-08-29",
            "not-a-timeZ",
            "2026-08-29T12:00:00",
            "2026-08-29T12:00:00+00:00",
        )
        for index, timestamp in enumerate(invalid_timestamp_values):
            invalid_console = root / f"invalid-console-{index}.json"
            invalid_console.write_text(
                json.dumps(
                    {
                        "schema": "IdleScreenC8PreflightConsoleState/v1",
                        "captured_at_utc": timestamp,
                        "state": "unlocked",
                        "source": "read-console-lock-state",
                    }
                ),
                encoding="utf-8",
            )
            invalid = run(
                str(PLANNER),
                str(matrix_root / "matrix.json"),
                "soak",
                "--authorization-id",
                "authorization-c8-soak-test",
                "--console-state-file",
                str(invalid_console),
                "--output-plan",
                str(root / f"invalid-plan-{index}.json"),
                "--schedule-soak",
                "--duration-seconds",
                "30",
                env=environment,
                expected=65,
            )
            assert "Traceback" not in invalid.stderr

        symlink_plan = root / "symlink-plan.json"
        symlink_plan.symlink_to(root / "missing-plan-target.json")
        symlink_refusal = run(
            str(PLANNER),
            str(matrix_root / "matrix.json"),
            "soak",
            "--authorization-id",
            "authorization-c8-soak-test",
            "--console-state-file",
            str(console),
            "--output-plan",
            str(symlink_plan),
            "--schedule-soak",
            "--duration-seconds",
            "30",
            env=environment,
            expected=65,
        )
        assert "new absolute file" in symlink_refusal.stderr

        original_plan = plan.read_bytes()
        refused_race = run(
            str(PLANNER),
            str(matrix_root / "matrix.json"),
            "soak",
            "--authorization-id",
            "authorization-c8-soak-test",
            "--console-state-file",
            str(console),
            "--output-plan",
            str(plan),
            "--schedule-soak",
            "--duration-seconds",
            "30",
            env=environment,
            expected=65,
        )
        assert "new absolute file" in refused_race.stderr
        assert plan.read_bytes() == original_plan
        assert re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value["created_at_utc"])
        assert re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", value["expires_at_utc"])

        refused = run(
            str(PLANNER),
            "--execute-plan",
            str(plan),
            "--authorization-id",
            "authorization-c8-soak-test",
            "--output-result",
            str(root / "result.json"),
            env=environment,
            expected=65,
        )
        assert "safe canonical installed-candidate executor" in refused.stderr
        assert not (root / "result.json").exists()

        planner = load_planner_module()
        flags_plan = root / "flags-plan.json"
        open_flags: list[int] = []
        original_open = planner.os.open

        def recording_open(path, flags, mode=0o777, **kwargs):
            open_flags.append(flags)
            return original_open(path, flags, mode, **kwargs)

        planner.os.open = recording_open
        try:
            planner.write_exclusive_json(flags_plan, {"state": "ready"})
        finally:
            planner.os.open = original_open
        assert any(flags & os.O_EXCL for flags in open_flags)
        assert any(flags & getattr(os, "O_NOFOLLOW", 0) for flags in open_flags)
        assert json.loads(flags_plan.read_text(encoding="utf-8"))["state"] == "ready"

        unsafe_parent = root / "unsafe-parent"
        unsafe_parent.mkdir()
        unsafe_parent.chmod(0o777)
        unsafe_plan = unsafe_parent / "unsafe-plan.json"
        try:
            planner.write_exclusive_json(unsafe_plan, {"state": "ready"})
        except planner.C8EvidenceError:
            pass
        else:
            raise AssertionError("unsafe output parent was accepted")
        assert not unsafe_plan.exists()

        unsafe_ancestor = root / "unsafe-ancestor"
        unsafe_ancestor.mkdir()
        unsafe_descendant = unsafe_ancestor / "private"
        unsafe_descendant.mkdir()
        unsafe_ancestor.chmod(0o777)
        ancestor_plan = unsafe_descendant / "ancestor-plan.json"
        try:
            planner.write_exclusive_json(ancestor_plan, {"state": "ready"})
        except planner.C8EvidenceError:
            pass
        else:
            raise AssertionError("unsafe output ancestor was accepted")
        assert not ancestor_plan.exists()

        acl_parent = root / "acl-parent"
        acl_parent.mkdir()
        subprocess.run(
            [
                "/bin/chmod",
                "+a",
                f"user:{os.environ.get('USER', 'unknown')} allow list",
                str(acl_parent),
            ],
            check=True,
        )
        acl_plan = acl_parent / "acl-plan.json"
        try:
            planner.write_exclusive_json(acl_plan, {"state": "ready"})
        except planner.C8EvidenceError:
            pass
        else:
            raise AssertionError("extended ACL output parent was accepted")
        assert not acl_plan.exists()

        deny_parent = root / "deny-parent"
        deny_parent.mkdir()
        subprocess.run(
            ["/bin/chmod", "+a", "everyone deny delete", str(deny_parent)],
            check=True,
        )
        deny_plan = deny_parent / "deny-plan.json"
        planner.write_exclusive_json(deny_plan, {"state": "ready"})
        assert json.loads(deny_plan.read_text(encoding="utf-8"))["state"] == "ready"
        subprocess.run(
            ["/bin/chmod", "-a", "everyone deny delete", str(deny_parent)],
            check=True,
        )

        acl_fd = os.open(acl_parent, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        original_acl_api = planner._load_acl_api

        class FailingAclApi:
            def acl_get_fd_np(self, descriptor, acl_type):
                ctypes.set_errno(errno.EIO)
                return None

        class FailingEntryApi:
            def acl_get_fd_np(self, descriptor, acl_type):
                return ctypes.c_void_p(1)

            def acl_get_entry(self, acl, entry_id, entry):
                ctypes.set_errno(errno.EIO)
                return -1

            def acl_free(self, acl):
                return 0

        class FailingFreeApi(FailingEntryApi):
            def acl_get_entry(self, acl, entry_id, entry):
                return 0

            def acl_free(self, acl):
                ctypes.set_errno(errno.EIO)
                return -1

        class AllowEntryApi(FailingEntryApi):
            def acl_get_tag_type(self, entry, tag_type):
                tag_type._obj.value = planner.ACL_EXTENDED_ALLOW
                return 0

        class UnknownEntryApi(AllowEntryApi):
            def acl_get_tag_type(self, entry, tag_type):
                tag_type._obj.value = 99
                return 0

        def unavailable_acl_api():
            raise OSError(errno.ENOSYS, "ACL API unavailable")

        for acl_loader in (
            unavailable_acl_api,
            lambda: FailingAclApi(),
            lambda: FailingEntryApi(),
            lambda: FailingFreeApi(),
            lambda: AllowEntryApi(),
            lambda: UnknownEntryApi(),
        ):
            planner._load_acl_api = acl_loader
            try:
                try:
                    planner._validate_extended_acl(acl_fd, "ACL fixture")
                except planner.C8EvidenceError:
                    pass
                else:
                    raise AssertionError("ACL inspection fault was accepted")
            finally:
                planner._load_acl_api = original_acl_api
        os.close(acl_fd)

        destination_replacement_plan = root / "destination-replacement-plan.json"
        moved_original = root / "destination-original-inode"
        original_sync_parent = planner._sync_parent
        sync_calls = 0
        closed_destinations: list[int] = []
        original_close = planner.os.close

        def recording_destination_close(descriptor):
            closed_destinations.append(descriptor)
            return original_close(descriptor)

        def replace_destination_after_rename(parent_descriptor):
            nonlocal sync_calls
            sync_calls += 1
            result = original_sync_parent(parent_descriptor)
            if sync_calls == 1:
                destination_replacement_plan.rename(moved_original)
                destination_replacement_plan.write_bytes(b"replacement\n")
                destination_replacement_plan.chmod(0o644)
            return result

        planner._sync_parent = replace_destination_after_rename
        planner.os.close = recording_destination_close
        os.environ["IDLESCREEN_C8_INJECT_POISON_FSYNC_FAILURE"] = "YES"
        try:
            try:
                planner.write_exclusive_json(
                    destination_replacement_plan, {"state": "ready"}
                )
            except planner.C8EvidenceError:
                pass
            else:
                raise AssertionError("destination replacement was accepted")
        finally:
            planner._sync_parent = original_sync_parent
            planner.os.close = original_close
            os.environ.pop("IDLESCREEN_C8_INJECT_POISON_FSYNC_FAILURE", None)
        assert destination_replacement_plan.read_bytes() == b"replacement\n"
        assert stat.S_IMODE(destination_replacement_plan.stat().st_mode) == 0o644
        assert moved_original.stat().st_size == 0
        assert stat.S_IMODE(moved_original.stat().st_mode) == 0
        assert closed_destinations
        for descriptor in set(closed_destinations):
            try:
                os.fstat(descriptor)
            except OSError:
                pass
            else:
                raise AssertionError("descriptor remained open after destination refusal")

        order_plan = root / "durability-order-plan.json"
        events: list[str] = []
        original_fsync = planner.os.fsync
        original_fchmod = planner.os.fchmod
        original_verify_entry = planner._verify_published_inode
        original_verify_parent = planner._verify_parent_identity

        def recording_fsync(descriptor):
            kind = "dir" if stat.S_ISDIR(os.fstat(descriptor).st_mode) else "file"
            events.append(f"fsync-{kind}")
            return original_fsync(descriptor)

        def recording_fchmod(descriptor, mode):
            events.append(f"fchmod-{mode:o}")
            return original_fchmod(descriptor, mode)

        def recording_verify_entry(parent_descriptor, output_name, descriptor):
            events.append("verify-entry")
            return original_verify_entry(parent_descriptor, output_name, descriptor)

        def recording_verify_parent(path, parent_descriptor):
            events.append("verify-parent")
            return original_verify_parent(path, parent_descriptor)

        planner.os.fsync = recording_fsync
        planner.os.fchmod = recording_fchmod
        planner._verify_published_inode = recording_verify_entry
        planner._verify_parent_identity = recording_verify_parent
        try:
            planner.write_exclusive_json(order_plan, {"state": "ready"})
        finally:
            planner.os.fsync = original_fsync
            planner.os.fchmod = original_fchmod
            planner._verify_published_inode = original_verify_entry
            planner._verify_parent_identity = original_verify_parent
        assert events == [
            "fchmod-0",
            "fsync-file",
            "fsync-dir",
            "verify-entry",
            "verify-parent",
            "fchmod-400",
            "fsync-file",
            "verify-parent",
            "verify-entry",
        ]

        close_error_plan = root / "close-error-plan.json"
        original_close = planner.os.close
        close_calls: list[int] = []
        failed_close_descriptor = None

        def fail_regular_close(descriptor):
            nonlocal failed_close_descriptor
            close_calls.append(descriptor)
            try:
                is_regular = stat.S_ISREG(os.fstat(descriptor).st_mode)
            except OSError:
                is_regular = False
            if is_regular and failed_close_descriptor is None:
                failed_close_descriptor = descriptor
                original_close(descriptor)
                raise OSError(errno.EINTR, "injected output descriptor close interruption")
            return original_close(descriptor)

        planner.os.close = fail_regular_close
        try:
            try:
                planner.write_exclusive_json(close_error_plan, {"state": "ready"})
            except planner.C8EvidenceError as error:
                assert "durable plan" in str(error)
            else:
                raise AssertionError("output close failure was accepted")
        finally:
            planner.os.close = original_close
        assert failed_close_descriptor is not None
        try:
            os.fstat(failed_close_descriptor)
        except OSError:
            pass
        else:
            raise AssertionError("output descriptor leaked after close failure")
        assert close_calls
        for descriptor in set(close_calls):
            try:
                os.fstat(descriptor)
            except OSError:
                pass
            else:
                raise AssertionError("parent descriptor leaked after output close failure")
        assert json.loads(close_error_plan.read_text(encoding="utf-8"))["state"] == "ready"
        assert stat.S_IMODE(close_error_plan.stat().st_mode) == 0o400

        close_before_plan = root / "close-before-plan.json"
        original_close = planner.os.close
        close_before_calls: list[int] = []
        close_before_descriptor = None

        def fail_output_close_before(descriptor):
            nonlocal close_before_descriptor
            close_before_calls.append(descriptor)
            try:
                is_regular = stat.S_ISREG(os.fstat(descriptor).st_mode)
            except OSError:
                is_regular = False
            if is_regular and close_before_descriptor is None:
                close_before_descriptor = descriptor
                raise OSError(errno.EINTR, "injected output close interruption before close")
            return original_close(descriptor)

        planner.os.close = fail_output_close_before
        try:
            try:
                planner.write_exclusive_json(close_before_plan, {"state": "ready"})
            except planner.C8EvidenceError as error:
                assert "durable plan" in str(error)
            else:
                raise AssertionError("output close interruption was accepted")
        finally:
            planner.os.close = original_close
        assert close_before_descriptor is not None
        assert len(close_before_calls) >= 2
        try:
            os.fstat(close_before_descriptor)
        except OSError:
            pass
        else:
            raise AssertionError("output descriptor leaked after EINTR-before-close")

        repeated_close_plan = root / "repeated-close-plan.json"
        original_close = planner.os.close
        repeated_close_calls: list[int] = []
        repeated_close_descriptor = None
        preclose_interruptions = 3

        def fail_output_close_repeatedly(descriptor):
            nonlocal repeated_close_descriptor, preclose_interruptions
            try:
                is_regular = stat.S_ISREG(os.fstat(descriptor).st_mode)
            except OSError:
                is_regular = False
            if is_regular and repeated_close_descriptor is None:
                repeated_close_descriptor = descriptor
            repeated_close_calls.append(descriptor)
            if descriptor == repeated_close_descriptor and preclose_interruptions:
                preclose_interruptions -= 1
                raise OSError(errno.EINTR, "injected repeated output close interruption")
            return original_close(descriptor)

        planner.os.close = fail_output_close_repeatedly
        try:
            try:
                planner.write_exclusive_json(repeated_close_plan, {"state": "ready"})
            except planner.C8EvidenceError as error:
                assert "durable plan" in str(error)
            else:
                raise AssertionError("repeated output close interruption was accepted")
        finally:
            planner.os.close = original_close
        assert repeated_close_descriptor is not None
        assert len(repeated_close_calls) >= 4
        try:
            os.fstat(repeated_close_descriptor)
        except OSError:
            pass
        else:
            raise AssertionError("output descriptor leaked after repeated EINTR")

        mixed_close_plan = root / "mixed-close-plan.json"
        original_close = planner.os.close
        mixed_close_descriptor = None
        mixed_close_attempts = 0

        def fail_output_close_mixed(descriptor):
            nonlocal mixed_close_descriptor, mixed_close_attempts
            try:
                is_regular = stat.S_ISREG(os.fstat(descriptor).st_mode)
            except OSError:
                is_regular = False
            if is_regular and mixed_close_descriptor is None:
                mixed_close_descriptor = descriptor
            if descriptor == mixed_close_descriptor:
                mixed_close_attempts += 1
                if mixed_close_attempts == 1:
                    raise OSError(errno.EINTR, "injected mixed pre-close interruption")
                if mixed_close_attempts == 2:
                    original_close(descriptor)
                    raise OSError(errno.EINTR, "injected mixed post-close interruption")
            return original_close(descriptor)

        planner.os.close = fail_output_close_mixed
        try:
            try:
                planner.write_exclusive_json(mixed_close_plan, {"state": "ready"})
            except planner.C8EvidenceError as error:
                assert "durable plan" in str(error)
            else:
                raise AssertionError("mixed output close interruption was accepted")
        finally:
            planner.os.close = original_close
        assert mixed_close_descriptor is not None
        assert mixed_close_attempts == 2
        try:
            os.fstat(mixed_close_descriptor)
        except OSError:
            pass
        else:
            raise AssertionError("descriptor was double-closed after mixed EINTR")

        for close_mode in ("before", "after", "repeated"):
            parent_close_plan = root / f"parent-close-{close_mode}-plan.json"
            original_close = planner.os.close
            original_sync_parent = planner._sync_parent
            parent_close_descriptor = None
            held_parent_descriptor = None
            parent_close_calls: list[int] = []
            parent_interruptions = 3

            def record_parent_descriptor(descriptor):
                nonlocal held_parent_descriptor
                held_parent_descriptor = descriptor
                return original_sync_parent(descriptor)

            def fail_parent_close(descriptor):
                nonlocal parent_close_descriptor, parent_interruptions
                parent_close_calls.append(descriptor)
                if descriptor == held_parent_descriptor and parent_close_descriptor is None:
                    parent_close_descriptor = descriptor
                    if close_mode == "after":
                        original_close(descriptor)
                    if close_mode == "repeated":
                        parent_interruptions -= 1
                    raise OSError(errno.EINTR, f"injected parent close {close_mode}")
                if (
                    close_mode == "repeated"
                    and descriptor == parent_close_descriptor
                    and parent_interruptions
                ):
                    parent_interruptions -= 1
                    raise OSError(errno.EINTR, "injected repeated parent close")
                return original_close(descriptor)

            planner._sync_parent = record_parent_descriptor
            planner.os.close = fail_parent_close
            try:
                try:
                    planner.write_exclusive_json(parent_close_plan, {"state": "ready"})
                except planner.C8EvidenceError as error:
                    assert "durable plan" in str(error)
                else:
                    raise AssertionError("parent close interruption was accepted")
            finally:
                planner._sync_parent = original_sync_parent
                planner.os.close = original_close
            assert parent_close_descriptor is not None
            if close_mode in ("before", "repeated"):
                assert len(parent_close_calls) >= 2
            if close_mode == "repeated":
                assert len(parent_close_calls) >= 4
            try:
                os.fstat(parent_close_descriptor)
            except OSError:
                pass
            else:
                raise AssertionError(
                    f"parent descriptor leaked after EINTR-{close_mode}-close"
                )

        cleanup_error_plan = root / "cleanup-parent-fsync-error-plan.json"
        original_sync_parent = planner._sync_parent
        cleanup_sync_calls = 0

        def fail_cleanup_parent_sync(parent_descriptor):
            nonlocal cleanup_sync_calls
            cleanup_sync_calls += 1
            if cleanup_sync_calls == 2:
                raise OSError(errno.EIO, "injected cleanup parent fsync failure")
            return original_sync_parent(parent_descriptor)

        planner._sync_parent = fail_cleanup_parent_sync
        os.environ["IDLESCREEN_C8_INJECT_FINAL_FSYNC_FAILURE"] = "YES"
        os.environ["IDLESCREEN_C8_INJECT_POISON_FSYNC_FAILURE"] = "YES"
        try:
            try:
                planner.write_exclusive_json(cleanup_error_plan, {"state": "ready"})
            except planner.C8EvidenceError as error:
                assert "cleanup failed" in str(error)
                assert error.__cause__ is not None
                assert "injected cleanup parent fsync failure" in str(error.__cause__)
            else:
                raise AssertionError("cleanup parent fsync failure was accepted")
        finally:
            planner._sync_parent = original_sync_parent
            os.environ.pop("IDLESCREEN_C8_INJECT_FINAL_FSYNC_FAILURE", None)
            os.environ.pop("IDLESCREEN_C8_INJECT_POISON_FSYNC_FAILURE", None)
        assert cleanup_sync_calls == 2
        assert not cleanup_error_plan.exists()

        serialization_plan = root / "serialization-failure.json"
        original_open = planner.os.open
        opened = False
        os.environ["IDLESCREEN_C8_INJECT_SERIALIZATION_FAILURE"] = "YES"

        def recording_serialization_open(*args, **kwargs):
            nonlocal opened
            opened = True
            return original_open(*args, **kwargs)

        planner.os.open = recording_serialization_open
        try:
            try:
                planner.write_exclusive_json(serialization_plan, {"state": "ready"})
            except planner.C8EvidenceError:
                pass
            else:
                raise AssertionError("serialization fault was not injected")
        finally:
            planner.os.open = original_open
            os.environ.pop("IDLESCREEN_C8_INJECT_SERIALIZATION_FAILURE", None)
        assert not opened
        assert not serialization_plan.exists()

        for fault_name, fault_plan in (
            ("IDLESCREEN_C8_INJECT_WRITE_FAILURE", root / "write-failure.json"),
            ("IDLESCREEN_C8_INJECT_FSYNC_FAILURE", root / "fsync-failure.json"),
        ):
            closed: list[int] = []
            original_close = planner.os.close
            original_open = planner.os.open

            def recording_close(descriptor):
                closed.append(descriptor)
                return original_close(descriptor)

            planner.os.close = recording_close
            os.environ[fault_name] = "YES"
            try:
                try:
                    planner.write_exclusive_json(fault_plan, {"state": "ready"})
                except (planner.C8EvidenceError, OSError):
                    pass
                else:
                    raise AssertionError(f"{fault_name} was not injected")
            finally:
                os.environ.pop(fault_name, None)
                planner.os.close = original_close
            assert fault_plan.exists()
            assert fault_plan.stat().st_size == 0
            assert stat.S_IMODE(fault_plan.stat().st_mode) == 0
            assert closed

        parent_fsync_plan = root / "parent-fsync-failure.json"
        original_sync_parent = planner._sync_parent
        sync_calls = 0

        def fail_final_parent_sync(parent_descriptor):
            nonlocal sync_calls
            sync_calls += 1
            if sync_calls == 1:
                raise OSError("injected final parent fsync failure")
            return original_sync_parent(parent_descriptor)

        planner._sync_parent = fail_final_parent_sync
        try:
            try:
                planner.write_exclusive_json(parent_fsync_plan, {"state": "ready"})
            except (OSError, planner.C8EvidenceError):
                pass
            else:
                raise AssertionError("final parent fsync fault was not injected")
        finally:
            planner._sync_parent = original_sync_parent
        assert parent_fsync_plan.exists()
        assert parent_fsync_plan.stat().st_size == 0
        assert stat.S_IMODE(parent_fsync_plan.stat().st_mode) == 0

        final_fsync_plan = root / "final-fsync-failure.json"
        os.environ["IDLESCREEN_C8_INJECT_FINAL_FSYNC_FAILURE"] = "YES"
        try:
            try:
                planner.write_exclusive_json(final_fsync_plan, {"state": "ready"})
            except OSError:
                pass
            else:
                raise AssertionError("final file fsync fault was not injected")
        finally:
            os.environ.pop("IDLESCREEN_C8_INJECT_FINAL_FSYNC_FAILURE", None)
        assert final_fsync_plan.exists()
        assert final_fsync_plan.stat().st_size == 0
        assert stat.S_IMODE(final_fsync_plan.stat().st_mode) == 0

        poison_plan = root / "poison-failure.json"
        original_poison = planner._poison_descriptor

        def fail_poison(descriptor):
            raise OSError("injected poison failure")

        planner._poison_descriptor = fail_poison
        os.environ["IDLESCREEN_C8_INJECT_WRITE_FAILURE"] = "YES"
        try:
            try:
                planner.write_exclusive_json(poison_plan, {"state": "ready"})
            except (OSError, planner.C8EvidenceError):
                pass
            else:
                raise AssertionError("poison fault was not injected")
        finally:
            planner._poison_descriptor = original_poison
            os.environ.pop("IDLESCREEN_C8_INJECT_WRITE_FAILURE", None)
        assert not poison_plan.exists()

        final_poison_plan = root / "final-poison-failure.json"
        original_sync_parent = planner._sync_parent
        sync_calls = 0

        def count_parent_sync(parent_descriptor):
            nonlocal sync_calls
            sync_calls += 1
            return original_sync_parent(parent_descriptor)

        planner._sync_parent = count_parent_sync
        os.environ["IDLESCREEN_C8_INJECT_FINAL_FSYNC_FAILURE"] = "YES"
        os.environ["IDLESCREEN_C8_INJECT_POISON_FSYNC_FAILURE"] = "YES"
        try:
            try:
                planner.write_exclusive_json(final_poison_plan, {"state": "ready"})
            except (OSError, planner.C8EvidenceError):
                pass
            else:
                raise AssertionError("final fsync poison fault was not injected")
        finally:
            planner._sync_parent = original_sync_parent
            os.environ.pop("IDLESCREEN_C8_INJECT_FINAL_FSYNC_FAILURE", None)
            os.environ.pop("IDLESCREEN_C8_INJECT_POISON_FSYNC_FAILURE", None)
        assert not final_poison_plan.exists()
        assert sync_calls == 2

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
