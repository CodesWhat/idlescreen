#!/usr/bin/python3

"""Compose one immutable, offline-verifiable C4 evidence bundle.

This command only copies already-retained evidence and rewrites its absolute
in-bundle references. It never installs, registers, launches, activates,
terminates, opens UI, changes TCC, or accesses a camera.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import stat
import subprocess
import sys
from pathlib import Path
from typing import Dict, Iterable, List, Sequence, Tuple


class CompositionFailure(Exception):
    pass


PROJECT_ROOT = Path(__file__).resolve().parents[1]
VERIFIER = PROJECT_ROOT / "scripts/verify-camera-gate-c4-evidence.py"
TOP_MANIFEST_NAME = "c4-evidence-manifest.txt"

TRANSACTION_REFERENCES = (
    "transaction_journal",
    "transaction_transitions",
    "pre_state",
    "quiescence_inventory",
    "gate_bound_state",
    "post_restore_state",
    "marker_process_inventory",
    "installed_production_identity",
    "restored_production_tree_inventory",
    "initial_helper_runtime_entitlements",
    "saver_runtime_entitlements",
)

A1_REFERENCES = (
    "log_path",
    "helper_marker_extract",
    "extension_marker_extract",
    "helper_codesign_output",
    "extension_codesign_output",
    "initial_helper_procinfo",
    "saver_procinfo",
    "configuration_snapshot",
)


def fail(message: str) -> None:
    raise CompositionFailure(message)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def require_absolute_regular_file(path_text: str, label: str) -> Path:
    path = Path(path_text)
    if not path.is_absolute() or path.is_symlink() or not path.is_file():
        fail(f"{label} must be an absolute, non-symlink regular file")
    return path.resolve(strict=True)


def require_absolute_directory(path_text: str, label: str) -> Path:
    path = Path(path_text)
    if not path.is_absolute() or path.is_symlink() or not path.is_dir():
        fail(f"{label} must be an absolute, non-symlink directory")
    return path.resolve(strict=True)


def require_descendant_file(root: Path, path_text: str, label: str) -> Path:
    path = require_absolute_regular_file(path_text, label)
    try:
        path.relative_to(root)
    except ValueError:
        fail(f"{label} escapes its retained evidence directory")
    return path


def parse_kv(path: Path, label: str) -> Tuple[List[str], Dict[str, str]]:
    keys: List[str] = []
    values: Dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        fail(f"could not read {label}: {error}")
    for line_number, line in enumerate(lines, 1):
        if "=" not in line or any(ord(character) < 0x20 for character in line):
            fail(f"malformed {label} line {line_number}")
        key, value = line.split("=", 1)
        if not key or key in values or not value:
            fail(f"empty or duplicate {label} field {key!r}")
        keys.append(key)
        values[key] = value
    return keys, values


def write_kv(path: Path, keys: Iterable[str], values: Dict[str, str]) -> None:
    path.write_text("".join(f"{key}={values[key]}\n" for key in keys), encoding="utf-8")
    path.chmod(0o600)


def copy_evidence_file(source: Path, destination: Path, label: str) -> Path:
    source = require_absolute_regular_file(str(source), label)
    if destination.exists() or destination.is_symlink():
        fail(f"refusing to replace composed evidence file: {destination}")
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    destination.chmod(0o600)
    return destination


def rebase_a1_evidence(
    source_manifest: Path, source_root: Path, destination_root: Path, mode: str
) -> Path:
    source_manifest = require_descendant_file(
        source_root, str(source_manifest), f"{mode} A1 evidence manifest"
    )
    keys, values = parse_kv(source_manifest, f"{mode} A1 evidence manifest")
    if (
        values.get("format") != "IdleScreenCameraGateEvidenceV1"
        or values.get("mode") != mode
    ):
        fail(f"{mode} A1 evidence manifest has the wrong format or mode")
    destination_manifest = destination_root / "evidence-manifest.txt"
    source_sibling = source_manifest.parent.resolve()
    for key in A1_REFERENCES:
        if key not in values:
            fail(f"{mode} A1 evidence manifest lacks {key}")
        source = require_absolute_regular_file(values[key], f"{mode} A1 {key}")
        if source.parent.resolve() != source_sibling:
            fail(f"{mode} A1 {key} is not a sibling evidence file")
        destination = destination_root / source.name
        copy_evidence_file(source, destination, f"{mode} A1 {key}")
        values[key] = str(destination)
    recovered = values.get("recovered_helper_procinfo")
    if mode == "a1tr":
        if recovered is None or recovered == "none":
            fail("A1TR evidence lacks recovered-helper procinfo")
        source = require_absolute_regular_file(
            recovered, "A1TR recovered-helper procinfo"
        )
        if source.parent.resolve() != source_sibling:
            fail("A1TR recovered-helper procinfo is not a sibling evidence file")
        destination = destination_root / source.name
        copy_evidence_file(source, destination, "A1TR recovered-helper procinfo")
        values["recovered_helper_procinfo"] = str(destination)
    elif recovered != "none":
        fail("A1T evidence unexpectedly names recovered-helper procinfo")
    destination_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    write_kv(destination_manifest, keys, values)
    return destination_manifest


def rebase_transaction(
    source_root: Path, destination_root: Path, mode: str
) -> Tuple[Path, Path]:
    source_manifest = require_descendant_file(
        source_root,
        str(source_root / "transaction-manifest.txt"),
        f"{mode} transaction manifest",
    )
    keys, values = parse_kv(source_manifest, f"{mode} transaction manifest")
    if (
        values.get("format") != "IdleScreenCameraGateC4TransactionV1"
        or values.get("mode") != mode
    ):
        fail(f"{mode} transaction manifest has the wrong format or mode")

    source_a1 = require_descendant_file(
        source_root, values.get("a1_evidence_manifest", ""), f"{mode} A1 manifest"
    )
    destination_a1 = rebase_a1_evidence(
        source_a1, source_root, destination_root / "a1", mode
    )
    values["a1_evidence_manifest"] = str(destination_a1)
    values["a1_evidence_manifest_sha256"] = sha256_file(destination_a1)

    for key in TRANSACTION_REFERENCES:
        if key not in values:
            fail(f"{mode} transaction manifest lacks {key}")
        source = require_descendant_file(source_root, values[key], f"{mode} {key}")
        destination = destination_root / source.name
        copy_evidence_file(source, destination, f"{mode} {key}")
        values[key] = str(destination)

    recovered = values.get("recovered_helper_runtime_entitlements")
    if mode == "a1tr":
        if recovered is None or recovered == "none":
            fail("A1TR transaction lacks recovered-helper runtime entitlements")
        source = require_descendant_file(
            source_root, recovered, "A1TR recovered-helper runtime entitlements"
        )
        destination = destination_root / source.name
        copy_evidence_file(
            source, destination, "A1TR recovered-helper runtime entitlements"
        )
        values["recovered_helper_runtime_entitlements"] = str(destination)
    elif recovered != "none":
        fail("A1T transaction unexpectedly names recovered-helper runtime entitlements")

    destination_manifest = destination_root / "transaction-manifest.txt"
    write_kv(destination_manifest, keys, values)
    return destination_a1, destination_manifest


def make_immutable(root: Path) -> None:
    entries = sorted(root.rglob("*"), key=lambda item: len(item.parts), reverse=True)
    for entry in entries:
        if entry.is_symlink():
            fail(f"composed evidence unexpectedly contains a symlink: {entry}")
        mode = stat.S_IMODE(entry.stat().st_mode) & ~0o222
        entry.chmod(mode)
    root.chmod(stat.S_IMODE(root.stat().st_mode) & ~0o222)


def compose(argv: Sequence[str]) -> Path:
    if len(argv) != 7:
        fail(
            "Usage: compose-camera-gate-c4-evidence.py "
            "/absolute/C3-provenance.txt /absolute/C4-gate-evidence "
            "/absolute/C4-install-evidence /absolute/C4-A1T-transaction-evidence "
            "/absolute/C4-A1TR-transaction-evidence /absolute/new-C4-evidence-root"
        )

    c3_source = require_absolute_regular_file(argv[1], "C3 provenance manifest")
    gate_root = require_absolute_directory(argv[2], "C4 gate evidence")
    install_root = require_absolute_directory(argv[3], "C4 install evidence")
    a1t_root = require_absolute_directory(argv[4], "C4 A1T transaction evidence")
    a1tr_root = require_absolute_directory(argv[5], "C4 A1TR transaction evidence")
    output_root = Path(argv[6])
    if not output_root.is_absolute() or output_root == Path("/"):
        fail("C4 output root must be a distinct absolute path")
    parent = output_root.parent
    if parent.is_symlink() or not parent.is_dir():
        fail("C4 output parent must be an existing, non-symlink directory")
    if os.path.lexists(output_root):
        fail(f"refusing to replace C4 evidence root: {output_root}")

    output_root.mkdir(mode=0o700)
    try:
        c3 = copy_evidence_file(
            c3_source, output_root / "c3-provenance.txt", "C3 provenance manifest"
        )
        binding = copy_evidence_file(
            gate_root / "IdleScreenC4GateBindingV1.txt",
            output_root / "gate-binding.txt",
            "C4 gate binding manifest",
        )
        gate = copy_evidence_file(
            gate_root / "IdleScreenC4GateManifestV1.txt",
            output_root / "synthetic-gate-manifest.txt",
            "C4 synthetic gate manifest",
        )
        install = copy_evidence_file(
            install_root / "install-manifest.txt",
            output_root / "install" / "install-manifest.txt",
            "C4 production install manifest",
        )
        candidate_tree = copy_evidence_file(
            install_root / "candidate-tree.tsv",
            output_root / "install" / "candidate-tree.tsv",
            "C4 production candidate inventory",
        )
        installed_tree = copy_evidence_file(
            install_root / "installed-tree.tsv",
            output_root / "install" / "installed-tree.tsv",
            "C4 production installed inventory",
        )
        a1t_a1, a1t_transaction = rebase_transaction(
            a1t_root, output_root / "a1t", "a1t"
        )
        a1tr_a1, a1tr_transaction = rebase_transaction(
            a1tr_root, output_root / "a1tr", "a1tr"
        )

        top = output_root / TOP_MANIFEST_NAME
        top_values = (
            ("format", "IdleScreenCameraGateC4EvidenceV1"),
            ("evidence_semantics", "topology-equivalent-camera-free"),
            ("trusted_for_production", "false"),
            ("c3_provenance_manifest", str(c3)),
            ("c3_provenance_manifest_sha256", sha256_file(c3)),
            (
                "c3_archive_tree_sha256",
                parse_kv(c3, "C3 provenance")[1].get("archive_tree_sha256", ""),
            ),
            ("gate_binding_manifest", str(binding)),
            ("gate_binding_manifest_sha256", sha256_file(binding)),
            ("synthetic_gate_manifest", str(gate)),
            ("synthetic_gate_manifest_sha256", sha256_file(gate)),
            ("production_install_manifest", str(install)),
            ("production_install_manifest_sha256", sha256_file(install)),
            ("production_candidate_tree_inventory", str(candidate_tree)),
            ("production_candidate_tree_inventory_sha256", sha256_file(candidate_tree)),
            ("production_installed_tree_inventory", str(installed_tree)),
            ("production_installed_tree_inventory_sha256", sha256_file(installed_tree)),
            ("a1t_evidence_manifest", str(a1t_a1)),
            ("a1t_evidence_manifest_sha256", sha256_file(a1t_a1)),
            ("a1t_transaction_manifest", str(a1t_transaction)),
            ("a1t_transaction_manifest_sha256", sha256_file(a1t_transaction)),
            ("a1tr_evidence_manifest", str(a1tr_a1)),
            ("a1tr_evidence_manifest_sha256", sha256_file(a1tr_a1)),
            ("a1tr_transaction_manifest", str(a1tr_transaction)),
            ("a1tr_transaction_manifest_sha256", sha256_file(a1tr_transaction)),
        )
        if not top_values[5][1]:
            fail("C3 provenance manifest lacks archive_tree_sha256")
        write_kv(top, (key for key, _ in top_values), dict(top_values))

        verification = subprocess.run(
            (str(VERIFIER), str(top)),
            text=True,
            capture_output=True,
            check=False,
        )
        if verification.returncode != 0:
            detail = (verification.stdout + verification.stderr).strip()
            fail(f"composed C4 evidence did not verify: {detail}")
        make_immutable(output_root)
        final_verification = subprocess.run(
            (str(VERIFIER), str(top)),
            text=True,
            capture_output=True,
            check=False,
        )
        if final_verification.returncode != 0:
            detail = (final_verification.stdout + final_verification.stderr).strip()
            fail(f"immutable C4 evidence did not replay: {detail}")
        return top
    except Exception:
        if output_root.exists():
            for entry in (output_root, *output_root.rglob("*")):
                try:
                    entry.chmod(stat.S_IMODE(entry.stat().st_mode) | 0o200)
                except OSError:
                    pass
            shutil.rmtree(output_root)
        raise


def main(argv: Sequence[str]) -> int:
    try:
        manifest = compose(argv)
    except (CompositionFailure, OSError, UnicodeError, ValueError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1
    print("PASS: immutable C4 evidence was composed and replayed offline.")
    print(f"Manifest: {manifest}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
