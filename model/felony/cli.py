"""Starter workflow: create, train, check and evaluate an exported model.

Run from the repository root with ``PYTHONPATH=model python -m felony <command>``.
"""

import argparse
from dataclasses import asdict
import hashlib
import json
from pathlib import Path
import sys

import numpy as np
import torch

from .actor import Actor, load_export
from .evaluation import DEVELOPMENT, SeedSchedule, evaluate_matchup, summarize_matchup
from .fixtures import legal_states
from .inference import State, forward
from .simulator import BatchGame, Heuristic, sample_tickets
from .training import Config, Trainer

HEURISTICS = ("uniform", "match", "shift", "sandbag", "mixed", "cyclic")
BASE = Path(__file__).resolve().parents[1] / "base"


def sha256(path) -> str:
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def library_versions() -> dict:
    return {
        "python": sys.version.split()[0],
        "numpy": np.__version__,
        "torch": str(torch.__version__),
    }


def init(out, seed=0):
    out = Path(out)
    if out.exists():
        raise FileExistsError(f"{out} exists")
    out.parent.mkdir(parents=True, exist_ok=True)
    Actor(seed).save_export(out)
    return out


def train(
    out,
    updates,
    base=None,
    resume=False,
    seed=1,
    batch_games=128,
    target=None,
    target_fraction=None,
    opponents=None,
    scoring=None,
):
    out = Path(out)
    if updates < 1 or batch_games < 1:
        raise ValueError("updates and batch_games must be positive")
    if target_fraction is not None and (target is None or not 0 <= target_fraction <= 1):
        raise ValueError("target_fraction requires a target and must be between 0 and 1")
    if resume:
        if (
            base is not None
            or target is not None
            or target_fraction is not None
            or opponents
            or scoring is not None
        ):
            raise ValueError("resume uses saved models and settings; do not pass replacements")
        trainer = Trainer.load(out)
        info = trainer.run_info
        if info is None:
            info = json.loads((out / "run.json").read_text())
        target_actor = None
        if info.get("target"):
            target_path = out / "target.json"
            if sha256(target_path) != info["target"]["sha256"]:
                raise ValueError("saved target changed")
            target_actor = load_export(target_path)
    else:
        if (out / "model.json").exists() or (out / "training.pt").exists():
            raise FileExistsError(f"{out} already holds a run; use --resume to continue it")
        if base is None:
            raise ValueError("a base model is required")
        torch.set_num_threads(1)
        trainer = Trainer(
            Config(
                seed=seed,
                batch_games=batch_games,
                scoring=scoring or "pvp",
                target_fraction=0.5 if target_fraction is None else target_fraction,
            )
        )
        target_actor = load_export(target) if target is not None else None
        trainer.external_population = [load_export(path) for path in (opponents or [])]

        trainer.actor.load_state_dict(load_export(base).state_dict())
        info = {"base": str(base), "base_sha256": sha256(base), "config": asdict(trainer.config)}
        info["target"] = None
        info["opponents"] = [{"path": str(p), "sha256": sha256(p)} for p in (opponents or [])]
        if target_actor is not None:
            out.mkdir(parents=True, exist_ok=True)
            target_actor.save_export(out / "target.json")
            info["target"] = {"path": str(target), "sha256": sha256(out / "target.json")}
    out.mkdir(parents=True, exist_ok=True)
    trainer.train_to(
        trainer.iteration + updates, target=target_actor, log_path=out / "training_log.jsonl"
    )
    info.update(
        updates=trainer.iteration,
        games=trainer.iteration * trainer.config.batch_games,
        versions=library_versions(),
    )
    trainer.save(out, run_info=info)
    return out / "model.json"


def _played_states(games, seed):
    game = BatchGame(games, seed)

    def bits(row):
        return sum(int(v) << i for i, v in enumerate(row))

    states = []
    for round_index in range(9):
        for seat in (0, 1):
            other = 1 - seat
            sign = 1 if seat == 0 else -1
            for j in range(games):
                states.append(
                    State(
                        bits(game.hands[seat, j]),
                        bits(game.hands[other, j]),
                        bits(game.loot[j]),
                        int(game.order[j, round_index]) + 1,
                        int(game.difference[j]) * sign,
                        tuple(map(int, game.history[seat, j])),
                        tuple(map(int, game.history[other, j])),
                    )
                )
        game.step(
            sample_tickets(game.hands[0], game.rngs[0]), sample_tickets(game.hands[1], game.rngs[1])
        )
    return states


def check(path, games=8, seed=0):
    if games < 0:
        raise ValueError("games must not be negative")
    actor = load_export(path)
    model = actor.export()
    if Actor.from_model(model).export() != model:
        raise ValueError("export does not round-trip")
    states = legal_states(seed + 19) + (_played_states(games, seed) if games else [])
    features = torch.tensor([s.features() for s in states])
    with torch.no_grad():
        _, trace = actor(features, features[:, :9] > 0)
    for j, state in enumerate(states):
        expected = forward(model, state)
        for name in ("z1", "h1", "z2", "h2", "z3", "raw_tickets", "tickets"):
            if trace[name][j].tolist() != expected[name]:
                raise ValueError(f"{name} differs from the integer reference at state {j}")
    return {
        "model": str(path),
        "sha256": sha256(path),
        "states_checked": len(states),
        "exact": True,
    }


def model_id(path) -> str:
    return "sha256:" + sha256(path)


def _opponent(name):
    if name in HEURISTICS:
        return Heuristic(name), name
    return load_export(name).policy(), model_id(name)


def evaluate(path, opponents=HEURISTICS, groups=500, replicates=2000, seed=0, scoring="pvp"):
    if groups < 1:
        raise ValueError("groups must be positive")
    candidate = load_export(path).policy()
    schedule = SeedSchedule(DEVELOPMENT, "" if seed == 0 else str(seed))
    report = {
        "model": str(path),
        "model_id": model_id(path),
        "scoring": scoring,
        "split": DEVELOPMENT,
        "seed": seed,
        "schedule": schedule.fingerprint,
        "games_per_opponent": 2 * groups,
        "opponents": {},
    }
    for name in opponents:
        policy, opponent_id = _opponent(str(name))
        result = evaluate_matchup(
            candidate,
            policy,
            model_id(path),
            opponent_id,
            schedule,
            groups,
            chunk_groups=min(groups, 1000),
            scoring=scoring,
        )
        estimates = summarize_matchup(result, replicates=replicates)
        report["opponents"][str(name)] = {
            "id": opponent_id,
            **{k: e.to_json() for k, e in estimates.items()},
        }
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(prog="python -m felony", description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    p = commands.add_parser("init", help="write a deterministic untrained model")
    p.add_argument("out", type=Path)
    p.add_argument("--seed", type=int, default=0)

    p = commands.add_parser("train", help="train from a model, or resume a run")
    p.add_argument("out", type=Path, help="run directory")
    p.add_argument(
        "--base",
        type=Path,
        help="exported model to start from (default: model/base/felony-base.json)",
    )
    p.add_argument(
        "--scoring",
        choices=("pvp", "tournament"),
        help="reward rule (default: pvp; saved on resume)",
    )
    p.add_argument("--resume", action="store_true", help="continue the run in OUT")
    p.add_argument("--updates", type=int, default=2048, help="updates to add (128 games each)")
    p.add_argument("--seed", type=int, default=1)
    p.add_argument("--batch-games", type=int, default=128)
    p.add_argument("--target", type=Path, help="frozen model to practise against")
    p.add_argument("--target-fraction", type=float, help="target probability (default: 0.5)")
    p.add_argument(
        "--opponent",
        type=Path,
        action="append",
        dest="opponents",
        help="extra model in the general training pool; repeatable",
    )

    p = commands.add_parser("check", help="validate an export against the integer reference")
    p.add_argument("model", type=Path)
    p.add_argument("--games", type=int, default=8, help="random games whose states are checked")

    p = commands.add_parser("evaluate", help="play seat-swapped games against opponents")
    p.add_argument("model", type=Path)
    p.add_argument("--scoring", choices=("pvp", "tournament"), default="pvp")
    p.add_argument(
        "--opponent",
        action="append",
        dest="opponents",
        help=f"heuristic ({', '.join(HEURISTICS)}) or model path; repeatable",
    )
    p.add_argument("--groups", type=int, default=500, help="seat-swapped pairs per opponent")
    p.add_argument(
        "--seed", type=int, default=0, help="evaluation schedule; keep equal for comparisons"
    )

    args = parser.parse_args(argv)
    if args.command == "init":
        result = {"model": str(init(args.out, args.seed))}
    elif args.command == "train":
        if args.resume and args.base is not None:
            parser.error("--resume continues the saved run; do not pass --base")
        base = None if args.resume else args.base or BASE / "felony-base.json"
        model = train(
            args.out,
            args.updates,
            base,
            args.resume,
            args.seed,
            args.batch_games,
            args.target,
            args.target_fraction,
            args.opponents,
            args.scoring,
        )
        result = check(model)
    elif args.command == "check":
        result = check(args.model, args.games)
    else:
        result = evaluate(
            args.model,
            args.opponents or HEURISTICS,
            args.groups,
            seed=args.seed,
            scoring=args.scoring,
        )
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
