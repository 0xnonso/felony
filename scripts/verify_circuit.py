#!/usr/bin/env python3
"""Reproduce integer parity, witness rejection and optional real ZK proof checks.

Uses an isolated copy of the Noir package; never reads/writes the player's Prover.toml.
All inputs are public synthetic fixtures. Native verification is NOT Fe/EVM execution.
"""

import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import sys
import tempfile

from validation_tools import capture_logged, installed_tools

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "model"))
from felony.fixtures import prover_toml  # noqa: E402
from felony.inference import PUBLIC_INPUT_NAMES  # noqa: E402
from felony.poseidon2 import FIELD_MODULUS  # noqa: E402


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--nargo")
    parser.add_argument(
        "--prove",
        action="store_true",
        help="Require Barretenberg 6.0.0 and verify real evm/ZK proofs",
    )
    parser.add_argument(
        "--bb",
        default=os.environ.get("BARRETENBERG_BIN"),
        help="Explicit Barretenberg executable; bb on PATH may be the IDE",
    )
    parser.add_argument(
        "--crs",
        type=Path,
        help="Existing Barretenberg CRS directory (otherwise downloaded under target)",
    )
    parser.add_argument(
        "--skip-noir-tests",
        action="store_true",
        help="For iterative development only; report marks this omission",
    )
    parser.add_argument("--output", type=Path, default=ROOT / "circuit/target/validation")
    args = parser.parse_args()
    args.nargo = args.nargo or str(installed_tools(("nargo",))["nargo"])
    if args.prove and not args.bb:
        args.bb = str(installed_tools(("barretenberg",))["barretenberg"])
    if args.bb:
        os.environ["BARRETENBERG_BIN"] = str(Path(args.bb).resolve())
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    env = {
        **os.environ,
        "PYTHONDONTWRITEBYTECODE": "1",
        "PYTHONPATH": str(ROOT / "model"),
        "HARDWARE_CONCURRENCY": "8",
    }
    report = {
        "success": False,
        "platform": platform.platform(),
        "python": platform.python_version(),
        "scope": "native circuit validation; not browser, trained policy, or Fe/EVM verification",
        "noir_tests_skipped": args.skip_noir_tests,
        "proofs_requested": args.prove,
        "steps": [],
        "proofs": [],
    }

    def run(label, command, cwd=ROOT, rejected=False, rejection_text=None):
        print(f"{label} ...", flush=True)
        result, elapsed = capture_logged(
            label,
            command,
            cwd=cwd,
            env=env,
            log_dir=output,
            records=report["steps"],
            timeout=240,
            merge_stderr=True,
            extra={"expected_rejection": rejected},
        )
        if rejected:
            if result.returncode == 0:
                raise RuntimeError(f"{label}: invalid input/proof was accepted")
            markers = (rejection_text,) if isinstance(rejection_text, str) else rejection_text
            if markers and not any(marker.lower() in result.stdout.lower() for marker in markers):
                raise RuntimeError(
                    f"{label}: failed for an unexpected reason: {result.stdout[-1500:]}"
                )
        elif result.returncode != 0:
            raise RuntimeError(f"{label}: {result.stdout[-2500:]}")
        print(f"  {'rejected as expected' if rejected else 'passed'} ({elapsed:.3f}s)", flush=True)
        return result.stdout, elapsed

    try:
        version, _ = run("nargo_version", [args.nargo, "--version"])
        report["nargo_version"] = version.strip()
        if not version.startswith("nargo version = 1.0.0\n"):
            raise RuntimeError(
                "This specification is validated with Nargo 1.0.0; review version changes explicitly"
            )
        if args.prove:
            version, _ = run("bb_version", [args.bb, "--version"])
            if version.strip() != "6.0.0":
                raise RuntimeError(
                    "Expected Barretenberg 6.0.0, not the BB IDE or another prover version"
                )
            report["barretenberg_version"] = version.strip()
        run(
            "python_tests",
            [
                sys.executable,
                "-m",
                "unittest",
                "discover",
                "-s",
                "model/tests",
                "-p",
                "test_inference.py",
                "-v",
            ],
        )
        run("fixtures_check", [sys.executable, "scripts/generate_inference_vectors.py", "--check"])
        run(
            "intermediate_parity",
            [sys.executable, "scripts/check_intermediates.py", "--nargo", args.nargo],
        )
        data = json.loads((ROOT / "test_vectors/inference.json").read_text())
        files = [
            ROOT / "circuit/Nargo.toml",
            ROOT / "docs/INFERENCE.md",
            ROOT / "test_vectors/inference.json",
        ]
        files += sorted((ROOT / "circuit/src").glob("*.nr"))
        files += sorted((ROOT / "model/felony").glob("*.py"))
        files += sorted((ROOT / "model/tests").glob("*.py"))
        files += sorted((ROOT / "scripts").glob("*.py"))
        files += [
            ROOT / "scripts/check_intermediates_main.nr",
            ROOT / "pyproject.toml",
            ROOT / "uv.lock",
        ]
        report["source_sha256"] = {
            str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files
        }
        with tempfile.TemporaryDirectory(prefix="felony-circuit-v1-") as directory:
            work = Path(directory)
            shutil.copyfile(ROOT / "circuit/Nargo.toml", work / "Nargo.toml")
            shutil.copytree(ROOT / "circuit/src", work / "src")
            run("nargo_check", [args.nargo, "check"], work)
            if not args.skip_noir_tests:
                run("noir_tests", [args.nargo, "test"], work)
            run("nargo_compile", [args.nargo, "compile"], work)
            artifact = work / "target/felony_circuit.json"
            compiled = json.loads(artifact.read_text())
            public = [
                p["name"] for p in compiled["abi"]["parameters"] if p["visibility"] == "public"
            ]
            if public != list(PUBLIC_INPUT_NAMES):
                raise RuntimeError(f"public ABI ordering mismatch: {public}")
            report["public_input_names"] = public
            report["artifact_sha256"] = hashlib.sha256(artifact.read_bytes()).hexdigest()
            if args.prove:
                gates, _ = run("gates", [args.bb, "gates", "-b", artifact, "-t", "evm"], work)
                try:
                    report["gates"] = json.loads(gates)
                except json.JSONDecodeError:
                    report["gates"] = gates.strip()
            proof_indices = (0, 3, 9)
            for index, case in enumerate(data["cases"]):
                name = f"case_{index}"
                (work / f"{name}.toml").write_text(prover_toml(data, case))
                run(f"execute_{case['name']}", [args.nargo, "execute", "-p", name, name], work)
                if args.prove and index in proof_indices:
                    proof_output = output / name
                    proof_output.mkdir(exist_ok=True)
                    crs = args.crs.resolve() if args.crs else output / "crs"
                    _, seconds = run(
                        f"prove_{name}",
                        [
                            args.bb,
                            "prove",
                            "-b",
                            artifact,
                            "-w",
                            work / f"target/{name}.gz",
                            "-o",
                            proof_output,
                            "-t",
                            "evm",
                            "--write_vk",
                            "-c",
                            crs,
                        ],
                        work,
                    )
                    verify = [
                        args.bb,
                        "verify",
                        "-p",
                        proof_output / "proof",
                        "-k",
                        proof_output / "vk",
                        "-i",
                        proof_output / "public_inputs",
                        "-t",
                        "evm",
                        "-c",
                        crs,
                    ]
                    run(f"verify_{name}", verify, work)
                    raw = (proof_output / "public_inputs").read_bytes()
                    expected = b"".join(int(x).to_bytes(32, "big") for x in case["public_inputs"])
                    if raw != expected:
                        raise RuntimeError(
                            "prover's public-input encoding disagrees with specification"
                        )
                    report["proofs"].append(
                        {
                            "case": case["name"],
                            "prove_seconds": seconds,
                            "proof_bytes": (proof_output / "proof").stat().st_size,
                            "public_input_bytes": len(raw),
                            "zk_target": "evm",
                        }
                    )
                    if index == 0:
                        for pos, field_name in enumerate(PUBLIC_INPUT_NAMES):
                            bad = bytearray(raw)
                            value = (
                                int.from_bytes(bad[pos * 32 : (pos + 1) * 32], "big") + 1
                            ) % FIELD_MODULUS
                            bad[pos * 32 : (pos + 1) * 32] = value.to_bytes(32, "big")
                            bad_path = proof_output / f"tampered_{field_name}"
                            bad_path.write_bytes(bad)
                            changed = verify.copy()
                            changed[changed.index("-i") + 1] = bad_path
                            run(
                                f"reject_public_{field_name}",
                                changed,
                                work,
                                True,
                                "verification failed",
                            )
                        bad_proof = bytearray((proof_output / "proof").read_bytes())
                        bad_proof[-1] ^= 1
                        bad_path = proof_output / "tampered_proof"
                        bad_path.write_bytes(bad_proof)
                        changed = verify.copy()
                        changed[changed.index("-p") + 1] = bad_path
                        run(
                            "reject_proof_bytes",
                            changed,
                            work,
                            True,
                            ("verification failed", "not on the curve"),
                        )

            original = data["cases"][0]

            for mutation in (
                "weight",
                "bias",
                "key",
                "salt",
                "wrong_action",
                "state_high_bit",
                "round",
                "player",
                "address",
            ):
                altered = copy.deepcopy(original)
                altered_data = {
                    "models": {original["model"]: copy.deepcopy(data["models"][original["model"]])}
                }
                expected_error = "commitment mismatch"
                if mutation == "weight":
                    altered_data["models"][original["model"]]["w"][-1] ^= 1
                elif mutation == "bias":
                    altered_data["models"][original["model"]]["b"][-1] ^= 1
                elif mutation in ("key", "salt"):
                    altered[mutation] = str(int(altered[mutation]) + 1)
                elif mutation == "wrong_action":
                    altered["expected"]["action"] = str(
                        (int(altered["expected"]["action"]) + 1) % 9
                    )
                    expected_error = "action is not the sampled card"
                elif mutation == "state_high_bit":
                    altered["state"] = str(int(altered["state"]) | (1 << 110))
                    expected_error = "Field failed to decompose into specified 110 limbs"
                elif mutation == "round":
                    altered["context"]["round"] = "1"
                    expected_error = "hand size does not match round"
                elif mutation == "player":
                    altered["context"]["player_id"] = "2"
                    expected_error = "player id out of range"
                elif mutation == "address":
                    altered["context"]["contract_address"] = str(1 << 160)
                    expected_error = "Assertion failed: call to assert_max_bit_size"
                (work / "invalid.toml").write_text(prover_toml(altered_data, altered))
                run(
                    f"reject_witness_{mutation}",
                    [args.nargo, "execute", "-p", "invalid", "invalid"],
                    work,
                    True,
                    expected_error,
                )
        report["success"] = True
    finally:
        (output / "report.json").write_text(json.dumps(report, indent=2) + "\n")
        print(f"Report: {output / 'report.json'}", flush=True)


if __name__ == "__main__":
    main()
