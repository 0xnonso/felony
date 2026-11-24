#!/usr/bin/env python3
"""Format maintained source, or check it without writing files."""

import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
from validation_tools import installed_tools


def run(command, cwd=ROOT):
    print("+ " + " ".join(map(str, command)), flush=True)
    subprocess.run(command, cwd=cwd, check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    check = ["--check"] if args.check else []
    tools = installed_tools(("fe", "forge", "nargo"))
    fe, forge, nargo = (tools[name] for name in ("fe", "forge", "nargo"))
    run([sys.executable, "-m", "ruff", "format", *check, "."])
    for directory in ("contracts/src", "tests/fixtures"):
        run([fe, "fmt", *check, directory])
    run([nargo, "fmt", *check], ROOT / "circuit")

    fixture = ROOT / "scripts/check_intermediates_main.nr"
    with tempfile.TemporaryDirectory(prefix="felony-format-") as temporary:
        package = Path(temporary)
        (package / "src").mkdir()
        (package / "Nargo.toml").write_text(
            '[package]\nname = "format_fixture"\ntype = "bin"\nauthors = []\n'
        )
        target = package / "src/main.nr"
        shutil.copyfile(fixture, target)
        run([nargo, "fmt", *check], package)
        if not args.check:
            shutil.copyfile(target, fixture)
    run([forge, "fmt", *check, "tests"])


if __name__ == "__main__":
    main()
