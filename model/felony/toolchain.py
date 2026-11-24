"""Discover installed native tools by version, independent of OS-specific binary hashes."""

import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
ENV = {
    "fe": "FE",
    "forge": "FORGE",
    "solc": "SOLC",
    "nargo": "NARGO",
    "barretenberg": "BARRETENBERG_BIN",
}
COMMAND = {name: "bb" if name == "barretenberg" else name for name in ENV}
PATTERN = {
    "fe": r"^fe ([^\s]+)",
    "forge": r"^forge Version: ([^\s]+)",
    "solc": r"^Version: ([^\s+]+)",
    "nargo": r"^nargo version = ([^\s]+)",
    "barretenberg": r"\A([^\s]+)\s*\Z",
}


def versions(root=ROOT):
    return json.loads((root / "toolchain.lock.json").read_text())["versions"]


def tool_version(name, path):
    try:
        result = subprocess.run(
            [str(path), "--version"], capture_output=True, text=True, timeout=10
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if result.returncode:
        return None
    match = re.search(PATTERN[name], result.stdout.strip(), re.M)
    if not match:
        return None
    version = match[1]
    # Forge's stable builds report e.g. 1.4.4-v1.4.4; nightly builds remain distinct.
    if name == "forge" and "-v" in version:
        first, tag = version.split("-v", 1)
        if first == tag:
            return first
    return version


def candidates(name, root=ROOT, upstream=None):
    command = COMMAND[name]
    required = versions(root)
    home = Path.home()
    # Search every PATH entry: an older executable may shadow the required version.
    paths = [Path(folder) / command for folder in os.get_exec_path()]
    standard = {
        "fe": [Path(os.environ.get("FE_HOME", home / ".fe")) / "bin/fe"],
        "forge": [Path(os.environ.get("FOUNDRY_DIR", home / ".foundry")) / "bin/forge"],
        "nargo": [Path(os.environ.get("NARGO_HOME", home / ".nargo")) / "bin/nargo"],
        "barretenberg": [
            home / f".local/share/felony/barretenberg/{required['barretenberg']}/bb",
            home / ".bb/bb",
        ],
        "solc": [
            Path(os.environ.get("SVM_HOME", home / ".svm"))
            / required["solc"]
            / f"solc-{required['solc']}"
        ],
    }
    paths += standard[name]
    config = root / ".tools/toolchain.json"
    if config.is_file():
        info = json.loads(config.read_text()).get("tools", {}).get(name)
        if info:
            paths.append(Path(info["path"]))
    # Reuse previous installations as well; never download an upstream binary bundle.
    upstream = upstream or root.parent / "barretenberg_fe"
    legacy = {
        "fe": "bin/fe",
        "forge": "foundry/forge",
        "solc": "bin/solc",
        "barretenberg": "barretenberg/bb",
    }
    if name in legacy:
        paths.append(upstream / ".tools" / legacy[name])
    if name == "nargo":
        paths.append(root / ".tools/noir/nargo")
    return list(dict.fromkeys(paths))


def find_tool(name, root=ROOT, upstream=None):
    expected = versions(root)[name]
    override = os.environ.get(ENV[name])
    if override:
        path = shutil.which(override)
        if not path or tool_version(name, path) != expected:
            raise RuntimeError(f"{ENV[name]} must select {name} {expected}: {override}")
        return Path(path).absolute()
    for path in candidates(name, root, upstream):
        if path.is_file() and os.access(path, os.X_OK) and tool_version(name, path) == expected:
            return path.absolute()
    return None


def installed_tools(names, upstream=None):
    result = {}
    for name in names:
        path = find_tool(name, upstream=upstream)
        if path is None:
            raise RuntimeError(f"Missing {name} {versions()[name]}; run make setup")
        result[name] = path
    return result
