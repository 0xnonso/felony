"""Dependency installation preserves local work and rejects untrusted downloads."""

from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from setup_toolchain import checkout, git, setup_native, install_tool


class SetupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name).resolve()
        self.source = self.root / "source"
        subprocess.run(["git", "init", "--quiet", str(self.source)], check=True)
        (self.source / "source.txt").write_text("original\n")
        (self.source / ".gitignore").write_text(".tools/\n")
        git(self.source, "add", ".")
        git(
            self.source,
            "-c",
            "user.name=Test",
            "-c",
            "user.email=test@example.invalid",
            "commit",
            "-qm",
            "fixture",
        )
        self.revision = git(self.source, "rev-parse", "HEAD")
        self.dest = self.root / "dependency"

    def test_fresh_checkout_and_repeat_with_ignored_tools(self):
        checkout(str(self.source), self.revision, self.dest)
        (self.dest / ".tools").mkdir()
        (self.dest / ".tools/cache").write_text("installed tools")
        checkout(str(self.source), self.revision, self.dest)
        self.assertEqual(git(self.dest, "rev-parse", "HEAD"), self.revision)

    def test_empty_uninitialized_submodule_can_be_installed(self):
        self.dest.mkdir()
        checkout(str(self.source), self.revision, self.dest)
        self.assertEqual((self.dest / "source.txt").read_text(), "original\n")

    def test_existing_edits_and_wrong_revision_are_preserved(self):
        checkout(str(self.source), self.revision, self.dest)
        (self.dest / "source.txt").write_text("local edit\n")
        with self.assertRaisesRegex(RuntimeError, "local changes"):
            checkout(str(self.source), self.revision, self.dest)
        with self.assertRaisesRegex(RuntimeError, "must be at"):
            checkout(str(self.source), "0" * 40, self.dest)
        self.assertEqual((self.dest / "source.txt").read_text(), "local edit\n")
        self.assertEqual(git(self.dest, "rev-parse", "HEAD"), self.revision)

    def test_failed_fetch_does_not_leave_installation(self):
        with self.assertRaises(subprocess.CalledProcessError):
            checkout(str(self.source), "0" * 40, self.dest)
        self.assertFalse(self.dest.exists())

    def test_all_installed_tools_are_reused_without_installing(self):
        selected = {
            name: Path("/installed") / name
            for name in ("fe", "barretenberg", "nargo", "forge", "solc")
        }
        with (
            patch("setup_toolchain.find_tool", side_effect=lambda name, **kw: selected[name]),
            patch("setup_toolchain.install_tool") as install,
            patch("setup_toolchain.tool_version", return_value="test"),
        ):
            self.assertEqual(setup_native(self.dest), selected)
            install.assert_not_called()

    def test_missing_tool_is_installed_then_rechecked(self):
        calls = []

        def find(name, **kw):
            return None if name == "fe" and not calls else Path("/installed") / name

        with (
            patch("setup_toolchain.find_tool", side_effect=find),
            patch(
                "setup_toolchain.install_tool",
                side_effect=lambda name, selected: calls.append(name),
            ),
            patch("setup_toolchain.tool_version", return_value="test"),
        ):
            self.assertEqual(setup_native(self.dest)["fe"], Path("/installed/fe"))
        self.assertEqual(calls, ["fe"])

    def test_failed_installer_does_not_continue_or_record_success(self):
        with (
            patch("setup_toolchain.find_tool", return_value=None),
            patch(
                "setup_toolchain.install_tool",
                side_effect=subprocess.CalledProcessError(1, "installer"),
            ),
            self.assertRaises(subprocess.CalledProcessError),
        ):
            setup_native(self.dest)

    def test_bb_installer_isolated_from_ide_and_solc_uses_foundry(self):
        with patch("setup_toolchain.installer") as run:
            install_tool("barretenberg", {})
            args, kwargs = run.call_args
            self.assertIn("bbup/bbup", args[0])
            self.assertEqual(args[1:], ("--version", "6.0.0", "--no-modify-path"))
            self.assertIn("/.local/share/felony/barretenberg/6.0.0", kwargs["env"]["BB_PATH"])
        with patch("setup_toolchain.subprocess.run") as run:
            install_tool("solc", {"forge": Path("/installed/forge")})
            self.assertEqual(run.call_args.args[0][:2], ["/installed/forge", "build"])
            self.assertEqual(run.call_args.args[0][-2:], ["--use", "0.8.30"])


class BootstrapTests(unittest.TestCase):
    def test_existing_prerequisites_and_python_are_reused(self):
        self.run_bootstrap(python_missing=False)

    def test_missing_python_is_installed_before_native_setup(self):
        self.run_bootstrap(python_missing=True)

    def test_make_is_required_without_attempting_installation(self):
        self.run_bootstrap(python_missing=True, make_missing=True)

    def run_bootstrap(self, python_missing, make_missing=False):
        import os
        import shlex
        import shutil

        source = Path(__file__).resolve().parents[1] / "scripts/setup.sh"
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "scripts").mkdir()
            shutil.copy2(source, root / "scripts/setup.sh")
            commands = root / "bin"
            commands.mkdir()
            log = root / "commands.log"
            marker = root / "python-installed"

            def stub(name, body):
                path = commands / name
                path.write_text("#!/bin/bash\n" + body + "\n")
                path.chmod(0o755)
                return path

            for name in ("bash", "dirname", "mkdir"):
                (commands / name).symlink_to(shutil.which(name))
            stub("uname", "echo Linux")
            for name in ("git", "make", "curl"):
                if name == "make" and make_missing:
                    continue
                stub(name, '[[ "$1" == --version ]] || exit 97')
            python = stub("python", f'echo "python $*" >> {shlex.quote(str(log))}')
            if not python_missing:
                marker.write_text("")
            stub(
                "uv",
                f"""echo "uv $*" >> {shlex.quote(str(log))}
if [[ "$1 $2" == "python find" ]]; then
  [[ "$3" == ">=3.12" ]] || exit 98
  [[ -f {shlex.quote(str(marker))} ]] || exit 1
  echo {shlex.quote(str(python))}
elif [[ "$1 $2" == "python install" ]]; then
  echo installed > {shlex.quote(str(marker))}
fi""",
            )
            result = subprocess.run(
                [
                    shutil.which("make"),
                    "-f",
                    str(source.parents[1] / "Makefile"),
                    "setup",
                    f"BARRETENBERG_FE={root / 'generator'}",
                ],
                cwd=root,
                env={**os.environ, "PATH": str(commands)},
                text=True,
                capture_output=True,
            )
            if make_missing:
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Make is required", result.stderr)
                self.assertFalse(log.exists())
                return
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            lines = log.read_text()
            self.assertIn("uv python find >=3.12 --no-python-downloads", lines)
            self.assertEqual("uv python install 3.12" in lines, python_missing)
            stages = [
                "python scripts/setup_toolchain.py --forge-std-only",
                f"uv sync --locked --python {python}",
                f"python scripts/setup_toolchain.py --barretenberg-fe {root / 'generator'}",
            ]
            positions = [lines.index(stage) for stage in stages]
            self.assertEqual(positions, sorted(positions))


if __name__ == "__main__":
    unittest.main()
