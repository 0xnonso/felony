#!/usr/bin/env python3
"""Run a complete Fe match using 16 fresh Noir proofs and an independent Python state oracle.
Public test keys only. No real chain deployment, broadcasts, or player Prover.toml reads.
"""

import argparse
from dataclasses import asdict
import json
import os
from pathlib import Path
import shutil
import sys

from validation_tools import capture_logged, installed_tools, sha256

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "model"))
from felony.keccak import keccak_words
from felony.fixtures import synthetic_model, prover_toml
from felony.inference import Model, State, Context, infer, public_inputs

FIELD = 21888242871839275222246405745257275088548364400416034343698204186575808495617
GAME = 0xFE11
ARENA_SOURCES = (
    "lib.fe",
    "constants.fe",
    "rules.fe",
    "types.fe",
    "events.fe",
    "interfaces.fe",
)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--barretenberg-fe", type=Path, default=ROOT.parent / "barretenberg_fe")
    ap.add_argument("--nargo", default=None)
    ap.add_argument(
        "--model",
        type=Path,
        help="Optional trained model; otherwise two dense synthetic models",
    )
    ap.add_argument(
        "--verifier",
        type=Path,
        default=ROOT / "contracts/generated/UltraHonkVerifier.fe",
        help="Generated verifier to build and replay proofs against",
    )
    args = ap.parse_args()
    args.nargo = args.nargo or str(installed_tools(("nargo",))["nargo"])
    verifier = args.verifier.resolve()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    upstream = args.barretenberg_fe.resolve()
    binaries = installed_tools(("fe", "barretenberg", "forge", "solc"), upstream)
    os.environ["BARRETENBERG_BIN"] = str(binaries["barretenberg"])
    logs = out / "logs"
    logs.mkdir()
    evm = out / "evm"
    evm.mkdir()
    art = evm / "artifacts"
    art.mkdir()
    (evm / "test").mkdir()
    work = out / "noir"
    work.mkdir()
    report = {
        "success": False,
        "evm_version": "osaka",
        "scope": "16 real proofs through Fe game and generated Fe verifier; fixed-address runtime install in local EVM",
        "commands": [],
        "tool_sha256": {name: sha256(path) for name, path in binaries.items()},
    }
    env = {**os.environ, "PYTHONDONTWRITEBYTECODE": "1", "HARDWARE_CONCURRENCY": "8"}

    def run(label, cmd, cwd=out):
        print(label, flush=True)
        r, _ = capture_logged(
            label, cmd, cwd=cwd, env=env, log_dir=logs, records=report["commands"]
        )
        if r.returncode:
            raise RuntimeError((r.stdout + r.stderr)[-6000:])
        return r.stdout

    def words_file(path, values):
        path.write_bytes(b"".join(int(x).to_bytes(32, "big") for x in values))

    sources = [
        *[ROOT / "contracts/src" / name for name in ARENA_SOURCES],
        verifier,
        ROOT / "tests/evm/FelonyRealGame.t.sol",
        ROOT / "tests/mocks/RealGameMocks.sol",
        ROOT / "foundry.lock",
        *sorted((ROOT / "lib/forge-std/src").rglob("*.sol")),
        Path(__file__).resolve(),
        ROOT / "scripts/validation_tools.py",
        ROOT / "circuit/Nargo.toml",
        ROOT / "pyproject.toml",
        ROOT / "uv.lock",
        *sorted((ROOT / "circuit/src").rglob("*.nr")),
        *sorted((ROOT / "model/felony").glob("*.py")),
    ]
    if args.model:
        sources.append(args.model.resolve())
    report["sources"] = {
        str(p.relative_to(ROOT) if p.is_relative_to(ROOT) else p): sha256(p) for p in sources
    }
    try:
        src = out / "arena"
        (src / "src").mkdir(parents=True)
        (src / "fe.toml").write_text('[ingot]\nname="arena_test"\nversion="0.1.0"\n')
        for name in ARENA_SOURCES:
            (src / "src" / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / "contracts/src" / name, src / "src" / name)
        run("arena_format", [binaries["fe"], "fmt", "--check", src / "src"])
        run(
            "test_format",
            [
                binaries["forge"],
                "fmt",
                "--check",
                ROOT / "tests/evm/FelonyRealGame.t.sol",
                ROOT / "tests/mocks/RealGameMocks.sol",
            ],
        )
        run(
            "build_arena",
            [
                binaries["fe"],
                "build",
                src,
                "--contract",
                "Felony",
                "-O",
                "2",
                "--emit",
                "bytecode,runtime-bytecode",
                "--out-dir",
                out / "arena_build",
            ],
        )
        runtime = bytes.fromhex(
            (out / "arena_build/Felony.runtime.bin").read_text().strip().removeprefix("0x")
        )
        assert len(runtime) <= 24576, "Arena exceeds EIP-170"
        report["arena_runtime_bytes"] = len(runtime)
        run(
            "build_verifier",
            [
                binaries["fe"],
                "build",
                "--standalone",
                verifier,
                "-O",
                "2",
                "--emit",
                "bytecode",
                "--out-dir",
                out / "verifier_build",
            ],
        )
        for source, dest in (
            (out / "arena_build/Felony.bin", art / "game.bin"),
            (out / "verifier_build/UltraHonkVerifier.bin", art / "verifier.bin"),
        ):
            dest.write_bytes(bytes.fromhex(source.read_text().strip().removeprefix("0x")))
        shutil.copy2(ROOT / "circuit/Nargo.toml", work / "Nargo.toml")
        shutil.copytree(ROOT / "circuit/src", work / "src")
        run("compile_noir", [args.nargo, "compile"], work)
        models = [synthetic_model(7), synthetic_model(29)]
        if args.model:
            m = json.loads(args.model.read_text())
            models = [Model(m["w"], m["b"]), models[1]]
        keys = [101, 102]
        salts = [201, 202]
        commitments = [m.commitment(k, s) for m, k, s in zip(models, keys, salts)]
        words_file(art / "commitments", commitments)
        data = {"models": {str(i): {"w": list(m.w), "b": list(m.b)} for i, m in enumerate(models)}}
        seed = keccak_words([521, 31337, GAME, 1, 777]) % FIELD
        hands = [511, 511]
        histories = [[0] * 9, [0] * 9]
        loot = 511
        scores = [0, 0]
        cases = []
        for round_ in range(9):
            prizes = [i + 1 for i in range(9) if loot & (1 << i)]
            prize = prizes[keccak_words([204, 1, seed, round_]) % len(prizes)]
            bids = []
            for seat in range(2):
                state = State(
                    hands[seat],
                    hands[1 - seat],
                    loot,
                    prize,
                    scores[seat] - scores[1 - seat],
                    tuple(histories[seat]),
                    tuple(histories[1 - seat]),
                )
                ctx = Context(31337, GAME, 1, seat, round_, seed)
                trace = infer(models[seat], state, ctx, keys[seat], salts[seat])
                bids.append(trace["action"] + 1)
                if round_ == 8:
                    continue
                index = 2 * round_ + seat
                name = f"move_{index}"
                dest = art / name
                dest.mkdir()
                case = {
                    "model": str(seat),
                    "key": str(keys[seat]),
                    "salt": str(salts[seat]),
                    "state": str(state.pack()),
                    "context": {k: str(v) for k, v in asdict(ctx).items()},
                    "expected": {k: str(trace[k]) for k in ("commitment", "action")},
                }
                (work / f"{name}.toml").write_text(prover_toml(data, case))
                run(f"execute_{index}", [args.nargo, "execute", "-p", name, name], work)
                run(
                    f"prove_{index}",
                    [
                        binaries["barretenberg"],
                        "prove",
                        "-b",
                        work / "target/felony_circuit.json",
                        "-w",
                        work / f"target/{name}.gz",
                        "-o",
                        dest,
                        "--verifier_target",
                        "evm",
                        "--write_vk",
                        "-c",
                        upstream / ".tools/crs",
                    ],
                )
                expected = b"".join(v.to_bytes(32, "big") for v in public_inputs(state, ctx, trace))
                assert (dest / "public_inputs").read_bytes() == expected
                if index:
                    assert (dest / "vk").read_bytes() == (art / "move_0/vk").read_bytes()
                cases.append(
                    {
                        "round": round_,
                        "seat": seat,
                        "action": trace["action"],
                        "state": str(state.pack()),
                    }
                )
            for seat in range(2):
                hands[seat] ^= 1 << (bids[seat] - 1)
                histories[seat][prize - 1] = bids[seat]
            if bids[0] != bids[1]:
                scores[0 if bids[0] > bids[1] else 1] += prize
            loot ^= 1 << (prize - 1)
        result = 1 if scores[0] > scores[1] else 2 if scores[1] > scores[0] else 3
        words_file(art / "final", [*scores, result])
        report["moves"] = cases
        report["scores"] = scores
        for name in ["evm/FelonyRealGame.t.sol", "mocks/RealGameMocks.sol"]:
            target = evm / "test" / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / "tests" / name, target)
        shutil.copytree(
            ROOT / "lib/forge-std",
            evm / "lib/forge-std",
            ignore=shutil.ignore_patterns(".git", ".github", "test", "scripts"),
        )
        (evm / "foundry.toml").write_text(
            f'[profile.default]\nsrc="src"\ntest="test"\nsolc="{binaries["solc"]}"\nevm_version="osaka"\noptimizer=true\noptimizer_runs=1\ngas_limit=100000000\ncode_size_limit=100000\nfs_permissions=[{{access="read",path="./artifacts"}}]\n'
        )
        run("full_game", [binaries["forge"], "test", "--root", evm, "-vv"], evm)
        report["sources_unchanged"] = all(
            sha256(ROOT / name) == value for name, value in report["sources"].items()
        )
        assert report["sources_unchanged"], "sources changed during validation"
        report["success"] = True
    finally:
        (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
