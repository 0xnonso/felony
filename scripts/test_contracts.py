#!/usr/bin/env python3
"""Build Fe contracts and run local lifecycle/ERC-4626/tournament tests. No broadcasts."""

import argparse
import json
import os
from pathlib import Path
import shutil

from validation_tools import capture_logged, installed_tools, sha256 as digest

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--barretenberg-fe", type=Path, default=ROOT.parent / "barretenberg_fe")
    parser.add_argument(
        "--aave-fork",
        action="store_true",
        help="Requires FELONY_AAVE_RPC_URL; local fixed-block fork only",
    )
    parser.add_argument(
        "--vrf-fork",
        action="store_true",
        help="Local Sepolia coordinator request test; requires FELONY_SEPOLIA_RPC_URL",
    )
    parser.add_argument(
        "--aave-block",
        type=int,
        default=26444402,
        help="Ethereum fork block; 0 selects current head",
    )
    parser.add_argument("--fuzz-runs", type=int, default=256)
    parser.add_argument("--invariant-runs", type=int, default=64)
    parser.add_argument("--invariant-depth", type=int, default=256)
    parser.add_argument("--fuzz-seed", default="0x66656c6f6e79")
    parser.add_argument("--suite", choices=("all", "stateful"), default="all")
    args = parser.parse_args()
    if args.suite == "stateful" and (args.aave_fork or args.vrf_fork):
        parser.error("fork tests require --suite all")
    if args.aave_block < 0:
        parser.error("aave block must be nonnegative")
    if args.fuzz_runs <= 0 or args.invariant_runs <= 0 or args.invariant_depth <= 0:
        parser.error("fuzz runs, invariant runs and depth must be positive")
    if args.vrf_fork and not os.environ.get("FELONY_SEPOLIA_RPC_URL"):
        parser.error("--vrf-fork requires FELONY_SEPOLIA_RPC_URL")
    if args.aave_fork and not os.environ.get("FELONY_AAVE_RPC_URL"):
        parser.error("--aave-fork requires FELONY_AAVE_RPC_URL")
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=False)
    upstream = args.barretenberg_fe.resolve()
    tools = installed_tools(("fe", "forge", "solc"), upstream)
    logs = out / "logs"
    logs.mkdir()
    report = {
        "success": False,
        "evm_version": "osaka",
        "scope": (
            "stateful EVM scenarios and invariants; mock vault, verifier and coordinator"
            if args.suite == "stateful"
            else "local EVM integration; mock verifier except separate verify_game.py"
        ),
        "suite": args.suite,
        "commands": [],
        "sizes": {},
        "aave_fork": args.aave_fork,
        "aave_block": args.aave_block,
        "vrf_fork": args.vrf_fork,
        "fuzz": {"runs": args.fuzz_runs, "seed": args.fuzz_seed},
        "invariants": {
            "runs": args.invariant_runs,
            "depth": args.invariant_depth,
            "seed": args.fuzz_seed,
            "fail_on_revert": True,
        },
    }
    report["tool_sha256"] = {name: digest(path) for name, path in tools.items()}
    sources = list((ROOT / "contracts/src").rglob("*.fe")) + [
        ROOT / "contracts/fe.toml",
        Path(__file__).resolve(),
        ROOT / "tests/reference/bracket.py",
        ROOT / "scripts/validation_tools.py",
        ROOT / "model/felony/keccak.py",
        ROOT / "pyproject.toml",
        ROOT / "uv.lock",
    ]
    test_names = [
        "MerkleBracket.sol",
        "RandomOracle.t.sol",
        "RandomOracleFork.t.sol",
        "FelonyInvariant.t.sol",
        "FeeCollector.t.sol",
        "FelonyGame.t.sol",
        "VaultIntegration.t.sol",
        "FelonyTournament.t.sol",
        "FelonyVaultTournament.t.sol",
    ]
    tests = [Path("evm") / name for name in test_names]
    tests += [
        Path("Interfaces.sol"),
        *[p.relative_to(ROOT / "tests") for p in sorted((ROOT / "tests/mocks").glob("*.sol"))],
    ]
    sources += [ROOT / "foundry.lock", *sorted((ROOT / "lib/forge-std/src").rglob("*.sol"))]
    sources += [ROOT / "fe.toml", ROOT / "tests/fixtures/fe.toml"]
    sources += sorted((ROOT / "tests/fixtures/src").rglob("*.fe"))
    sources += [ROOT / "tests" / name for name in tests]
    report["source_sha256"] = {str(p.relative_to(ROOT)): digest(p) for p in sources}

    def run(label, command, cwd=out):
        print(label, flush=True)
        env = os.environ.copy()
        env["FELONY_AAVE_BLOCK"] = str(args.aave_block)
        if not args.aave_fork:
            env.pop("FELONY_AAVE_RPC_URL", None)
        if not args.vrf_fork:
            env.pop("FELONY_SEPOLIA_RPC_URL", None)
        result, _ = capture_logged(
            label, command, cwd=cwd, env=env, log_dir=logs, records=report["commands"]
        )
        if result.returncode:
            raise RuntimeError((result.stdout + result.stderr)[-6000:])

    try:
        ingot = out / "contracts"
        shutil.copytree(ROOT / "contracts/src", ingot / "src")
        shutil.copy2(ROOT / "contracts/fe.toml", ingot / "fe.toml")
        run("fe_format", [tools["fe"], "fmt", "--check", ingot / "src"])
        run(
            "fixture_format",
            [tools["fe"], "fmt", "--check", ROOT / "tests/fixtures/src"],
        )
        run(
            "solidity_format",
            [
                tools["forge"],
                "fmt",
                "--check",
                *[ROOT / "tests" / name for name in tests],
            ],
        )
        run("fe_check", [tools["fe"], "check", ingot])
        run("fe_test", [tools["fe"], "test", ingot])
        evm = out / "evm"
        (evm / "test").mkdir(parents=True)
        (evm / "src").mkdir()
        (evm / "artifacts").mkdir()
        for contract, artifact in [
            ("Felony", "game"),
            ("FelonyTournament", "tournament"),
            ("ChainlinkRandomOracle", "random_oracle"),
            ("FeeCollector", "fees"),
        ]:
            build = out / "build" / contract
            run(
                "build_" + artifact,
                [
                    tools["fe"],
                    "build",
                    ingot,
                    "--contract",
                    contract,
                    "-O",
                    "2",
                    "--emit",
                    "bytecode,runtime-bytecode,abi",
                    "--out-dir",
                    build,
                ],
            )
            creation = bytes.fromhex(
                (build / f"{contract}.bin").read_text().strip().removeprefix("0x")
            )
            runtime = bytes.fromhex(
                (build / f"{contract}.runtime.bin").read_text().strip().removeprefix("0x")
            )
            report["sizes"][contract] = {
                "creation_bytes": len(creation),
                "runtime_template_bytes": len(runtime),
            }

            assert len(runtime) <= 24576 and len(creation) <= 49152, (
                f"{contract}: EVM deployment size limit"
            )
            (evm / "artifacts" / f"{artifact}.bin").write_bytes(creation)
        fixture = out / "tests/fixtures"
        shutil.copytree(ROOT / "tests/fixtures", fixture)
        run("fixture_check", [tools["fe"], "check", fixture])
        build = out / "build/VaultHarness"
        run(
            "build_vault_harness",
            [
                tools["fe"],
                "build",
                fixture,
                "--contract",
                "VaultHarness",
                "-O",
                "2",
                "--emit",
                "bytecode",
                "--out-dir",
                build,
            ],
        )
        (evm / "artifacts/vault_harness.bin").write_bytes(
            bytes.fromhex((build / "VaultHarness.bin").read_text().strip().removeprefix("0x"))
        )
        for name in tests:
            (evm / "test" / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / "tests" / name, evm / "test" / name)
        shutil.copytree(
            ROOT / "lib/forge-std",
            evm / "lib/forge-std",
            ignore=shutil.ignore_patterns(".git", ".github", "test", "scripts"),
        )
        (evm / "foundry.toml").write_text(
            f"""[profile.default]\nsrc = "src"\ntest = "test"\nsolc = {json.dumps(str(tools["solc"]))}\nevm_version = "osaka"\noptimizer = true\noptimizer_runs = 1\ngas_limit = 2000000000\ncode_size_limit = 100000\nfs_permissions = [{{ access = "read", path = "./artifacts" }}]\n\n[fuzz]\nruns = {args.fuzz_runs}\n\n[invariant]\nruns = {args.invariant_runs}\ndepth = {args.invariant_depth}\nfail_on_revert = true\n"""
        )
        run(
            "evm_tests",
            [
                tools["forge"],
                "test",
                "--deny",
                "warnings",
                "--root",
                evm,
                "--fuzz-seed",
                args.fuzz_seed,
                *(
                    ["--match-contract", "^FelonyInvariantTest$"]
                    if args.suite == "stateful"
                    else []
                ),
                "-vv",
            ],
            evm,
        )
        if args.suite == "all":
            run(
                "isolated_lifecycle_gas",
                [
                    tools["forge"],
                    "test",
                    "--root",
                    evm,
                    "--isolate",
                    "--deny",
                    "warnings",
                    "--match-test",
                    "testGas|testUnderfilled513",
                    "-vv",
                ],
                evm,
            )
        report["sources_unchanged"] = set((ROOT / "contracts/src").rglob("*.fe")) == {
            p for p in sources if p.is_relative_to(ROOT / "contracts/src")
        } and all(digest(ROOT / name) == value for name, value in report["source_sha256"].items())
        assert report["sources_unchanged"], "sources changed while validation was running"
        report["success"] = True
    finally:
        (out / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    print(out / "report.json")


if __name__ == "__main__":
    main()
