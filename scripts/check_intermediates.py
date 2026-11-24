#!/usr/bin/env python3
"""Compare Noir intermediates with Python vectors, then reject corrupted expected values.

Uses temporary witnesses. This checks execution, not proof generation or model quality.
See docs/INFERENCE.md for the protocol rules.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "model"))
from felony.poseidon2 import FIELD_MODULUS  # noqa: E402

TEMPLATE = Path(__file__).with_name("check_intermediates_main.nr")
COMMAND_TIMEOUT_SECONDS = 300
PUBLIC_PARAMETER_COUNT = 9
SOLVED_TEXT = "Circuit witness successfully solved"
ANSI_ESCAPE = re.compile(r"\x1b\[[0-9;]*m")


FIELD_ARRAYS = {
    "features": ("expected_features", "features"),
    "z1": ("expected_z1", "z1"),
    "h1": ("expected_h1", "h1"),
    "z2": ("expected_z2", "z2"),
    "h2": ("expected_h2", "h2"),
    "z3": ("expected_z3", "z3"),
}
INTEGER_ARRAYS = {
    "raw_tickets": ("expected_raw_tickets", "raw_tickets"),
    "tickets": ("expected_tickets", "tickets"),
}
SCALARS = {
    "total": ("expected_total", "total"),
    "model_digest": ("expected_model_digest", "model_digest"),
    "commitment": ("expected_commitment", "commitment"),
    "sample_hash": ("expected_sample_hash", "sample_hash"),
    "random_u64": ("expected_random_u64", "random_u64"),
    "ticket": ("expected_ticket", "ticket"),
    "action": ("expected_action", "action"),
}
ALL_COMPARED = {**FIELD_ARRAYS, **INTEGER_ARRAYS, **SCALARS}


def field_string(value):
    return str(int(value) % FIELD_MODULUS)


def replace_exactly(text, old, new, count):
    found = text.count(old)
    if found != count:
        raise RuntimeError(f"expected {count} of {old!r} in circuit/src/main.nr, found {found}")
    return text.replace(old, new)


def build_package(work):
    shutil.copyfile(ROOT / "circuit/Nargo.toml", work / "Nargo.toml")
    shutil.copytree(ROOT / "circuit/src", work / "src")
    (work / "src/tests.nr").unlink()
    path = work / "src/main.nr"
    source = path.read_text()
    source = replace_exactly(source, "mod tests;\n", "", 1)
    source = replace_exactly(source, "fn main(", "pub fn circuit_main(", 1)
    source = replace_exactly(source, ": pub ", ": ", PUBLIC_PARAMETER_COUNT)
    path.write_text(source + TEMPLATE.read_text())


def witness_inputs(data, case):
    model = data["models"][case["model"]]
    expected = case["expected"]
    inputs = {
        "w": [str(x) for x in model["w"]],
        "b": [str(x) for x in model["b"]],
        "key": case["key"],
        "salt": case["salt"],
        "public_inputs": [field_string(x) for x in case["public_inputs"]],
    }
    for key, (parameter, _) in FIELD_ARRAYS.items():
        inputs[parameter] = [field_string(x) for x in expected[key]]
    for key, (parameter, _) in INTEGER_ARRAYS.items():
        inputs[parameter] = list(expected[key])
    for key, (parameter, _) in SCALARS.items():
        inputs[parameter] = expected[key]
    return inputs


def corrupted(inputs, key):
    parameter = ALL_COMPARED[key][0]
    changed = dict(inputs)
    if key in FIELD_ARRAYS:
        values = list(inputs[parameter])
        values[0] = str((int(values[0]) + 1) % FIELD_MODULUS)
        changed[parameter] = values
    elif key in INTEGER_ARRAYS:
        values = list(inputs[parameter])
        values[0] = str(int(values[0]) + 1)
        changed[parameter] = values
    elif key == "action":
        changed[parameter] = str((int(inputs[parameter]) + 1) % 9)
    elif key == "random_u64":
        changed[parameter] = str((int(inputs[parameter]) + 1) % (1 << 64))
    elif key in ("total", "ticket"):
        changed[parameter] = str(int(inputs[parameter]) + 1)
    else:
        changed[parameter] = str((int(inputs[parameter]) + 1) % FIELD_MODULUS)
    return changed


def write_inputs(work, name, inputs):
    lines = (f"{key} = {json.dumps(value)}" for key, value in inputs.items())
    (work / f"{name}.toml").write_text("\n".join(lines) + "\n")


def run(command, cwd):
    env = {**os.environ, "NO_COLOR": "1"}
    result = subprocess.run(
        command,
        cwd=cwd,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=COMMAND_TIMEOUT_SECONDS,
    )
    return result.returncode, ANSI_ESCAPE.sub("", result.stdout)


def main():
    parser = argparse.ArgumentParser(
        description=(__doc__ or "Compare circuit intermediates").splitlines()[0]
    )
    parser.add_argument("--nargo", default="nargo")
    parser.add_argument("--vectors", type=Path, default=ROOT / "test_vectors/inference.json")
    args = parser.parse_args()

    data = json.loads(args.vectors.read_text())
    if data.get("spec_version") != 1 or not data.get("cases"):
        raise SystemExit("unexpected vector file: need spec_version 1 and at least one case")

    code, output = run([args.nargo, "--version"], ROOT)
    print(f"nargo --version: exit {code}")
    if code != 0 or not output.startswith("nargo version = 1.0.0\n"):
        raise SystemExit(f"Nargo 1.0.0 is required:\n{output}")

    failures = []
    with tempfile.TemporaryDirectory(prefix="felony-intermediates-") as directory:
        work = Path(directory)
        build_package(work)

        code, output = run([args.nargo, "compile"], work)
        print(f"nargo compile: exit {code}")
        if code != 0:
            raise SystemExit(f"harness failed to compile:\n{output[-3000:]}")

        for index, case in enumerate(data["cases"]):
            name = f"case_{index}"
            write_inputs(work, name, witness_inputs(data, case))
            code, output = run([args.nargo, "execute", "-p", name, name], work)
            passed = code == 0 and SOLVED_TEXT in output
            print(f"match {case['name']}: exit {code}, {'ok' if passed else 'FAILED'}")
            if not passed:
                failures.append(f"{case['name']}: {output[-1500:]}")

        reference = witness_inputs(data, data["cases"][0])
        for key, (_, label) in ALL_COMPARED.items():
            name = f"wrong_{key}"
            write_inputs(work, name, corrupted(reference, key))
            code, output = run([args.nargo, "execute", "-p", name, name], work)
            own_assertion = re.search(
                rf"Assertion failed: {re.escape(label)}\s*$", output, re.MULTILINE
            )
            passed = code != 0 and own_assertion is not None
            print(f"reject wrong {key}: exit {code}, {'ok' if passed else 'FAILED'}")
            if not passed:
                failures.append(f"wrong {key}: {output[-1500:]}")

    checks = len(data["cases"]) + len(ALL_COMPARED)
    if failures:
        print(f"{len(failures)} of {checks} checks failed", file=sys.stderr)
        for failure in failures:
            print(failure, file=sys.stderr)
        raise SystemExit(1)
    print(
        f"All {len(data['cases'])} cases matched; all {len(ALL_COMPARED)} corrupted values were rejected"
    )


if __name__ == "__main__":
    main()
