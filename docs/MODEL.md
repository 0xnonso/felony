# Felony models

A Felony model is a fixed integer network (55 → 128 → 128 → 9) defined by [inference specification](INFERENCE.md). Any offline training method is allowed, but the exported model must follow that specification exactly, because every move is proved against it.

## Quick start

Install the pinned environment once, from the repository root, with `make setup`. The starter commands (`init`, `train`, `check`, `evaluate`) need no Barretenberg executable. Then train from the supplied base model and get a reusable export:

```sh
PYTHONPATH=model .venv/bin/python -m felony train model/runs/my-model
```

This runs 2,048 updates of 128 games against heuristics and saved policies on one CPU thread. `make train OUTPUT=model/runs/my-model UPDATES=2048` runs the same command. The output directory holds:

| File | Use |
|---|---|
| `model.json` | The exported model. Commit to it, prove with it, or train from it again. |
| `training.pt` | Authoritative trainer state and resume metadata, for `--resume`. |
| `run.json` | The base model hash, settings, update count and library versions. |
| `training_log.jsonl` | One line of diagnostics per update. |

### Checkpoint recovery

Checkpoint saves use a temporary file and atomic replacement:

- If a save fails **before** `training.pt` is replaced, the previous checkpoint remains usable; if no checkpoint exists yet, rerun the original command.
- If it fails **afterwards**, use `--resume`: the checkpoint contains the model and metadata even when `model.json` or `run.json` is missing or stale.
- Resume before using the export after an interrupted save. A successful resume adds the requested updates and rewrites both files.
- Older checkpoints still require their original `run.json`.

### Operating rules

- Use only one training process per output directory. A hard kill may leave unused hidden temporary files.
- The diagnostic log can repeat updates from an interrupted attempt; the checkpoint's update count is authoritative.
- Atomic saves protect against interrupted writes, not hardware or filesystem failure.

### Paths and hashes

- `model/runs/` is ignored by git.
- `check` reports the file SHA-256, not the Poseidon2 model digest.
- Computing commitments and generating proof fixtures separately require Barretenberg 6.0.0; use the sibling toolchain or set `BARRETENBERG_BIN`.

## Commands

All commands print JSON. Run them with `PYTHONPATH=model .venv/bin/python -m felony <command>`.

| Command | What it does |
|---|---|
| `init OUT [--seed 0]` | Writes a deterministic, untrained model. |
| `train OUT [--base MODEL] [--updates 2048] [--seed 1] [--batch-games 128]` | Trains a copy of `MODEL` (default `model/base/felony-base.json`) and checks the result. Use a separate output directory for each run. |
| `train OUT --target MODEL [--target-fraction 0.5] [--opponent MODEL]...` | Practises against a frozen target; extra opponents join the general pool. Extra opponents also work without a target. |
| `train OUT --resume [--updates N]` | Adds `N` updates to the run saved in `OUT`. |
| `check MODEL [--games 8]` | Validates the file and compares the trainer's forward pass with the exact Python integer reference on sample states. It does not run Noir or produce a proof. |
| `evaluate MODEL [--opponent NAME_OR_PATH]... [--groups 500] [--seed 0]` | Plays seat-swapped games on the public development deals against heuristics (`uniform`, `match`, `shift`, `sandbag`, `mixed`, `cyclic`) or other models. Seeds follow file contents, so moving a file does not change results. |

## Tournament scoring

Use `train OUT --scoring tournament` and `evaluate MODEL --scoring tournament` for tournament play:

- Higher total score wins; a score tie goes to the highest captured prize.
- For all-burn games the simulator uses the coin's expected score of 0.5 instead of sampling another coin. Thus the evaluation's `draw` statistic in this mode counts unresolved all-burn games before the on-chain coin, not final tournament draws.
- Score margins stay unchanged, including a zero margin for tiebreak wins.

The default remains `--scoring pvp`, where every score tie is worth 0.5 and stakes are refunded. The training setting is saved in the checkpoint; resume keeps it. To change objectives, start a new run with `--base` pointing at the old export. Older checkpoints default to PvP scoring. The shipped base model uses PvP rewards. Training for tournament scoring uses the same model format and circuit.

## Base models

`model/base/` holds two public models. Neither contains a sampling key or salt; choose your own secret key and salt when you commit to a model. `model/base/MANIFEST.json` lists hashes and the commands that produce each file.

- **`felony-untrained.json`** is the seeded initialization from `init --seed 0`, with no training.
- **`felony-base.json`** is that model after 2,048 updates (262,144 games) of the default trainer with seed 1.

The default training pool includes five public heuristics; evaluation adds `cyclic`. Results against this panel are a development sanity check, not a strength rating against unfamiliar trained opponents.

## Compare training runs

Compare two changes from the same base, using the same training budget and seed:

```sh
PYTHONPATH=model .venv/bin/python -m felony train model/runs/control --updates 2048 --seed 7
PYTHONPATH=model .venv/bin/python -m felony train model/runs/challenger --updates 2048 --seed 7 --target model/base/felony-base.json
```

Each run adds 262,144 games.

- The challenger samples the frozen base with probability 50% for each opponent group; the other groups use the ordinary pool of five heuristics and saved self-play policies.
- The proportion is approximate, not exactly half of every batch. `--target-fraction` changes it; `--opponent path/to/model.json` adds a model to the general pool without replacing the heuristics.
- Neither opponent is trained alongside your actor.

The target is copied to `target.json`, and extra opponents are saved inside `training.pt`. Resume with `train OUT --resume --updates N`; do not resupply opponents or a base. Deleting the original opponent files will not change the resumed run. `run.json` records their hashes and the total game budget.

Evaluate both exports against the base on identical fresh simulated games:

```sh
PYTHONPATH=model .venv/bin/python -m felony evaluate model/runs/control/model.json --opponent model/base/felony-base.json --groups 5000 --seed 2027
PYTHONPATH=model .venv/bin/python -m felony evaluate model/runs/challenger/model.json --opponent model/base/felony-base.json --groups 5000 --seed 2027
```

- A score counts a win as 1 and a draw as 0.5. Above 0.5 means beating that opponent on average; also compare the challenger with the control to see whether targeting helped more than ordinary training.
- Bootstrap intervals resample whole seat-swapped pairs, preserving the dependence between the two games. They describe match luck, not uncertainty across training runs.
- The library's `compare_paired` compares candidates using paired differences on matching schedules; do not subtract interval endpoints to claim a significant gain.

Repeat evaluation against unfamiliar models that neither run trained against, plus the default heuristic panel (omit `--opponent`). If you have no unfamiliar models yet, report only target and heuristic performance. Choose evaluation seeds before looking at results, keep the same seed and opponents for both candidates, and repeat training with several seeds before claiming a reliable improvement. Fresh seeds do not make a repeatedly inspected opponent panel held out. Targeting can win against the base while making other matchups worse.

## Model privacy

Keeping weights and sampler keys private does not prevent an opponent from fitting a surrogate to public bids. Proofs establish that a move follows the committed model; they do not establish resistance to strategy imitation or guarantee competitive strength. Keep evaluation results scoped to their opponents and budgets.

## Library

| File | Purpose |
|---|---|
| `felony/inference.py` | Integer reference: state encoding, features, layers, quantization, commitments and sampling |
| `felony/keccak.py` | Ethereum Keccak-256 through PyCryptodome, with uint256 word encoding |
| `felony/poseidon2.py` | Thin wrapper around official Barretenberg Poseidon2 |
| `felony/actor.py` | Trainable actor whose forward pass equals the integer reference; export and import |
| `felony/training.py` | CPU PPO trainer with self-play snapshots and heuristic opponents |
| `felony/simulator.py` | Batched game simulator and public heuristic opponents |
| `felony/evaluation.py` | Seat-paired evaluation with bootstrap intervals |
| `felony/endgame.py` | Exact endgame solver used as an optional training teacher |
| `felony/cli.py` | The commands above |
| `felony/fixtures.py` | Public synthetic models and states for tests; never use them in competition |

## Training internals

The pipeline trains the same 24,841-parameter actor that the Noir circuit constrains. Training changes weights between games; it introduces no model update inside a committed match. A separate value network helps training and is never exported or proved.

The root `uv.lock` pins the training environment. CPU float64 is intentional: the bounded binary fixed-point products and sums are exact at that precision. Switching the actor to float32, a GPU backend or different scales requires renewed parity tests.

### Follow one learning iteration

1. `simulator.BatchGame` starts a batch of nine-round games. Both policies receive observations before either bid is applied. Features and histories match the existing integer reference.
2. `actor.Actor` rounds its latent parameters to the permitted encodings, runs the integer-equivalent layers, masks unavailable cards and samples from the resulting tickets.
3. The trainer groups games across several opponents: fixed heuristics, a uniform reservoir over all saved self-play snapshots, and optionally independently trained models or a designated target. The learning actor alternates seats between updates.
4. At game end, win/draw/loss becomes reward 1/0.5/0. The value network predicts the expected reward from each observation. Reward minus that prediction is the **advantage**: how much better or worse the outcome was than expected.
5. PPO adjusts action probabilities using those advantages, with a clipped update objective and an entropy bonus. Actor and critic gradients are clipped separately. This uses approximate gradients through the quantization, so it is a training recipe, not a convergence guarantee.
6. Saving writes both a resumable `training.pt` and an integer-only `model.json`. Inference uses the latter. Optimizers, the value network and floating-point latent parameters stay outside the commitment.

### Forward pass and surrogate

The output uses exact clipped integer tickets in the forward pass. Its backward pass uses a normalized softplus distribution as a surrogate, including at an all-zero fallback, so zero-ticket actions have a way to recover.

The surrogate is deliberately biased and can differ materially from the forward distribution. `Config.surrogate_beta` controls its temperature without changing the exported forward rule.

### Optional training controls

The Python `Config` API exposes controls beyond the starter CLI. `opponent_sampling="hard"` uses a moving average of training rollout results to favour difficult opponents while retaining a nonzero sampling floor. Evaluation results do not update these scores.

### Endgame solver

`felony.endgame` solves positions with at most three cards remaining using exact rational arithmetic:

- It averages unknown future loot uniformly and returns both players' mixed strategies with minimax certificates.
- Multiple optimal strategies are combined deterministically by averaging optimal vertices.
- It does not solve the full nine-card game or compute a best response to a particular opponent.
- The solver uses PvP terminal rewards: win 1, score tie 0.5, loss 0. Completed bid history does not affect that objective once the remaining cards, current loot and score difference are known.
- It does not implement the tournament's highest-captured-prize tiebreak and must not be treated as an exact tournament teacher.

### Teacher targets

`teacher_targets(features, legal)` returns `covered`, `policy`, `value` and `residual` arrays; positions with more than three cards are uncovered. Supply only covered examples to `Trainer.set_teacher`, with a positive `Config.teacher_coefficient`.

Training uses squared probability error (Brier loss), which stays finite at zero tickets and preserves mixed targets. Teacher data and training state are saved in the checkpoint; loading uses PyTorch's `weights_only=True` mode.

### Sampling during training

Most simulated training/evaluation moves use uniform uint64 draws with the same integer modulo/CDF rule. They do not run Poseidon or generate proofs per move. Export validation uses the actual context-bound Poseidon sampler. This separates strategic experimentation from cryptographic protocol validation without replacing the deployed inference algorithm.

### Determinism

The trainer enables PyTorch deterministic algorithms, and actor construction uses a local generator so evaluation policies do not reset the trainer's random stream. Exact cross-platform reproducibility is not promised; keep the recorded dependency versions and inspect the parity checks.
