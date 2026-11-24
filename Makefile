PYTHON ?= .venv/bin/python
BARRETENBERG_FE ?= $(abspath ../barretenberg_fe)
-include .tools/prerequisites.mk
-include .tools/toolchain.mk
UV ?= uv
NARGO ?= nargo
FE ?= fe
FORGE ?= forge
SOLC ?= solc
BARRETENBERG_BIN ?= bb
ifeq ($(filter setup,$(MAKECMDGOALS)),)
export FE FORGE SOLC NARGO BARRETENBERG_BIN
endif
BUILD_OUTPUT ?= contracts/target/build
PROOF_OUTPUT ?= contracts/target/proofs
MODEL ?=
VERIFIER ?= contracts/generated/UltraHonkVerifier.fe
OUTPUT ?= model/runs/starter
UPDATES ?= 2048
CONTRACT_OUTPUT ?= contracts/target/local-check
FUZZ_RUNS ?= 256
FUZZ_SEED ?= 0x66656c6f6e79
INVARIANT_RUNS ?= 64
INVARIANT_DEPTH ?= 256
DOCS_ADDR ?= 127.0.0.1:8000

.PHONY: build build-contracts build-circuit verify-circuit verify-fe verify-game verify-proofs publish-verifier test-setup help setup format format-check test test-model test-circuit test-contracts test-stateful train typecheck docs docs-build
help:
	@echo "make setup         Install all dependencies; reuse matching tools"
	@echo "make build         Build contracts and circuit"
	@echo "make verify-proofs PROOF_OUTPUT=contracts/target/my-proofs [MODEL=path/to/model.json]"
	@echo "make docs          Preview the documentation site"
	@echo "make docs-build    Validate and build the static docs"
	@echo "make format        Format Python, Fe, Noir and Solidity"
	@echo "make format-check  Check formatting without changing source"
	@echo "make typecheck     Check model, tests and scripts with Pyright"
	@echo "make test          Run model and circuit tests"
	@echo "make test-contracts CONTRACT_OUTPUT=contracts/target/my-check"
	@echo "make test-stateful CONTRACT_OUTPUT=contracts/target/stateful-check FUZZ_SEED=0x1234"
	@echo "make train OUTPUT=model/runs/my-model UPDATES=2048"

setup:
	bash scripts/setup.sh --barretenberg-fe "$(BARRETENBERG_FE)"

format:
	$(PYTHON) scripts/format.py

format-check:
	$(PYTHON) scripts/format.py --check

typecheck:
	$(PYTHON) -m pyright

test: test-setup test-model test-circuit

test-model:
	PYTHONPATH=model $(PYTHON) -m unittest discover -s model/tests -v

test-circuit:
	cd circuit && $(NARGO) test

test-contracts:
	$(PYTHON) scripts/test_contracts.py --barretenberg-fe "$(BARRETENBERG_FE)" --output $(CONTRACT_OUTPUT) --fuzz-runs $(FUZZ_RUNS) --fuzz-seed $(FUZZ_SEED) --invariant-runs $(INVARIANT_RUNS) --invariant-depth $(INVARIANT_DEPTH)

test-stateful:
	$(PYTHON) scripts/test_contracts.py --barretenberg-fe "$(BARRETENBERG_FE)" --output $(CONTRACT_OUTPUT) --suite stateful --fuzz-seed $(FUZZ_SEED) --invariant-runs $(INVARIANT_RUNS) --invariant-depth $(INVARIANT_DEPTH)

train:
	PYTHONPATH=model $(PYTHON) -m felony train $(OUTPUT) --updates $(UPDATES)

docs:
	$(UV) run --locked --group docs zensical serve --dev-addr $(DOCS_ADDR)

docs-build:
	$(UV) run --locked --group docs zensical build --clean --strict

build: build-contracts build-circuit

build-contracts:
	"$(FE)" check contracts
	"$(FE)" build contracts -O 2 --emit bytecode,runtime-bytecode,abi --out-dir "$(BUILD_OUTPUT)"

build-circuit:
	cd circuit && "$(NARGO)" compile

test-setup:
	$(PYTHON) -m unittest discover -s tests -p 'test_setup_toolchain.py' -v

verify-circuit:
	$(PYTHON) scripts/verify_circuit.py --nargo "$(NARGO)" --bb "$(BARRETENBERG_BIN)" --prove --output "$(PROOF_OUTPUT)/circuit" --crs "$(BARRETENBERG_FE)/.tools/crs"

verify-fe:
	$(PYTHON) scripts/verify_fe.py --barretenberg-fe "$(BARRETENBERG_FE)" --nargo "$(NARGO)" --output "$(PROOF_OUTPUT)/verifier" $(if $(MODEL),--trained-model "$(MODEL)")

verify-game:
	$(PYTHON) scripts/verify_game.py --barretenberg-fe "$(BARRETENBERG_FE)" --nargo "$(NARGO)" --output "$(PROOF_OUTPUT)/game" --verifier "$(VERIFIER)" $(if $(MODEL),--model "$(MODEL)")

verify-proofs:
	$(PYTHON) -c 'import pathlib, sys; pathlib.Path(sys.argv[1]).mkdir(parents=True)' "$(PROOF_OUTPUT)"
	$(MAKE) verify-circuit
	$(MAKE) verify-fe
	$(MAKE) verify-game VERIFIER="$(PROOF_OUTPUT)/verifier/UltraHonkVerifier.fe"

publish-verifier:
	$(PYTHON) scripts/verify_fe.py --barretenberg-fe "$(BARRETENBERG_FE)" --nargo "$(NARGO)" --output "$(PROOF_OUTPUT)/publish" --publish
