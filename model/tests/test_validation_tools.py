import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location(
    "validation_tools", Path(__file__).resolve().parents[2] / "scripts/validation_tools.py"
)
assert spec is not None and spec.loader is not None
tools = importlib.util.module_from_spec(spec)
spec.loader.exec_module(tools)


class ValidationToolsTests(unittest.TestCase):
    def test_capture_preserves_streams_environment_directory_and_nonzero_status(self):
        with tempfile.TemporaryDirectory() as directory:
            root, records = Path(directory), []
            code = "import os,sys; print(os.environ['CASE']); print(os.getcwd()); print('err',file=sys.stderr); sys.exit(7)"
            with mock.patch.object(tools.time, "monotonic", side_effect=[10.0, 10.25]):
                result, elapsed = tools.capture_logged(
                    "rejected",
                    [sys.executable, "-c", code],
                    cwd=root,
                    log_dir=root,
                    records=records,
                    env={"CASE": "public fixture"},
                    extra={"expected_rejection": True},
                )
            self.assertEqual(elapsed, 0.25)
            self.assertEqual(result.returncode, 7)
            self.assertEqual(result.stdout.splitlines(), ["public fixture", str(root.resolve())])
            self.assertEqual(result.stderr, "err\n")
            self.assertEqual((root / "rejected.log").read_text(), result.stdout + result.stderr)
            self.assertEqual(
                records,
                [
                    {
                        "name": "rejected",
                        "exit_code": 7,
                        "seconds": 0.25,
                        "expected_rejection": True,
                    }
                ],
            )

    def test_merged_streams_and_export_report_label(self):
        with tempfile.TemporaryDirectory() as directory:
            root, records = Path(directory), []
            result, _ = tools.capture_logged(
                "export",
                [sys.executable, "-c", "import os; os.write(1,b'out'); os.write(2,b'err')"],
                cwd=root,
                log_dir=root,
                records=records,
                merge_stderr=True,
                label_key="label",
            )
            self.assertEqual((result.returncode, result.stdout, result.stderr), (0, "outerr", None))
            self.assertEqual((root / "export.log").read_text(), "outerr")
            self.assertEqual(set(records[0]), {"label", "exit_code", "seconds"})

    def test_timeout_is_not_reported_as_completed_or_expected_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            root, records = Path(directory), []
            with (
                mock.patch.object(
                    tools.subprocess,
                    "run",
                    side_effect=subprocess.TimeoutExpired("public-command", 0.02),
                ),
                self.assertRaises(subprocess.TimeoutExpired),
            ):
                tools.capture_logged(
                    "timeout",
                    ["public-command"],
                    cwd=root,
                    log_dir=root,
                    records=records,
                    timeout=0.02,
                )
            self.assertEqual(records, [])
            self.assertFalse((root / "timeout.log").exists())
