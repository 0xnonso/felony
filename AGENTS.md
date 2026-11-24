# Working on Felony

## Project map

- `contracts/src/`: Fe Arena, tournament, oracle, fee collector and shared modules.
- `circuit/src/`: Noir inference and sampling. `model/felony/`: Python inference, training, evaluation and CLI.
- `model/tests/`, `tests/`, `test_vectors/`: tests and public fixtures. Foundry suites live in `tests/evm/`, reusable test doubles in `tests/mocks/`, and shared Solidity interfaces in `tests/Interfaces.sol`.
- `tests/fixtures/`: Fe test harness package with a path dependency on `contracts/`; check it directly with `fe check tests/fixtures`.
- `scripts/`: validation, formatting and proof generation.
- `docs/`: project-specific protocol and development documentation. Zensical navigation is in `zensical.toml`.

Before changing behavior, read the relevant spec: [inference](docs/INFERENCE.md), [contracts](docs/GAME_CONTRACTS.md), [economics](docs/GAME_ECONOMICS.md).

Keep implementation rationale beside the relevant specification or guide in `docs/`; avoid parallel copies of current behavior or chronological work logs.

## Setup and checks

Run commands from the repository root. `make setup` installs the full toolchain, pinned dependency checkouts and Python ≥3.12 dependencies from `uv.lock`; Make must already be installed. Declare dependency changes in `pyproject.toml` and regenerate the lock file; do not add requirements files. Native versions and the verifier-generator revision are pinned in `toolchain.lock.json`. Setup saves executable selections in ignored `.tools/toolchain.json` and `.tools/toolchain.mk`. Override `FE`, `FORGE`, `SOLC`, `NARGO` or `BARRETENBERG_BIN` to select a matching executable. For a different generator checkout location, pass `BARRETENBERG_FE=/absolute/path/to/barretenberg_fe` to setup and subsequent Make commands.

Run `make format` after edits and `make format-check` before finishing. Formatting covers maintained Python, Fe, Noir and Solidity files, so wait until other agents finish editing them. The pinned Forge 1.4.4 formatter can drop braces from single-line blocks containing several statements; write those blocks across multiple lines and test after formatting.

Use `make docs` to preview documentation and `make docs-build` for a clean, strict static build. The optional `docs` dependency group stays in `pyproject.toml` and `uv.lock`. Edit model and circuit guides in `docs/`; their directory READMEs are links.

Run checks appropriate to the change:

| Change | Checks |
|---|---|
| Documentation | `make docs-build` |
| Python | `make test-model` and `make typecheck` |
| Circuit or witness | `make test-circuit` and `.venv/bin/python scripts/verify_circuit.py`; generate and verify proofs for changes to proving behavior |
| Contracts | `make test-contracts CONTRACT_OUTPUT=contracts/target/my-new-check`, using a new output directory |
| Starter workflow | Train briefly into a new temporary directory, then `PYTHONPATH=model .venv/bin/python -m felony check /path/to/model.json` |

## Cross-language changes

For Fe changes, check the pinned compiler’s `core` and `std` libraries before adding a local helper. Prefer a built-in when its behavior, rounding and supported EVM target match the project.

Keep feature encoding, integer arithmetic, model dimensions, commitment hashing, sampling and the nine public inputs consistent across Python, Noir and the Arena. Protocol changes require updating the [inference specification](docs/INFERENCE.md), vectors, circuit, verifier and proof fixtures together. Use `scripts/generate_inference_vectors.py --check` and `scripts/check_intermediates.py`. For protocol changes, run `scripts/verify_circuit.py --prove`, `scripts/verify_fe.py` and `scripts/verify_game.py` for fresh proofs; use each runner’s `--help` for toolchain and output options.

Keccak encoding and domains must agree across Fe, `model/felony/keccak.py`, `tests/reference/bracket.py` and `tests/evm/MerkleBracket.sol`. Update mirrored test interfaces when contract selectors change.

## Generated files and evidence

- Regenerate `contracts/generated/` with `make publish-verifier PROOF_OUTPUT=contracts/target/<unique-run>`; do not edit verifier code or its provenance manifest by hand.
- `model/base/MANIFEST.json` records how to reproduce the public models. Keep it consistent when those models change.
- `test_vectors/bracket.json` and `test_vectors/inference.json` contain the current independent protocol fixtures. Preserve their source provenance and verify changes against the independent implementations; keep obsolete fixtures outside the repository.
- Keep experiment history outside this repository. Preserve frozen outputs and source hashes in the external archive; never resume them as unchanged after their sources change.
- Keep production sampler keys and witnesses out of Git; committed fixtures use public test values only.
- Distinguish mock tests, real-proof replay, local RPC forks and live network delivery in reports.

## Parallel work and handoff

- Before editing, inspect the working diff and declare the files you own. Split parallel tasks by files; agree on shared interfaces before implementations diverge. Never overwrite another task's changes.
- Use a separate worktree for overlapping edits. Run repository-wide formatting only after writers have stopped.
- Handoff with changed paths, interface changes, exact check commands and remaining failures. Final checks must run on the integrated sources, not just individual branches.
- Keep explanations in the relevant spec or ADR; remove stale or redundant prose. Preserve license notices and tool directives.
- Test observable behavior and failure sequences. Use controlled time, explicit external outcomes and recorded seeds. Keep focused regressions and independent protocol vectors; do not delete a test based on who wrote it.
- A failing scenario should leave a reproducible input or trace. Add the smallest regression that catches the failure. Separate simulated dependencies from real integration evidence.

Use `make test-stateful CONTRACT_OUTPUT=contracts/target/<unique-run> FUZZ_SEED=0x1234` for the existing Foundry lifecycle scenarios and seeded invariant campaign. It still builds Fe and runs Fe tests, but filters EVM execution to `FelonyInvariantTest` and omits gas benchmarks. It is not the full contract or proof gate. Use `make test-contracts` before handing off contract behavior changes.
