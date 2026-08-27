#!/usr/bin/env python3

import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"FAIL: {message}")


def read_manifest(path: Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line or "=" not in line:
            fail("candidate manifest contains a malformed line")
        key, value = line.split("=", 1)
        if not key or not value or key in values:
            fail(f"candidate manifest has a missing or duplicate key: {key}")
        values[key] = value
    return values


def required(values: dict[str, str], key: str) -> str:
    value = values.get(key)
    if not value:
        fail(f"candidate manifest has no unique {key}")
    return value


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def commit_timestamp(project_root: Path, commit: str) -> str:
    result = subprocess.run(
        ["git", "show", "-s", "--format=%cI", commit],
        cwd=project_root,
        check=True,
        capture_output=True,
        text=True,
    )
    value = result.stdout.strip()
    parsed = datetime.fromisoformat(value)
    return (
        parsed.astimezone(timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z")
    )


def main() -> None:
    if len(sys.argv) != 3:
        fail("usage: generate-release-sbom.py manifest output")

    manifest = Path(sys.argv[1]).resolve(strict=True)
    output = Path(sys.argv[2])
    if not output.is_absolute() or output.exists() or output.is_symlink():
        fail("output must be an absolute nonexistent path")
    if not output.parent.is_dir() or output.parent.is_symlink():
        fail("output parent must be an existing non-symlink directory")

    values = read_manifest(manifest)
    expected = {
        "schema": "IdleScreenR1ReleaseCandidate/v1",
        "verification_mode": "release",
        "source_clean": "true",
        "notary_status": "Accepted",
        "notary_issue_count": "0",
        "stapler_status": "valid",
        "dmg_gatekeeper_status": "accepted",
        "mounted_app_gatekeeper_status": "accepted",
    }
    for key, expected_value in expected.items():
        if required(values, key) != expected_value:
            fail(f"candidate manifest has invalid {key}")

    version = required(values, "bundle_short_version")
    build = required(values, "bundle_version")
    source_commit = required(values, "source_commit")
    dmg_relative = required(values, "dmg_relative_path")
    dmg_digest = required(values, "stapled_dmg_sha256")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        fail("candidate version is not stable semantic versioning")
    if not re.fullmatch(r"[1-9][0-9]*", build):
        fail("candidate build is malformed")
    if not re.fullmatch(r"[0-9a-f]{40}", source_commit):
        fail("candidate source commit is malformed")
    expected_relative = f"Distribution/idlescreen-{version}-build{build}.dmg"
    if dmg_relative != expected_relative:
        fail("candidate DMG path is not canonical")
    if not re.fullmatch(r"[0-9a-f]{64}", dmg_digest):
        fail("candidate DMG checksum is malformed")

    candidate_root = manifest.parent.resolve(strict=True)
    dmg_candidate = candidate_root / dmg_relative
    if dmg_candidate.is_symlink():
        fail("candidate DMG must not be a symlink")
    dmg = dmg_candidate.resolve(strict=True)
    if candidate_root not in dmg.parents or not dmg.is_file():
        fail("candidate DMG escapes its release directory")
    if sha256(dmg) != dmg_digest:
        fail("candidate DMG differs from its stapled checksum")

    project_root = Path(__file__).resolve().parent.parent
    created = commit_timestamp(project_root, source_commit)
    release_url = f"https://github.com/CodesWhat/idlescreen/releases/tag/v{version}"
    dmg_url = (
        f"https://github.com/CodesWhat/idlescreen/releases/download/v{version}/"
        f"idlescreen-{version}-build{build}.dmg"
    )
    namespace = (
        f"https://github.com/CodesWhat/idlescreen/releases/download/v{version}/"
        f"idlescreen-{version}-build{build}.spdx.json"
    )
    adapted_commit = "6be6c85b49e827320711289853726e68d3fbd7ea"
    document = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"idlescreen-{version}-build{build}",
        "documentNamespace": namespace,
        "creationInfo": {
            "created": created,
            "creators": ["Organization: CodesWhat", "Tool: idlescreen-release-sbom-v1"],
            "licenseListVersion": "3.27.0",
        },
        "documentDescribes": ["SPDXRef-Package-idlescreen"],
        "packages": [
            {
                "name": "idlescreen",
                "SPDXID": "SPDXRef-Package-idlescreen",
                "versionInfo": version,
                "packageFileName": f"idlescreen-{version}-build{build}.dmg",
                "supplier": "Organization: CodesWhat",
                "originator": "Organization: CodesWhat",
                "downloadLocation": dmg_url,
                "filesAnalyzed": False,
                "checksums": [{"algorithm": "SHA256", "checksumValue": dmg_digest}],
                "licenseConcluded": "MIT",
                "licenseDeclared": "MIT",
                "copyrightText": "Copyright (c) 2026 CodesWhat",
                "homepage": "https://github.com/CodesWhat/idlescreen",
                "sourceInfo": f"Built from {source_commit}; release record {release_url}",
                "externalRefs": [
                    {
                        "referenceCategory": "PACKAGE-MANAGER",
                        "referenceType": "purl",
                        "referenceLocator": f"pkg:generic/idlescreen@{version}",
                    }
                ],
            },
            {
                "name": "AppexSaverMinimal declarations",
                "SPDXID": "SPDXRef-Package-AppexSaverMinimal",
                "versionInfo": adapted_commit,
                "supplier": "Person: Guillaume Louel",
                "downloadLocation": (
                    "https://github.com/AerialScreensaver/AppexSaverMinimal/tree/"
                    f"{adapted_commit}"
                ),
                "filesAnalyzed": False,
                "licenseConcluded": "MIT",
                "licenseDeclared": "MIT",
                "copyrightText": "Copyright (c) 2026 Guillaume Louel",
            },
        ],
        "relationships": [
            {
                "spdxElementId": "SPDXRef-DOCUMENT",
                "relationshipType": "DESCRIBES",
                "relatedSpdxElement": "SPDXRef-Package-idlescreen",
            },
            {
                "spdxElementId": "SPDXRef-Package-idlescreen",
                "relationshipType": "CONTAINS",
                "relatedSpdxElement": "SPDXRef-Package-AppexSaverMinimal",
            },
        ],
    }

    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(output, flags, 0o644)
    with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
        handle.write(json.dumps(document, indent=2, sort_keys=True) + "\n")
    print(f"Generated SPDX SBOM: {output}")


if __name__ == "__main__":
    main()
