#!/usr/bin/env python3
"""Check trained actor exports against Python, Noir intermediates and optional ZK proofs.

All generated witness keys here are public test keys. Never uses circuit/Prover.toml.
"""

import argparse
from dataclasses import asdict
import hashlib
import json
import os
from pathlib import Path
import shutil
import sys
import tempfile
import numpy as np
import torch

from validation_tools import capture_logged

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "model"))
from felony.actor import load_export
from felony.fixtures import legal_states, prover_toml
from felony.inference import Context, forward, infer, public_inputs


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--models", nargs="+", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--nargo", default="nargo")
    p.add_argument("--bb", help="When present, prove and verify one case per exported checkpoint")
    p.add_argument("--crs", type=Path)
    args = p.parse_args()
    if args.bb:
        os.environ["BARRETENBERG_BIN"] = str(Path(args.bb).resolve())
    torch.set_num_threads(1)
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    data = {"spec_version": 1, "models": {}, "cases": []}
    report = {"success": False, "models": [], "commands": []}

    def run(label, command, cwd=ROOT):
        print(label, flush=True)
        result, _ = capture_logged(
            label,
            command,
            cwd=cwd,
            log_dir=out,
            records=report["commands"],
            merge_stderr=True,
            label_key="label",
        )
        if result.returncode:
            raise RuntimeError(result.stdout[-2500:])

    try:
        for index, path in enumerate(args.models):
            actor = load_export(path)
            model = actor.export()
            name = f"model_{index}"
            data["models"][name] = {"w": list(model.w), "b": list(model.b)}
            states = legal_states(927461 + index)
            with torch.no_grad():
                x = torch.tensor([s.features() for s in states])
                _, trace = actor(x, x[:, :9] > 0)
            for i, state in enumerate(states):
                reference = forward(model, state)
                for field in ("z1", "h1", "z2", "h2", "z3", "raw_tickets", "tickets"):
                    if trace[field][i].tolist() != reference[field]:
                        raise ValueError(f"{path}: {field} parity failed")
            for r in (0, 3, 7):
                state = states[r]
                context = Context(31337, 0x12345, 1000 + index, index % 2, r, 9287361 + index)
                key, salt = 100 + index, 200 + index
                expected = infer(model, state, context, key, salt)
                data["cases"].append(
                    dict(
                        name=f"{name}_round{r}",
                        model=name,
                        state=str(state.pack()),
                        key=str(key),
                        salt=str(salt),
                        context={k: str(v) for k, v in asdict(context).items()},
                        expected={
                            k: [str(vv) for vv in v] if isinstance(v, list) else str(v)
                            for k, v in expected.items()
                        },
                        public_inputs=[str(v) for v in public_inputs(state, context, expected)],
                    )
                )
            report["models"].append(
                dict(
                    path=str(path.resolve()),
                    sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                    digest=str(model.digest),
                    reference_states=9,
                )
            )
        vector_path = out / "vectors.json"
        vector_path.write_text(json.dumps(data, separators=(",", ":")) + "\n")
        run(
            "intermediates",
            [
                sys.executable,
                ROOT / "scripts/check_intermediates.py",
                "--nargo",
                args.nargo,
                "--vectors",
                vector_path,
            ],
        )
        with tempfile.TemporaryDirectory(prefix="felony-trained-proof-") as directory:
            work = Path(directory)
            shutil.copyfile(ROOT / "circuit/Nargo.toml", work / "Nargo.toml")
            shutil.copytree(ROOT / "circuit/src", work / "src")
            run("compile", [args.nargo, "compile"], work)
            for i, case in enumerate(data["cases"]):
                name = f"case_{i}"
                (work / f"{name}.toml").write_text(prover_toml(data, case))
                run(f"execute_{name}", [args.nargo, "execute", "-p", name, name], work)
                if args.bb and i % 3 == 0:
                    dest = out / name
                    dest.mkdir()
                    crs = args.crs.resolve() if args.crs else out / "crs"
                    run(
                        f"prove_{name}",
                        [
                            args.bb,
                            "prove",
                            "-b",
                            work / "target/felony_circuit.json",
                            "-w",
                            work / f"target/{name}.gz",
                            "-o",
                            dest,
                            "-t",
                            "evm",
                            "--write_vk",
                            "-c",
                            crs,
                        ],
                        work,
                    )
                    run(
                        f"verify_{name}",
                        [
                            args.bb,
                            "verify",
                            "-p",
                            dest / "proof",
                            "-k",
                            dest / "vk",
                            "-i",
                            dest / "public_inputs",
                            "-t",
                            "evm",
                            "-c",
                            crs,
                        ],
                        work,
                    )
                    expected = b"".join(int(v).to_bytes(32, "big") for v in case["public_inputs"])
                    if (dest / "public_inputs").read_bytes() != expected:
                        raise ValueError("public input serialization mismatch")
        report["success"] = True
    finally:
        (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
