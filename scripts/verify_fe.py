#!/usr/bin/env python3
"""Generate and execute a barretenberg_fe verifier for the current Noir circuit.

Uses only explicit public test witnesses in an isolated package. Never reads the
player's circuit/Prover.toml. Local EVM execution, not deployment to a network.
"""

import argparse
from dataclasses import asdict
import json
import os
from pathlib import Path
import re
import shutil
import sys

from validation_tools import capture_logged, installed_tools, sha256 as sha

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "model"))
from felony.fixtures import legal_states, prover_toml
from felony.inference import Context, Model, PUBLIC_INPUT_NAMES, infer, public_inputs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--barretenberg-fe", type=Path, default=ROOT.parent / "barretenberg_fe")
    parser.add_argument("--nargo", default=None)
    parser.add_argument(
        "--output", type=Path, default=ROOT / "contracts/target/verifier_validation"
    )
    parser.add_argument(
        "--trained-model", type=Path, help="Optional exported model; uses public dummy key/salt"
    )
    parser.add_argument(
        "--publish",
        action="store_true",
        help="After tests pass, save contracts/generated/UltraHonkVerifier.fe",
    )
    args = parser.parse_args()
    args.nargo = args.nargo or str(installed_tools(("nargo",))["nargo"])
    upstream = args.barretenberg_fe.resolve()
    binaries = installed_tools(("barretenberg", "fe", "forge", "solc"), upstream)
    os.environ["BARRETENBERG_BIN"] = str(binaries["barretenberg"])
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    logs = out / "logs"
    logs.mkdir()
    work = out / "noir"
    work.mkdir()
    evm = out / "evm"
    evm.mkdir()
    artifacts = evm / "artifacts"
    artifacts.mkdir()
    report = {
        "success": False,
        "evm_version": "osaka",
        "scope": "local EVM Fe/Solidity differential verification; no game contract integration",
        "commands": [],
        "cases": [],
        "toolchain_lock_sha256": sha(ROOT / "toolchain.lock.json"),
        "tool_sha256": {name: sha(path) for name, path in binaries.items()},
        "sources": {},
        "upstream_sources": {},
        "public_inputs": list(PUBLIC_INPUT_NAMES),
    }
    files = [
        ROOT / "circuit/Nargo.toml",
        ROOT / "scripts/verify_fe.py",
        ROOT / "scripts/validation_tools.py",
        ROOT / "tests/evm/FelonyVerifier.t.sol",
        ROOT / "foundry.lock",
        *sorted((ROOT / "lib/forge-std/src").rglob("*.sol")),
        ROOT / "test_vectors/inference.json",
        *sorted((ROOT / "circuit/src").glob("*.nr")),
    ]
    report["sources"] = {str(p.relative_to(ROOT)): sha(p) for p in files}
    upstream_files = [
        upstream / "scripts/generate.py",
        upstream / "templates/circuit.fe.in",
        *sorted((upstream / "src").rglob("*.fe")),
    ]
    report["upstream_sources"] = {str(p.relative_to(upstream)): sha(p) for p in upstream_files}
    env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1", "HARDWARE_CONCURRENCY": "8"}

    def run(label, command, cwd=out):
        print(label, flush=True)
        result, _ = capture_logged(
            label, command, cwd=cwd, env=env, log_dir=logs, records=report["commands"]
        )
        text = result.stdout + result.stderr
        if result.returncode:
            raise RuntimeError(f"{label} failed:\n{text[-5000:]}")
        return text

    try:
        report["nargo_version"] = run("nargo_version", [args.nargo, "--version"]).strip()
        if not report["nargo_version"].startswith("nargo version = 1.0.0\n"):
            raise RuntimeError(
                "Expected the circuit-pinned Nargo 1.0.0, not the upstream fixture compiler"
            )
        for name, binary in binaries.items():
            report[f"{name}_version"] = run(f"{name}_version", [binary, "--version"]).strip()
        shutil.copy2(ROOT / "circuit/Nargo.toml", work / "Nargo.toml")
        shutil.copytree(ROOT / "circuit/src", work / "src")
        run("compile_noir", [args.nargo, "compile"], work)
        compiled = work / "target/felony_circuit.json"
        document = json.loads(compiled.read_text())
        names = [p["name"] for p in document["abi"]["parameters"] if p["visibility"] == "public"]
        if names != list(PUBLIC_INPUT_NAMES):
            raise RuntimeError(f"Unexpected circuit public ABI: {names}")
        report["circuit_artifact_sha256"] = sha(compiled)
        data = json.loads((ROOT / "test_vectors/inference.json").read_text())
        cases = [data["cases"][i] for i in (0, 2, 9, 12)]
        if args.trained_model:
            export = json.loads(args.trained_model.read_text())
            if export["spec_version"] != 1 or export["architecture"] != [55, 128, 128, 9]:
                raise ValueError("Unsupported model format")
            model = Model(export["w"], export["b"])
            state = legal_states(727451)[3]
            context = Context(31337, 0x12345, 5555, 1, 3, 928731)
            trace = infer(model, state, context, 501, 502)
            data["models"]["trained"] = {"w": list(model.w), "b": list(model.b)}
            cases.append(
                {
                    "name": "trained_round3",
                    "model": "trained",
                    "state": str(state.pack()),
                    "context": {k: str(v) for k, v in asdict(context).items()},
                    "key": "501",
                    "salt": "502",
                    "expected": {
                        k: [str(x) for x in v] if isinstance(v, list) else str(v)
                        for k, v in trace.items()
                    },
                    "public_inputs": [str(v) for v in public_inputs(state, context, trace)],
                }
            )
            report["trained_model"] = {
                "path": str(args.trained_model.resolve()),
                "sha256": sha(args.trained_model),
            }
        bb = binaries["barretenberg"]
        crs = upstream / ".tools/crs"
        for i, case in enumerate(cases):
            name = f"case_{i}"
            dest = artifacts / name
            dest.mkdir()
            (work / f"{name}.toml").write_text(prover_toml(data, case))
            run(f"execute_{name}", [args.nargo, "execute", "-p", name, name], work)
            run(
                f"prove_{name}",
                [
                    bb,
                    "prove",
                    "-b",
                    compiled,
                    "-w",
                    work / f"target/{name}.gz",
                    "-o",
                    dest,
                    "--verifier_target",
                    "evm",
                    "--write_vk",
                    "-c",
                    crs,
                ],
            )
            run(
                f"native_verify_{name}",
                [
                    bb,
                    "verify",
                    "-p",
                    dest / "proof",
                    "-i",
                    dest / "public_inputs",
                    "-k",
                    dest / "vk",
                    "--verifier_target",
                    "evm",
                    "-c",
                    crs,
                ],
            )
            expected = b"".join(int(v).to_bytes(32, "big") for v in case["public_inputs"])
            if (dest / "public_inputs").read_bytes() != expected:
                raise RuntimeError("Public-input byte encoding mismatch")
            if i and (dest / "vk").read_bytes() != (artifacts / "case_0/vk").read_bytes():
                raise RuntimeError("Verification key depends on witness")
            report["cases"].append(
                {
                    "name": case["name"],
                    "model": case["model"],
                    "proof_bytes": (dest / "proof").stat().st_size,
                    "public_input_bytes": len(expected),
                    "proof_sha256": sha(dest / "proof"),
                }
            )
        key = artifacts / "case_0/vk"
        words = [int.from_bytes(key.read_bytes()[i : i + 32], "big") for i in range(0, 1888, 32)]
        if words[1] - 8 != 9:
            raise RuntimeError("Unexpected VK application-input count")
        report["vk"] = {
            "sha256": sha(key),
            "hash": (key.parent / "vk_hash").read_bytes().hex(),
            "log_n": words[0],
            "application_inputs": words[1] - 8,
            "total_inputs": words[1],
        }
        generated = out / "UltraHonkVerifier.fe"
        run(
            "generate_fe",
            [sys.executable, upstream / "scripts/generate.py", "-k", key, "-o", generated],
        )
        run(
            "compile_fe",
            [
                binaries["fe"],
                "build",
                "--standalone",
                generated,
                "-O",
                "2",
                "--emit",
                "bytecode,runtime-bytecode",
                "--out-dir",
                out / "fe_build",
            ],
        )
        for source, target in [
            ("UltraHonkVerifier.bin", "fe.bin"),
            ("UltraHonkVerifier.runtime.bin", "fe.runtime.bin"),
            ("RelationsLib.runtime.bin", "fe-relations.runtime.bin"),
        ]:
            raw = bytes.fromhex((out / "fe_build" / source).read_text().strip().removeprefix("0x"))
            (artifacts / target).write_bytes(raw)
        run(
            "generate_solidity",
            [
                bb,
                "write_solidity_verifier",
                "-k",
                key,
                "-o",
                out / "Reference.sol",
                "--verifier_target",
                "evm",
            ],
        )
        run(
            "compile_solidity",
            [
                binaries["solc"],
                "--bin",
                "--optimize",
                "--optimize-runs",
                "1",
                "--evm-version",
                "osaka",
                "--metadata-hash",
                "none",
                "--libraries",
                "Reference.sol:RelationsLib=0x0000000000000000000000000000000000001001,Reference.sol:ZKTranscriptLib=0x0000000000000000000000000000000000001002",
                "-o",
                out / "solidity_build",
                "Reference.sol",
            ],
        )
        for source, target in [
            ("HonkVerifier", "solidity"),
            ("RelationsLib", "RelationsLib"),
            ("ZKTranscriptLib", "ZKTranscriptLib"),
        ]:
            (artifacts / f"{target}.bin").write_bytes(
                bytes.fromhex((out / f"solidity_build/{source}.bin").read_text().strip())
            )
        (artifacts / "case_count").write_bytes(len(cases).to_bytes(32, "big"))
        (evm / "test").mkdir()
        (evm / "src").mkdir()
        shutil.copy2(ROOT / "tests/evm/FelonyVerifier.t.sol", evm / "test/FelonyVerifier.t.sol")
        shutil.copytree(
            ROOT / "lib/forge-std",
            evm / "lib/forge-std",
            ignore=shutil.ignore_patterns(".git", ".github", "test", "scripts"),
        )
        (evm / "foundry.toml").write_text(
            "\n".join(
                [
                    "[profile.default]",
                    'src = "src"',
                    'test = "test"',
                    'out = "out"',
                    'cache_path = "cache"',
                    'libs = ["lib"]',
                    f"solc = {json.dumps(str(binaries['solc']))}",
                    'evm_version = "osaka"',
                    "optimizer = true",
                    "optimizer_runs = 1",
                    'bytecode_hash = "none"',
                    "gas_limit = 10000000000",
                    "memory_limit = 536870912",
                    'fs_permissions = [{ access = "read", path = "./artifacts" }]',
                    "",
                ]
            )
        )
        forge = run(
            "evm_tests",
            [
                binaries["forge"],
                "test",
                "--match-contract",
                "FelonyVerifierTest",
                "-vv",
                "--color",
                "never",
            ],
            evm,
        )
        report["metrics"] = {
            name: int(value) for name, value in re.findall(r"^\s+([\w.]+): (\d+)\s*$", forge, re.M)
        }
        report["tests_passed"] = len(re.findall(r"^\[PASS\]", forge, re.M))
        if report["tests_passed"] != 6:
            raise RuntimeError("Expected all six EVM integration tests to execute")
        report["generated_verifier_sha256"] = sha(generated)
        if args.publish:
            publish = ROOT / "contracts/generated/UltraHonkVerifier.fe"
            publish.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(generated, publish)
            report["published"] = str(publish.relative_to(ROOT))
            manifest = {
                "format": "Barretenberg 6.0.0 UltraHonk ZK/Keccak EVM",
                "circuit_artifact_sha256": report["circuit_artifact_sha256"],
                "verification_key": report["vk"],
                "public_input_names": report["public_inputs"],
                "generated_source_sha256": report["generated_verifier_sha256"],
                "circuit_source_sha256": {
                    k: v for k, v in report["sources"].items() if k.startswith("circuit/")
                },
                "generator_source_sha256": report["upstream_sources"],
                "toolchain_lock_sha256": report["toolchain_lock_sha256"],
                "tool_sha256": report["tool_sha256"],
                "nargo_version": report["nargo_version"],
                "validation_report": str((out / "report.json").relative_to(ROOT))
                if out.is_relative_to(ROOT)
                else str(out / "report.json"),
            }
            (publish.parent / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
        report["success"] = True
    finally:
        (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"Report: {out / 'report.json'}", flush=True)


if __name__ == "__main__":
    main()
