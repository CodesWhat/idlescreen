#!/usr/bin/env python3

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("xccov_to_lcov.py")


class CoverageExportTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.output = self.root / "coverage.lcov"

    def export(self, *reports):
        inputs = []
        for index, report in enumerate(reports):
            path = self.root / f"report-{index}.json"
            path.write_text(json.dumps(report))
            inputs.append(str(path))
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--source-root", str(self.root),
             "--output", str(self.output), *inputs],
            capture_output=True, text=True,
        )

    def test_exports_real_line_counts_and_keeps_uncovered_lines(self):
        result = self.export({str(self.root / "Sources/Agent.swift"): [
            {"line": 1, "isExecutable": False},
            {"line": 2, "isExecutable": True, "executionCount": 7},
            {"line": 3, "isExecutable": True, "executionCount": 0},
        ]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text(),
                         "SF:Sources/Agent.swift\nDA:2,7\nDA:3,0\nLF:2\nLH:1\nend_of_record\n")

    def test_merges_schemes_by_line_without_inflating_counts(self):
        path = str(self.root / "Products/App/main.swift")
        result = self.export(
            {path: [{"line": 4, "isExecutable": True, "executionCount": 0},
                    {"line": 5, "isExecutable": True, "executionCount": 3}]},
            {path: [{"line": 4, "isExecutable": True, "executionCount": 2},
                    {"line": 5, "isExecutable": True, "executionCount": 1}]},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("DA:4,2\nDA:5,3\nLF:2\nLH:2", self.output.read_text())

    def test_excludes_tests_support_generated_builds_and_external_paths(self):
        records = [{"line": 1, "isExecutable": True, "executionCount": 1}]
        result = self.export({str(self.root / path): records for path in [
            "Sources/Agent.swift", "Tests/AgentTests.swift", "Support/Probe.swift",
            "DerivedData/Generated.swift", "../elsewhere/Sources/Foreign.swift",
        ]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.output.read_text().count("SF:"), 1)
        self.assertIn("SF:Sources/Agent.swift", self.output.read_text())

    def test_all_uncovered_executable_lines_are_valid_measurements(self):
        result = self.export({str(self.root / "Sources/Agent.swift"): [
            {"line": 3, "isExecutable": True, "executionCount": 0},
        ]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("LF:1\nLH:0", self.output.read_text())

    def test_empty_or_unsupported_archives_fail_without_replacing_output(self):
        for report in [{}, [], {"targets": []},
                       {str(self.root / "Tests/AgentTests.swift"): []}]:
            with self.subTest(report=report):
                self.output.write_text("previous report")
                result = self.export(report)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.output.read_text(), "previous report")

    def test_rejects_malformed_line_records(self):
        for record in [
            {"line": 0, "isExecutable": True, "executionCount": 1},
            {"line": True, "isExecutable": True, "executionCount": 1},
            {"line": 1, "isExecutable": "true", "executionCount": 1},
            {"line": 1, "isExecutable": True},
            {"line": 1, "isExecutable": True, "executionCount": -1},
            {"line": 1, "isExecutable": True, "executionCount": False},
        ]:
            with self.subTest(record=record):
                result = self.export({str(self.root / "Sources/Agent.swift"): [record]})
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(self.output.exists())

    def test_each_input_must_contain_production_measurements(self):
        path = str(self.root / "Sources/Agent.swift")
        result = self.export({path: [{"line": 2, "isExecutable": True,
                                     "executionCount": 1}]}, {})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())

    def test_invalid_json_fails_without_creating_output(self):
        report = self.root / "broken.json"
        report.write_text("{")
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--source-root", str(self.root),
             "--output", str(self.output), str(report)],
            capture_output=True, text=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
