"""Tool discovery rejects wrong versions while accepting different host builds."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

from felony import toolchain


class ToolchainTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        (self.root / "toolchain.lock.json").write_text(
            json.dumps({"versions": toolchain.versions()})
        )

    def binary(self, name, output):
        path = self.root / name
        path.write_text('#!/bin/sh\nprintf "%s\\n" ' + repr(output) + "\n")
        path.chmod(0o755)
        return path

    def test_reuses_matching_path_after_shadowed_old_version(self):
        old = self.binary("old-fe", "fe 0.26.0")
        current = self.binary("current-fe", "fe 26.6.0 (linux-build)")
        with (
            patch.dict(os.environ, {}, clear=True),
            patch.object(toolchain, "candidates", return_value=[old, current]),
        ):
            self.assertEqual(toolchain.find_tool("fe", self.root), current)

    def test_explicit_wrong_version_fails_without_falling_back(self):
        old = self.binary("old-fe", "fe 0.26.0")
        with (
            patch.dict(os.environ, {"FE": str(old)}, clear=True),
            self.assertRaisesRegex(RuntimeError, "FE must select fe 26.6.0"),
        ):
            toolchain.find_tool("fe", self.root)

    def test_bb_ide_is_not_selected_as_barretenberg(self):
        ide = self.binary("bb-ide", "bb 6.0.0")
        prover = self.binary("bb-prover", "6.0.0")
        with (
            patch.dict(os.environ, {}, clear=True),
            patch.object(toolchain, "candidates", return_value=[ide, prover]),
        ):
            self.assertEqual(toolchain.find_tool("barretenberg", self.root), prover)

    def test_release_candidates_nightlies_and_version_prefixes_are_rejected(self):
        for name, text in [
            ("nargo", "nargo version = 1.0.0-rc.3"),
            ("forge", "forge Version: 1.4.4-nightly"),
            ("fe", "fe 26.6.01"),
        ]:
            path = self.binary(name, text)
            with (
                patch.dict(os.environ, {}, clear=True),
                patch.object(toolchain, "candidates", return_value=[path]),
            ):
                self.assertIsNone(toolchain.find_tool(name, self.root))

    def test_forge_stable_suffix_and_solc_build_metadata(self):
        self.assertEqual(
            toolchain.tool_version("forge", self.binary("forge", "forge Version: 1.4.4-v1.4.4")),
            "1.4.4",
        )
        self.assertEqual(
            toolchain.tool_version(
                "solc", self.binary("solc", "Version: 0.8.30+commit.73712a01.Linux.g++")
            ),
            "0.8.30",
        )

    def test_unexecutable_or_timed_out_tool_is_not_accepted(self):
        path = self.binary("fe", "fe 26.6.0")
        path.chmod(0o644)
        self.assertIsNone(toolchain.tool_version("fe", path))
        with patch.object(
            toolchain.subprocess, "run", side_effect=subprocess.TimeoutExpired("fe", 10)
        ):
            self.assertIsNone(toolchain.tool_version("fe", path))
