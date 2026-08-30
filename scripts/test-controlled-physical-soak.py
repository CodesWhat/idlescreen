#!/usr/bin/env python3
"""Deterministic contract fixtures for the bounded attended soak runner."""

from __future__ import annotations

import importlib.util
import json
import os
import copy
import plistlib
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PREPARER = ROOT / "scripts/prepare-camera-gate-c8-evidence.py"
RUNNER = ROOT / "scripts/run-controlled-physical-soak.py"
MODULE = ROOT / "scripts/controlled_physical_soak.py"
CLI = ROOT / "scripts/run-controlled-physical-soak.py"


def load_runner():
    sys.path.insert(0, str(RUNNER.parent))
    spec = importlib.util.spec_from_file_location("controlled_physical_soak", MODULE)
    if spec is None or spec.loader is None:
        raise AssertionError("could not load controlled soak runner")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


def load_cli():
    spec = importlib.util.spec_from_file_location("controlled_physical_soak_cli", CLI)
    if spec is None or spec.loader is None:
        raise AssertionError("could not load controlled soak CLI")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Fixtures:
    def __init__(self, root: Path, runner):
        self.root = root
        self.runner = runner
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
        self.matrix = root / "matrix"
        subprocess.run(
            [
                sys.executable,
                str(PREPARER),
                str(self.matrix),
                "--matrix-id",
                "matrix-controlled-soak-test",
                "--candidate-provenance",
                str(provenance),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        self.matrix_path = self.matrix / "matrix.json"
        self.now = datetime(2026, 8, 29, 20, 0, tzinfo=timezone.utc)
        self.identity = {
            "app_path": "/Applications/idlescreen.app",
            "app_executable_path": str(runner.APP_EXECUTABLE_PATH),
            "team_identifier": "3524374A2S",
            "app_cdhash": "b" * 40,
            "helper_cdhash": "c" * 40,
            "extension_cdhash": "d" * 40,
            "profiles_valid": True,
            "production_marker_absent": True,
            "provenance_archive_tree_sha256": "a" * 64,
        }

    def plan(self, authorization_id="authorization-controlled-soak"):
        os.environ["IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK"] = "YES"
        plan = self.runner.build_plan(
            self.matrix_path,
            authorization_id,
            30,
            now=self.now,
            candidate_path=Path("/Applications/idlescreen.app"),
        )
        self.identity.update(plan["candidate"])
        return plan

    def dependencies(self, console=None, candidate=None, lifecycle=None, sampler=None, processes=None, cleanup=None):
        return self.runner.RunnerDependencies(
            console_probe=console or (lambda: {"state": "unlocked"}),
            candidate_probe=candidate or (lambda: dict(self.identity)),
            lifecycle_collector=lifecycle
            or (lambda deadline: {"events": [{"instance_id": "saver-a", "kind": "start", "sequence": 1}, {"instance_id": "saver-a", "kind": "stop", "sequence": 2}]}),
            energy_sampler=sampler
            or (lambda pids, deadline: {
                "samples": [
                    {"pid": pid, "cpu": 1.0, "power": 2.0, "mem": "3M", "index": offset * 30 + index}
                    for pid in (4242, 4343)
                    for index in range(30)
                    for offset in [0 if pid == 4242 else 1]
                ],
                "sample_interval_seconds": 1,
                "sample_count": 1,
                "coverage": 1.0,
            }),
            process_probe=processes
            or (
                lambda: [
                    {"pid": 4242, "path": self.identity["app_executable_path"], "cdhash": self.identity["app_cdhash"], "start_identity": "100:1"},
                    {"pid": 4343, "path": str(self.runner.HELPER_PATH), "cdhash": self.identity["helper_cdhash"], "start_identity": "100:2"},
                ]
            ),
            cleanup=cleanup or (lambda: True),
        )


def expect_refusal(function, text):
    try:
        function()
    except Exception as error:
        if text not in str(error):
            raise AssertionError(f"expected {text!r}, got {error!r}") from error
    else:
        raise AssertionError(f"expected refusal containing {text!r}")


def expect_failure(function, text):
    result = function()
    assert result["status"] == "failed"
    assert any(text in reason for reason in result["failure_reasons"])


def main() -> int:
    runner = load_runner()
    cli = load_cli()
    with tempfile.TemporaryDirectory(prefix="idlescreen-controlled-soak-") as value:
        fixtures = Fixtures(Path(value), runner)

        plan = fixtures.plan()
        assert plan["schema"] == runner.PLAN_SCHEMA
        assert plan["schema"] != runner.ENERGY_SCHEMA
        assert plan["schema"] != runner.RESULT_SCHEMA
        assert plan["created_at_utc"] == "2026-08-29T20:00:00Z"
        assert plan["expires_at_utc"] == "2026-08-29T20:05:00Z"
        assert plan["candidate"]["app_path"] == "/Applications/idlescreen.app"
        assert plan["c8_evidence_completed"] is False
        assert plan["duration_seconds"] == 30
        profile_payload = {
            "ExpirationDate": datetime(2040, 1, 1, tzinfo=timezone.utc),
            "DeveloperCertificates": [b"exact-leaf"],
            "ProvisionsAllDevices": True,
            "TeamIdentifier": [runner.TEAM_IDENTIFIER],
            "Entitlements": {
                "com.apple.developer.team-identifier": runner.TEAM_IDENTIFIER,
                "com.apple.application-identifier": f"{runner.TEAM_IDENTIFIER}.com.idlescreen.app",
                "get-task-allow": False,
                "com.apple.security.application-groups": ["group.com.idlescreen.shared"],
            },
        }
        assert runner._validate_profile_payload(profile_payload, "com.idlescreen.app", [b"exact-leaf"])
        serialized_profile = plistlib.loads(plistlib.dumps(profile_payload))
        assert serialized_profile["ExpirationDate"].tzinfo is None
        assert runner._validate_profile_payload(serialized_profile, "com.idlescreen.app", [b"exact-leaf"])
        absent_get_task_allow = copy.deepcopy(profile_payload)
        del absent_get_task_allow["Entitlements"]["get-task-allow"]
        absent_get_task_allow = plistlib.loads(plistlib.dumps(absent_get_task_allow))
        assert runner._validate_profile_payload(absent_get_task_allow, "com.idlescreen.app", [b"exact-leaf"])
        enabled_get_task_allow = copy.deepcopy(profile_payload)
        enabled_get_task_allow["Entitlements"]["get-task-allow"] = True
        enabled_get_task_allow = plistlib.loads(plistlib.dumps(enabled_get_task_allow))
        assert not runner._validate_profile_payload(enabled_get_task_allow, "com.idlescreen.app", [b"exact-leaf"])
        inverted_distribution = copy.deepcopy(profile_payload)
        inverted_distribution["ProvisionsAllDevices"] = False
        assert not runner._validate_profile_payload(inverted_distribution, "com.idlescreen.app", [b"exact-leaf"])
        unrelated_signer = copy.deepcopy(profile_payload)
        unrelated_signer["DeveloperCertificates"] = [b"unrelated-leaf"]
        assert not runner._validate_profile_payload(unrelated_signer, "com.idlescreen.app", [b"exact-leaf"])
        missing_team_entitlement = copy.deepcopy(profile_payload)
        del missing_team_entitlement["Entitlements"]["com.apple.developer.team-identifier"]
        assert not runner._validate_profile_payload(missing_team_entitlement, "com.idlescreen.app", [b"exact-leaf"])
        expect_refusal(
            lambda: fixtures.runner.validate_plan_document(
                {**plan, "duration_seconds": True}
            ),
            "duration",
        )
        os.environ["IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK"] = "YES"
        os.environ["IDLESCREEN_C8_AUTHORIZE_SLEEP_WAKE"] = "YES"
        try:
            expect_refusal(
                lambda: fixtures.runner.build_plan(
                    fixtures.matrix_path,
                    "authorization-controlled-soak",
                    30,
                    now=fixtures.now + timedelta(seconds=1),
                    candidate_path=Path("/Applications/idlescreen.app"),
                ),
                "unrelated",
            )
        finally:
            os.environ.pop("IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK", None)
            os.environ.pop("IDLESCREEN_C8_AUTHORIZE_SLEEP_WAKE", None)

        plan_path = Path(value) / "plan.json"
        result_path = Path(value) / "result.json"
        energy_path = Path(value) / "energy.json"
        runner.write_json_atomic(plan_path, plan)
        original_cli_argv = sys.argv[:]
        original_cli_execute = cli.execute_plan
        try:
            for raised, suffix in ((EOFError, "eof"), (KeyboardInterrupt, "interrupt")):
                cli.execute_plan = lambda *args, raised=raised, **kwargs: (_ for _ in ()).throw(raised())
                sys.argv = [
                    str(CLI),
                    "--execute-plan",
                    str(plan_path),
                    "--output-result",
                    str(Path(value) / f"cli-{suffix}-result.json"),
                    "--output-energy",
                    str(Path(value) / f"cli-{suffix}-energy.json"),
                ]
                assert cli.main() == 65
        finally:
            sys.argv = original_cli_argv
            cli.execute_plan = original_cli_execute
        os.environ["IDLESCREEN_ALLOW_PHYSICAL_TESTS"] = "YES"
        os.environ["IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK"] = "YES"
        try:
            success = runner.execute_plan(
                plan_path,
                result_path,
                energy_path,
                now=fixtures.now + timedelta(seconds=1),
                dependencies=fixtures.dependencies(),
                tty_available=True,
                confirmation=lambda prompt: prompt,
            )
        finally:
            os.environ.pop("IDLESCREEN_ALLOW_PHYSICAL_TESTS", None)
            os.environ.pop("IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK", None)
        assert success["status"] == "completed"
        assert success["c8_evidence_completed"] is False
        assert success["energy_artifact_sha256"] == runner.sha256_file(energy_path)
        assert json.loads(result_path.read_text(encoding="utf-8"))["plan_digest"] == success["plan_digest"]
        assert success["started_at_utc"] < success["completed_at_utc"]

        occupied = Path(value) / "occupied-result.json"
        occupied.write_text("operator-owned\n", encoding="utf-8")
        before = occupied.read_bytes()
        observed = []
        os.environ["IDLESCREEN_ALLOW_PHYSICAL_TESTS"] = "YES"
        os.environ["IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK"] = "YES"
        try:
            occupied_result = runner.execute_plan(
                plan_path,
                occupied,
                Path(value) / "occupied-energy.json",
                now=fixtures.now + timedelta(seconds=1),
                dependencies=fixtures.dependencies(
                    lifecycle=lambda deadline: observed.append("lifecycle") or {},
                    sampler=lambda pids, deadline: observed.append("energy") or {},
                ),
                tty_available=True,
                confirmation=lambda prompt: prompt,
            )
        finally:
            os.environ.pop("IDLESCREEN_ALLOW_PHYSICAL_TESTS", None)
            os.environ.pop("IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK", None)
        assert occupied_result["status"] == "failed"
        assert "occupied" in occupied_result["failure_reasons"][0]
        assert occupied.read_bytes() == before
        assert observed == []

        supervisor_events = []
        def subprocess_lifecycle(deadline):
            process = subprocess.Popen(
                [sys.executable, "-c", "import time; print('Animation started', flush=True); time.sleep(2)"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
                text=False,
            )
            try:
                output, timed_out = runner._read_bounded(process, deadline)
                assert "Animation started" in output
                assert timed_out
                return {"events": [{"instance_id": "saver-a", "kind": "start", "sequence": 1}, {"instance_id": "saver-a", "kind": "stop", "sequence": 2}]}
            finally:
                if process.poll() is None:
                    runner._terminate_group(process)
                assert runner._group_gone(process)

        def subprocess_energy(pids, deadline):
            process = subprocess.Popen(
                [sys.executable, "-c", "import time; print('4242 1.0 2.0 3M', flush=True); time.sleep(2)"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                start_new_session=True,
                text=False,
            )
            try:
                output, timed_out = runner._read_bounded(process, deadline)
                assert "4242" in output
                assert timed_out
                return {
                    "samples": [{"pid": 4242, "cpu": 1.0, "power": 2.0, "mem": "3M", "index": 0}],
                    "sample_interval_seconds": 1,
                }
            finally:
                if process.poll() is None:
                    runner._terminate_group(process)
                assert runner._group_gone(process)

        realistic = runner.supervise_observation(
            0.75, [4242], subprocess_lifecycle, subprocess_energy
        )
        assert realistic["energy"]["sample_count"] == 1

        supervisor_result = runner.supervise_observation(
            0.05,
            [4242],
            lambda deadline: supervisor_events.append("lifecycle") or {"events": [{"instance_id": "saver-a", "kind": "start", "sequence": 1}, {"instance_id": "saver-a", "kind": "stop", "sequence": 2}]},
            lambda pids, deadline: supervisor_events.append("energy") or {
                "samples": [{"pid": 4242, "cpu": 1.0, "power": 2.0, "mem": "3M", "index": 0}],
                "sample_interval_seconds": 1,
                "sample_count": 1,
                "coverage": 1.0,
            },
        )
        assert set(supervisor_events) == {"lifecycle", "energy"}
        assert supervisor_result["energy"]["sample_count"] == 1
        expect_refusal(
            lambda: runner.supervise_observation(
                900,
                [4242],
                lambda deadline: {"events": [{"instance_id": "saver-a", "kind": "start", "sequence": 1}, {"instance_id": "saver-a", "kind": "stop", "sequence": 2}]},
                lambda pids, deadline: {
                    "samples": [{"pid": 4242, "cpu": 1.0, "power": 2.0, "mem": "3M", "index": 0}],
                    "sample_interval_seconds": 1,
                },
            ),
            "insufficient",
        )

        os.environ["IDLESCREEN_ALLOW_PHYSICAL_TESTS"] = "YES"
        os.environ["IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK"] = "YES"
        try:
            expect_failure(
                lambda: runner.execute_plan(
                    plan_path,
                    Path(value) / "replay-result.json",
                    Path(value) / "replay-energy.json",
                    now=fixtures.now + timedelta(seconds=2),
                    dependencies=fixtures.dependencies(),
                    tty_available=True,
                    confirmation=lambda prompt: prompt,
                ),
                "already claimed",
            )
        finally:
            os.environ.pop("IDLESCREEN_ALLOW_PHYSICAL_TESTS", None)
            os.environ.pop("IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK", None)

        os.environ["IDLESCREEN_ALLOW_PHYSICAL_TESTS"] = "YES"
        os.environ["IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK"] = "YES"
        expired = fixtures.plan()
        expired_path = Path(value) / "expired-plan.json"
        runner.write_json_atomic(expired_path, expired)
        expect_failure(
            lambda: runner.execute_plan(
                expired_path,
                Path(value) / "expired-result.json",
                Path(value) / "expired-energy.json",
                now=fixtures.now + timedelta(seconds=301),
                dependencies=fixtures.dependencies(),
                tty_available=True,
                confirmation=lambda prompt: prompt,
            ),
            "expired",
        )

        no_tty_plan = fixtures.plan()
        no_tty_path = Path(value) / "no-tty-plan.json"
        runner.write_json_atomic(no_tty_path, no_tty_plan)
        expect_failure(
            lambda: runner.execute_plan(
                no_tty_path,
                Path(value) / "no-tty-result.json",
                Path(value) / "no-tty-energy.json",
                now=fixtures.now + timedelta(seconds=1),
                dependencies=fixtures.dependencies(),
                tty_available=False,
                confirmation=lambda prompt: prompt,
            ),
            "TTY",
        )
        assert not (Path(value) / "no-tty-result.json").exists()
        assert not (Path(value) / "no-tty-energy.json").exists()

        decline_plan = fixtures.plan()
        decline_path = Path(value) / "decline-plan.json"
        runner.write_json_atomic(decline_path, decline_plan)
        expect_failure(
            lambda: runner.execute_plan(
                decline_path,
                Path(value) / "decline-result.json",
                Path(value) / "decline-energy.json",
                now=fixtures.now + timedelta(seconds=1),
                dependencies=fixtures.dependencies(),
                tty_available=True,
                confirmation=lambda prompt: False,
            ),
            "declined",
        )

        drift_plan = fixtures.plan()
        drift_path = Path(value) / "drift-plan.json"
        runner.write_json_atomic(drift_path, drift_plan)
        drift_identity = dict(fixtures.identity)
        drift_identity["app_cdhash"] = "e" * 40
        expect_failure(
            lambda: runner.execute_plan(
                drift_path,
                Path(value) / "drift-result.json",
                Path(value) / "drift-energy.json",
                now=fixtures.now + timedelta(seconds=1),
                dependencies=fixtures.dependencies(candidate=lambda: drift_identity),
                tty_available=True,
                confirmation=lambda prompt: prompt,
            ),
            "candidate",
        )

        console_states = iter(("unlocked", "locked"))
        boundary_plan = fixtures.plan()
        boundary_path = Path(value) / "boundary-plan.json"
        runner.write_json_atomic(boundary_path, boundary_plan)
        expect_failure(
            lambda: runner.execute_plan(
                boundary_path,
                Path(value) / "boundary-result.json",
                Path(value) / "boundary-energy.json",
                now=fixtures.now + timedelta(seconds=1),
                dependencies=fixtures.dependencies(
                    console=lambda: {"state": next(console_states)}
                ),
                tty_available=True,
                confirmation=lambda prompt: prompt,
            ),
            "console",
        )
        os.environ.pop("IDLESCREEN_ALLOW_PHYSICAL_TESTS", None)
        os.environ.pop("IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK", None)

        process_drift_plan = fixtures.plan()
        process_drift_path = Path(value) / "process-drift-plan.json"
        runner.write_json_atomic(process_drift_path, process_drift_plan)
        process_states = iter(
            (
                [{"pid": 4242, "path": fixtures.identity["app_executable_path"], "cdhash": fixtures.identity["app_cdhash"], "start_identity": "100:1"}, {"pid": 4343, "path": str(runner.HELPER_PATH), "cdhash": fixtures.identity["helper_cdhash"], "start_identity": "100:2"}],
                [{"pid": 4242, "path": fixtures.identity["app_executable_path"], "cdhash": fixtures.identity["app_cdhash"], "start_identity": "101:1"}, {"pid": 4343, "path": str(runner.HELPER_PATH), "cdhash": fixtures.identity["helper_cdhash"], "start_identity": "100:2"}],
            )
        )
        os.environ["IDLESCREEN_ALLOW_PHYSICAL_TESTS"] = "YES"
        os.environ["IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK"] = "YES"
        try:
            process_drift_result = runner.execute_plan(
                process_drift_path,
                Path(value) / "process-drift-result.json",
                Path(value) / "process-drift-energy.json",
                now=fixtures.now + timedelta(seconds=1),
                dependencies=fixtures.dependencies(processes=lambda: next(process_states)),
                tty_available=True,
                confirmation=lambda prompt: prompt,
            )
        finally:
            os.environ.pop("IDLESCREEN_ALLOW_PHYSICAL_TESTS", None)
            os.environ.pop("IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK", None)
        assert process_drift_result["status"] == "failed"
        assert "process identity" in process_drift_result["failure_reasons"][0]

        cleanup_plan = fixtures.plan()
        cleanup_path = Path(value) / "cleanup-plan.json"
        runner.write_json_atomic(cleanup_path, cleanup_plan)
        os.environ["IDLESCREEN_ALLOW_PHYSICAL_TESTS"] = "YES"
        os.environ["IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK"] = "YES"
        try:
            cleanup_result = runner.execute_plan(
                cleanup_path,
                Path(value) / "cleanup-result.json",
                Path(value) / "cleanup-energy.json",
                now=fixtures.now + timedelta(seconds=1),
                dependencies=fixtures.dependencies(cleanup=lambda: False),
                tty_available=True,
                confirmation=lambda prompt: prompt,
            )
        finally:
            os.environ.pop("IDLESCREEN_ALLOW_PHYSICAL_TESTS", None)
            os.environ.pop("IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK", None)
        assert cleanup_result["status"] == "failed"
        assert "cleanup" in cleanup_result["failure_reasons"][0]

        orphan_plan = fixtures.plan("authorization-orphan-energy")
        orphan_plan_path = Path(value) / "orphan-plan.json"
        orphan_result_path = Path(value) / "orphan-result.json"
        orphan_energy_path = Path(value) / "orphan-energy.json"
        runner.write_json_atomic(orphan_plan_path, orphan_plan)
        original_verify_result = runner.verify_result_document

        def fail_completed_result(value, plan_digest):
            if isinstance(value, dict) and value.get("status") == "completed":
                raise runner.ControlledSoakError("injected result verification failure")
            return original_verify_result(value, plan_digest)

        runner.verify_result_document = fail_completed_result
        os.environ["IDLESCREEN_ALLOW_PHYSICAL_TESTS"] = "YES"
        os.environ["IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK"] = "YES"
        try:
            orphan_result = runner.execute_plan(
                orphan_plan_path,
                orphan_result_path,
                orphan_energy_path,
                now=fixtures.now + timedelta(seconds=1),
                dependencies=fixtures.dependencies(),
                tty_available=True,
                confirmation=lambda prompt: prompt,
            )
        finally:
            runner.verify_result_document = original_verify_result
            os.environ.pop("IDLESCREEN_ALLOW_PHYSICAL_TESTS", None)
            os.environ.pop("IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK", None)
        assert orphan_result["status"] == "failed"
        assert not orphan_energy_path.exists()
        assert orphan_result_path.is_file()

        interrupt_plan = fixtures.plan("authorization-result-interrupt")
        interrupt_plan_path = Path(value) / "result-interrupt-plan.json"
        interrupt_result_path = Path(value) / "result-interrupt-result.json"
        interrupt_energy_path = Path(value) / "result-interrupt-energy.json"
        runner.write_json_atomic(interrupt_plan_path, interrupt_plan)
        original_publish_reserved = runner._publish_reserved

        def interrupt_after_completed_publish(reservation, document):
            original_publish_reserved(reservation, document)
            if isinstance(document, dict) and document.get("status") == "completed":
                raise KeyboardInterrupt()

        runner._publish_reserved = interrupt_after_completed_publish
        os.environ["IDLESCREEN_ALLOW_PHYSICAL_TESTS"] = "YES"
        os.environ["IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK"] = "YES"
        try:
            try:
                runner.execute_plan(
                    interrupt_plan_path,
                    interrupt_result_path,
                    interrupt_energy_path,
                    now=fixtures.now + timedelta(seconds=1),
                    dependencies=fixtures.dependencies(),
                    tty_available=True,
                    confirmation=lambda prompt: prompt,
                )
            except KeyboardInterrupt:
                pass
            else:
                raise AssertionError("post-publication interrupt was swallowed")
        finally:
            runner._publish_reserved = original_publish_reserved
            os.environ.pop("IDLESCREEN_ALLOW_PHYSICAL_TESTS", None)
            os.environ.pop("IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK", None)
        assert json.loads(interrupt_result_path.read_text(encoding="utf-8"))["status"] == "completed"
        assert interrupt_energy_path.exists()

        internal_interrupt_plan = fixtures.plan("authorization-internal-result-interrupt")
        internal_plan_path = Path(value) / "internal-result-interrupt-plan.json"
        internal_result_path = Path(value) / "internal-result-interrupt-result.json"
        internal_energy_path = Path(value) / "internal-result-interrupt-energy.json"
        runner.write_json_atomic(internal_plan_path, internal_interrupt_plan)
        original_mark_publication_committed = runner._mark_publication_committed

        def interrupt_after_publication_marker(reservation, document):
            original_mark_publication_committed(reservation, document)
            if isinstance(document, dict) and document.get("status") == "completed":
                raise KeyboardInterrupt()

        runner._mark_publication_committed = interrupt_after_publication_marker
        os.environ["IDLESCREEN_ALLOW_PHYSICAL_TESTS"] = "YES"
        os.environ["IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK"] = "YES"
        try:
            try:
                runner.execute_plan(
                    internal_plan_path,
                    internal_result_path,
                    internal_energy_path,
                    now=fixtures.now + timedelta(seconds=1),
                    dependencies=fixtures.dependencies(),
                    tty_available=True,
                    confirmation=lambda prompt: prompt,
                )
            except KeyboardInterrupt:
                pass
            else:
                raise AssertionError("internal publication interrupt was swallowed")
        finally:
            runner._mark_publication_committed = original_mark_publication_committed
            os.environ.pop("IDLESCREEN_ALLOW_PHYSICAL_TESTS", None)
            os.environ.pop("IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK", None)
        assert not internal_result_path.exists()
        assert not internal_energy_path.exists()

        runner.verify_energy_document(
            {
                "schema": runner.ENERGY_SCHEMA,
                "plan_digest": plan["plan_digest"],
                "sampled_pids": [4242],
                "samples": [{"pid": 4242, "cpu": 1, "power": 2, "mem": "3M", "index": 0}],
                "sample_interval_seconds": 1,
                "sample_count": 1,
                "duration_seconds": 1,
                "per_pid_counts": {"4242": 1},
                "coverage": 1.0,
            },
            plan["plan_digest"],
        )
        expect_refusal(
            lambda: runner.verify_energy_document(
                {
                    "schema": runner.ENERGY_SCHEMA,
                    "plan_digest": "0" * 64,
                    "sampled_pids": [4242],
                    "samples": [{"pid": 4242, "cpu": 1, "power": 2, "mem": "3M", "index": 0}],
                    "sample_interval_seconds": 1,
                    "sample_count": 1,
                    "duration_seconds": 1,
                    "per_pid_counts": {"4242": 1},
                    "coverage": 1.0,
                },
                plan["plan_digest"],
            ),
            "bound",
        )

        for label, sampler in (
            ("sampling", lambda pids, deadline: (_ for _ in ()).throw(OSError("sampler failed"))),
            ("timeout", lambda pids, deadline: (_ for _ in ()).throw(TimeoutError("sampler timeout"))),
        ):
            failure_plan = fixtures.plan()
            failure_path = Path(value) / f"{label}-plan.json"
            failure_result = Path(value) / f"{label}-result.json"
            failure_energy = Path(value) / f"{label}-energy.json"
            runner.write_json_atomic(failure_path, failure_plan)
            os.environ["IDLESCREEN_ALLOW_PHYSICAL_TESTS"] = "YES"
            os.environ["IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK"] = "YES"
            try:
                result = runner.execute_plan(
                    failure_path,
                    failure_result,
                    failure_energy,
                    now=fixtures.now + timedelta(seconds=1),
                    dependencies=fixtures.dependencies(sampler=sampler),
                    tty_available=True,
                    confirmation=lambda prompt: prompt,
                )
            finally:
                os.environ.pop("IDLESCREEN_ALLOW_PHYSICAL_TESTS", None)
                os.environ.pop("IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK", None)
            assert result["status"] == "failed"
            assert result["c8_evidence_completed"] is False
            assert failure_result.is_file()

        expect_refusal(
            lambda: runner.verify_energy_document(
                {
                    "schema": runner.ENERGY_SCHEMA,
                    "plan_digest": plan["plan_digest"],
                    "sampled_pids": [4242],
                    "samples": [{"pid": 4242, "cpu": 1, "power": 2, "mem": "3M", "index": 0}],
                    "sample_interval_seconds": 1,
                    "sample_count": 1,
                    "duration_seconds": 1,
                    "per_pid_counts": {"4242": 1},
                    "coverage": 1.0,
                },
                plan["plan_digest"],
                plan_duration_seconds=30,
            ),
            "duration",
        )
        expect_refusal(
            lambda: runner.validate_lifecycle_observations(
                {"events": [{"instance_id": "saver-a", "kind": "stop", "sequence": 1}]}
            ),
            "start",
        )
        assert runner.verify_result_document(
            runner._failure(None, "plan could not be loaded"), None
        ) is None
        assert hasattr(runner, "_open_plan")
        assert hasattr(runner, "_ProcBsdInfo")
        assert hasattr(runner, "_parse_lifecycle_lines")
        assert hasattr(runner, "_wait_group_gone")
        original_matrix_loader = runner._C8.load_matrix_definition
        runner._C8.load_matrix_definition = lambda path: (_ for _ in ()).throw(
            AssertionError("matrix binding must not reopen through pathname loader")
        )
        try:
            runner._validate_matrix_binding(plan)
        finally:
            runner._C8.load_matrix_definition = original_matrix_loader
        original_source_reader = runner._read_trusted_source
        provenance_path = fixtures.matrix_path.parent / "candidate-provenance.txt"
        saved_provenance = fixtures.matrix_path.parent / "candidate-provenance.saved"
        swapped_provenance = fixtures.matrix_path.parent / "candidate-provenance.swap"
        swapped_source = False

        def swap_source_reader(parent_descriptor, name):
            nonlocal swapped_source
            if name == "candidate-provenance.txt" and not swapped_source:
                swapped_source = True
                provenance_path.rename(saved_provenance)
                swapped_provenance.write_bytes(saved_provenance.read_bytes())
                swapped_provenance.rename(provenance_path)
                try:
                    return original_source_reader(parent_descriptor, name)
                finally:
                    provenance_path.rename(swapped_provenance)
                    saved_provenance.rename(provenance_path)
            return original_source_reader(parent_descriptor, name)

        runner._read_trusted_source = swap_source_reader
        try:
            expect_refusal(lambda: runner._validate_matrix_binding(plan), "written inode")
        finally:
            runner._read_trusted_source = original_source_reader
        mode_plan_path = Path(value) / "mode-plan.json"
        runner.write_json_atomic(mode_plan_path, fixtures.plan("authorization-mode-plan"))
        mode_plan_path.chmod(0o666)
        expect_refusal(lambda: runner._open_plan(mode_plan_path), "mode")
        missing_provenance = dict(fixtures.identity)
        missing_provenance.pop("provenance_sha256", None)
        expect_refusal(
            lambda: runner._validate_candidate(missing_provenance, fixtures.plan()),
            "provenance",
        )
        assert runner._failure(None, "")["failure_reasons"] == ["controlled soak failed"]

        moved_plan = fixtures.plan("authorization-moved-plan")
        moved_path = Path(value) / "moved-plan.json"
        runner.write_json_atomic(moved_path, moved_plan)
        moved_handle = runner._open_plan(moved_path)
        moved_elsewhere = Path(value) / "moved-plan-away.json"
        moved_path.rename(moved_elsewhere)
        try:
            expect_refusal(
                lambda: runner._claim(moved_handle, moved_plan["plan_digest"]),
                "claim",
            )
        finally:
            runner._close_plan(moved_handle)

        mismatch = {"events": [{"instance_id": "saver-a", "kind": "start", "sequence": 1}, {"instance_id": "saver-b", "kind": "stop", "sequence": 2}]}
        expect_refusal(lambda: runner.validate_lifecycle_observations(mismatch), "different")
        interleaved = runner._parse_lifecycle_lines(
            "Animation started instance_id=saver-a\n"
            "Animation stopped instance_id=saver-b\n"
            "Animation stopped instance_id=saver-a\n"
        )
        runner.validate_lifecycle_observations(interleaved)

        reserve_plan = fixtures.plan("authorization-reservation-failure")
        reserve_path = Path(value) / "reservation-plan.json"
        runner.write_json_atomic(reserve_path, reserve_plan)
        original_reserve = runner._reserve_output
        reserve_calls = []
        def fail_energy_reservation(path):
            reserve_calls.append(path)
            if len(reserve_calls) == 2:
                raise runner.ControlledSoakError("energy output is occupied")
            return original_reserve(path)
        runner._reserve_output = fail_energy_reservation
        os.environ["IDLESCREEN_ALLOW_PHYSICAL_TESTS"] = "YES"
        os.environ["IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK"] = "YES"
        reserve_result_path = Path(value) / "reservation-result.json"
        try:
            reservation_result = runner.execute_plan(
                reserve_path,
                reserve_result_path,
                Path(value) / "reservation-energy.json",
                now=fixtures.now + timedelta(seconds=1),
                dependencies=fixtures.dependencies(),
                tty_available=True,
                confirmation=lambda prompt: prompt,
            )
        finally:
            runner._reserve_output = original_reserve
            os.environ.pop("IDLESCREEN_ALLOW_PHYSICAL_TESTS", None)
            os.environ.pop("IDLESCREEN_C8_AUTHORIZE_EXTENDED_SOAK", None)
        assert reservation_result["status"] == "failed"
        assert reserve_result_path.is_file()
        runner.verify_result_document(json.loads(reserve_result_path.read_text()), reservation_result["plan_digest"])

        print("PASS: controlled attended soak runner contracts cover inert planning, consent, boundaries, replay, lifecycle, energy, privacy, and failure-shaped results.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
