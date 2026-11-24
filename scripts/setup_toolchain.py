#!/usr/bin/env python3
"""Install Felony's pinned public dependencies without replacing existing checkouts."""

import argparse
import hashlib
import json
from pathlib import Path
import os
import sys
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "model"))
from felony.toolchain import ENV, find_tool, tool_version, versions


def git(path, *args):
    return subprocess.check_output(["git", "-C", str(path), *args], text=True).strip()


def checkout(url, revision, path):
    path = path.resolve()
    # Git leaves empty submodule directories in clones made without --recurse-submodules.
    if path.is_dir() and not any(path.iterdir()):
        path.rmdir()
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        # A failed fetch never leaves a half-installed dependency at the final path.
        with tempfile.TemporaryDirectory(prefix="felony-dependency-", dir=path.parent) as tmp:
            staged = Path(tmp) / "checkout"
            subprocess.run(["git", "init", "--quiet", str(staged)], check=True)
            subprocess.run(["git", "-C", str(staged), "remote", "add", "origin", url], check=True)
            subprocess.run(
                ["git", "-C", str(staged), "fetch", "--depth", "1", "origin", revision], check=True
            )
            subprocess.run(
                ["git", "-C", str(staged), "checkout", "--quiet", "--detach", revision], check=True
            )
            staged.rename(path)
    if git(path, "rev-parse", "--show-toplevel") != str(path):
        raise RuntimeError(f"{path} is not a dependency checkout")
    if git(path, "rev-parse", "HEAD") != revision:
        raise RuntimeError(f"{path} must be at {revision}; existing checkout left unchanged")
    if git(path, "status", "--porcelain", "--untracked-files=normal"):
        raise RuntimeError(f"{path} has local changes; existing checkout left unchanged")


def installer(url, *args, env=None):
    """Run the official installer, which selects assets for the host platform."""
    print(f"Installer: {url} {' '.join(args)}", flush=True)
    with tempfile.TemporaryDirectory(prefix="felony-installer-") as tmp:
        script = Path(tmp) / "install.sh"
        subprocess.run(
            ["curl", "--fail", "--location", "--retry", "3", url, "--output", str(script)],
            check=True,
        )
        subprocess.run(["bash", str(script), *args], env=env, check=True)


def install_tool(name, selected):
    home = Path.home()
    version = versions()[name]
    if name == "fe":
        installer(
            "https://raw.githubusercontent.com/argotorg/fe/master/feup/feup.sh",
            "--version",
            f"v{version}",
            "--no-modify-path",
        )
    elif name == "barretenberg":
        # BB IDE also owns a `bb` command. bbup supports a separate destination.
        installer(
            "https://raw.githubusercontent.com/AztecProtocol/aztec-packages/refs/heads/next/barretenberg/bbup/bbup",
            "--version",
            version,
            "--no-modify-path",
            env={
                **os.environ,
                "BB_PATH": str(home / f".local/share/felony/barretenberg/{version}"),
            },
        )
    elif name == "nargo":
        updater = Path(os.environ.get("NARGO_HOME", home / ".nargo")) / "bin/noirup"
        if not updater.is_file():
            installer("https://raw.githubusercontent.com/noir-lang/noirup/refs/heads/main/install")
        subprocess.run([str(updater), "--version", version], check=True)
    elif name == "forge":
        updater = Path(os.environ.get("FOUNDRY_DIR", home / ".foundry")) / "bin/foundryup"
        if not updater.is_file():
            installer("https://foundry.paradigm.xyz")
        subprocess.run([str(updater), "--install", f"v{version}"], check=True)
    elif name == "solc":
        # Forge manages native Solc versions through SVM; solcjs is not compatible.
        with tempfile.TemporaryDirectory(prefix="felony-solc-") as tmp:
            project = Path(tmp)
            (project / "src").mkdir()
            (project / "foundry.toml").write_text('[profile.default]\nsrc="src"\n')
            (project / "src/CompilerCheck.sol").write_text(
                f"// SPDX-License-Identifier: MIT\npragma solidity {version};\ncontract CompilerCheck {{}}\n"
            )
            subprocess.run(
                [str(selected["forge"]), "build", "--root", tmp, "--use", version], check=True
            )
    else:
        raise ValueError(name)


def setup_native(upstream):
    selected = {}
    for name in ("fe", "barretenberg", "nargo", "forge", "solc"):
        path = find_tool(name, upstream=upstream)
        if path is None:
            install_tool(name, selected)
            path = find_tool(name, upstream=upstream)
        if path is None:
            raise RuntimeError(
                f"Installer did not provide {name} {versions()[name]}; set {ENV[name]} to its executable"
            )
        selected[name] = path
        print(f"Using {name} {tool_version(name, path)}: {path}", flush=True)
    return selected


def save_selection(selected):
    info = {
        name: {
            "path": str(path),
            "version": tool_version(name, path),
            "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        }
        for name, path in selected.items()
    }
    tools_dir = ROOT / ".tools"
    tools_dir.mkdir(exist_ok=True)
    # Machine-local paths/hashes record what ran, rather than imposing one OS's hashes.
    (tools_dir / "toolchain.json").write_text(json.dumps({"tools": info}, indent=2) + "\n")

    def escape(value):
        return value.replace("$", "$$").replace("#", "\\#")

    (tools_dir / "toolchain.mk").write_text(
        "".join(f"{ENV[name]} ?= {escape(str(path))}\n" for name, path in selected.items())
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--forge-std-only", action="store_true")
    parser.add_argument("--barretenberg-fe", type=Path, default=ROOT.parent / "barretenberg_fe")
    args = parser.parse_args()
    if args.forge_std_only:
        revision = json.loads((ROOT / "foundry.lock").read_text())["lib/forge-std"]["tag"]["rev"]
        checkout("https://github.com/foundry-rs/forge-std.git", revision, ROOT / "lib/forge-std")
        return
    lock = json.loads((ROOT / "toolchain.lock.json").read_text())
    upstream = args.barretenberg_fe.resolve()
    checkout(lock["barretenberg_fe"]["url"], lock["barretenberg_fe"]["revision"], upstream)
    save_selection(setup_native(upstream))
    print(
        "Toolchain ready. Existing matching versions were reused; missing versions use official installers."
    )


if __name__ == "__main__":
    main()
