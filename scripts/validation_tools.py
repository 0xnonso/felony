"""Shared process capture and installed-tool version checks for local validation runners."""

import hashlib
from pathlib import Path
import subprocess
import time
import sys


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "model"))
from felony.toolchain import installed_tools


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def capture_logged(
    label,
    command,
    *,
    cwd,
    log_dir,
    records,
    env=None,
    timeout=900,
    merge_stderr=False,
    label_key="name",
    extra=None,
):
    """Record completed commands; callers decide which exit codes are acceptable."""
    start = time.monotonic()
    result = subprocess.run(
        list(map(str, command)),
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT if merge_stderr else subprocess.PIPE,
        timeout=timeout,
    )
    elapsed = time.monotonic() - start
    (log_dir / f"{label}.log").write_text(result.stdout + (result.stderr or ""))
    records.append(
        {label_key: label, "exit_code": result.returncode, "seconds": elapsed, **(extra or {})}
    )
    return result, elapsed
