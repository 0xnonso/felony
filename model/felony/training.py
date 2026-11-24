from contextlib import contextmanager
from dataclasses import asdict, dataclass
import copy
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time
import numpy as np
import torch
from torch import nn
from .actor import Actor
from .simulator import BatchGame, Heuristic, sample_tickets


@contextmanager
def _atomic_file(destination):
    destination = Path(destination)
    with tempfile.NamedTemporaryFile(
        dir=destination.parent, prefix=f".{destination.name}.", delete=False
    ) as stream:
        temporary = Path(stream.name)
    try:
        yield temporary
        with temporary.open("rb") as stream:
            os.fsync(stream.fileno())
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


@dataclass
class Config:
    seed: int = 1
    batch_games: int = 128
    epochs: int = 2
    learning_rate: float = 0.001
    entropy: float = 0.01
    scoring: str = "pvp"
    clip: float = 0.2
    snapshot_interval: int = 32
    population_limit: int = 8
    target_fraction: float = 0.5
    threads: int = 1
    opponent_groups: int = 4
    surrogate_beta: float = 4.0
    opponent_sampling: str = "uniform"
    teacher_coefficient: float = 0.0
    teacher_batch: int = 64

    def __post_init__(self):
        if self.scoring not in ("pvp", "tournament"):
            raise ValueError("unknown scoring rule")
        if self.opponent_sampling not in ("uniform", "hard"):
            raise ValueError("unknown opponent sampling")
        if self.teacher_coefficient < 0 or self.teacher_batch < 1:
            raise ValueError("invalid teacher configuration")


class Trainer:
    def __init__(self, config):
        self.config = config
        torch.set_num_threads(config.threads)
        torch.use_deterministic_algorithms(True)
        torch.manual_seed(config.seed)
        self.actor = Actor(config.seed, config.surrogate_beta)
        self.critic = nn.Sequential(nn.Linear(55, 64), nn.Tanh(), nn.Linear(64, 1)).double()
        self.optimizer = torch.optim.Adam(
            list(self.actor.parameters()) + list(self.critic.parameters()), lr=config.learning_rate
        )
        self.rng = np.random.default_rng(config.seed)
        self.population = []
        self.external_population = []
        self.iteration = 0
        self.elapsed_seconds = 0.0
        self.logs = []
        self.opponent_scores = {}
        self.teacher_bank = None
        self.teacher_examples = 0
        self.run_info: dict | None = None

    def set_teacher(self, features, legal, probabilities):
        x = np.asarray(features, dtype=np.int64)
        m = np.asarray(legal, dtype=bool)
        p = np.asarray(probabilities, dtype=np.float64)
        if (
            x.ndim != 2
            or x.shape[1] != 55
            or m.shape != (len(x), 9)
            or p.shape != m.shape
            or not len(x)
        ):
            raise ValueError("teacher array shapes")
        if (
            not np.isfinite(p).all()
            or (p < 0).any()
            or (p[~m] != 0).any()
            or not np.allclose(p.sum(1), 1)
        ):
            raise ValueError("invalid teacher probabilities")
        if not np.array_equal(x[:, :9] > 0, m):
            raise ValueError("teacher masks disagree with features")
        self.teacher_bank = (torch.as_tensor(x), torch.as_tensor(m), torch.as_tensor(p))

    def opponent_probabilities(self, count, names=None):
        if self.config.opponent_sampling == "uniform":
            return np.full(count, 1 / count)

        names = names or [f"population_{i}" for i in range(count)]
        difficulty = np.array([(1 - self.opponent_scores.get(name, 0.5)) ** 2 for name in names])
        return (
            0.2 / count + 0.8 * difficulty / float(difficulty.sum())
            if difficulty.sum() > 0
            else np.full(count, 1 / count)
        )

    def choose_opponent(self, target):
        if target is not None and self.rng.random() < self.config.target_fraction:
            return target.policy(), "target"
        pool = [Heuristic(x) for x in ("uniform", "match", "shift", "sandbag", "mixed")]
        names = ["heuristic_" + h.name for h in pool]
        pool += [a.policy() for a in self.population + self.external_population]
        names += [f"snapshot_{i}" for i in range(len(self.population))]
        names += [f"external_{i}" for i in range(len(self.external_population))]
        index = (
            int(self.rng.integers(len(pool)))
            if self.config.opponent_sampling == "uniform"
            else int(self.rng.choice(len(pool), p=self.opponent_probabilities(len(pool), names)))
        )
        return pool[index], names[index]

    def update(self, target=None):
        start = time.perf_counter()
        opponents = [
            self.choose_opponent(target)
            for _ in range(min(self.config.opponent_groups, self.config.batch_games))
        ]
        partitions = np.array_split(np.arange(self.config.batch_games), len(opponents))
        opponent_name = ",".join(name for _, name in opponents)
        game = BatchGame(self.config.batch_games, int(self.rng.integers(2**63)))

        seat = self.iteration % 2
        xs, masks, actions, old_logps = [], [], [], []
        diagnostics = []
        for round_index in range(9):
            x, mask = game.observation(seat)
            ox, omask = game.observation(1 - seat)
            with torch.no_grad():
                prob, trace = self.actor(torch.as_tensor(x), torch.as_tensor(mask))
                a = sample_tickets(trace["tickets"].numpy().astype(np.uint64), game.rngs[seat])
                if round_index < 8:
                    xs.append(x)
                    masks.append(mask)
                    actions.append(a)
                    old_logps.append(prob[torch.arange(len(a)), torch.as_tensor(a)].log())
                    legal_count = int(mask.sum())
                    diagnostics.append(
                        (
                            float(trace["fallback"].double().mean()),
                            float(((trace["raw_tickets"] == 0) & torch.as_tensor(mask)).sum())
                            / legal_count,
                            float((trace["raw_tickets"] >= 65535).double().mean()),
                            float((trace["h1"] >= 255).double().mean()),
                            float((trace["h2"] >= 255).double().mean()),
                            float(np.median(trace["tickets"].numpy().sum(1))),
                            float(np.quantile(trace["tickets"].numpy().sum(1), 0.05)),
                        )
                    )
            b = np.empty(self.config.batch_games, dtype=np.int64)
            for indices, (opponent, _) in zip(partitions, opponents):
                b[indices] = opponent(ox[indices], omask[indices], game.rngs[1 - seat])
            game.step(a, b) if seat == 0 else game.step(b, a)
        result = game.result(self.config.scoring)
        rewards = result["outcome"] if seat == 0 else 1 - result["outcome"]
        if self.config.opponent_sampling == "hard":
            for indices, (_, name) in zip(partitions, opponents):
                self.opponent_scores[name] = 0.9 * self.opponent_scores.get(
                    name, 0.5
                ) + 0.1 * float(rewards[indices].mean())
        x = torch.as_tensor(np.concatenate(xs))
        legal = torch.as_tensor(np.concatenate(masks))
        action = torch.as_tensor(np.concatenate(actions))
        old_logp = torch.cat(old_logps)
        returns = torch.as_tensor(np.tile(rewards, 8), dtype=torch.float64)
        with torch.no_grad():
            advantages = returns - self.critic(x.double() / 255).squeeze(1)
            advantages = (advantages - advantages.mean()) / advantages.std().clamp(min=1e-8)
        teacher_batch = None
        if self.config.teacher_coefficient:
            if self.teacher_bank is None:
                raise ValueError("teacher coefficient requires a teacher dataset")
            indices = self.rng.integers(len(self.teacher_bank[0]), size=self.config.teacher_batch)
            teacher_batch = tuple(a[indices] for a in self.teacher_bank)
            self.teacher_examples += len(indices) * self.config.epochs
        for _ in range(self.config.epochs):
            prob, trace = self.actor(x, legal)
            logp = prob[torch.arange(len(action)), action].clamp(min=1e-12).log()
            ratio = (logp - old_logp).exp()
            surrogate = torch.minimum(
                ratio * advantages,
                ratio.clamp(1 - self.config.clip, 1 + self.config.clip) * advantages,
            )
            entropy = -(prob * prob.clamp(min=1e-12).log()).sum(1).mean()
            values = self.critic(x.double() / 255).squeeze(1)
            value_loss = (values - returns).square().mean()
            loss = -surrogate.mean() + 0.5 * value_loss - self.config.entropy * entropy
            teacher_loss = torch.zeros((), dtype=torch.float64)
            if teacher_batch is not None:
                tx, tm, tp = teacher_batch
                predicted, _ = self.actor(tx, tm)

                teacher_loss = (predicted - tp).square().sum(1).mean()
                loss = loss + self.config.teacher_coefficient * teacher_loss
            if not torch.isfinite(loss):
                raise RuntimeError("non-finite training loss")
            self.optimizer.zero_grad(set_to_none=True)
            loss.backward()
            grad_norm = nn.utils.clip_grad_norm_(self.actor.parameters(), 1.0)
            critic_grad_norm = nn.utils.clip_grad_norm_(self.critic.parameters(), 1.0)
            self.optimizer.step()
            self.actor.project()
        self.iteration += 1
        if self.iteration % self.config.snapshot_interval == 0:
            snapshot = Actor.from_model(self.actor.export())

            if len(self.population) < self.config.population_limit:
                self.population.append(snapshot)
            else:
                index = int(self.rng.integers(self.iteration // self.config.snapshot_interval))
                if index < self.config.population_limit:
                    self.population[index] = snapshot
                    self.opponent_scores.pop(f"snapshot_{index}", None)
        self.elapsed_seconds += time.perf_counter() - start
        means = np.mean(diagnostics, axis=0)
        log = dict(
            iteration=self.iteration,
            games=self.iteration * self.config.batch_games,
            environment_steps=self.iteration * self.config.batch_games * 9,
            optimizer_steps=self.iteration * self.config.epochs,
            wall_seconds=self.elapsed_seconds,
            teacher_loss=float(teacher_loss.detach()),
            teacher_examples=self.teacher_examples,
            opponent=opponent_name,
            rollout_score=float(rewards.mean()),
            loss=float(loss.detach()),
            entropy=float(entropy.detach()),
            grad_norm=float(grad_norm),
            critic_grad_norm=float(critic_grad_norm),
            fallback_rate=float(means[0]),
            zero_legal_ticket_rate=float(means[1]),
            head_saturation_rate=float(means[2]),
            hidden1_saturation_rate=float(means[3]),
            hidden2_saturation_rate=float(means[4]),
            mean_round_median_ticket_total=float(means[5]),
            mean_round_p05_ticket_total=float(means[6]),
        )
        self.logs.append(log)
        return log

    def train_to(self, iterations, target=None, log_path=None):
        while self.iteration < iterations:
            record = self.update(target)
            if log_path:
                with Path(log_path).open("a") as stream:
                    stream.write(json.dumps(record) + "\n")
            if self.iteration % 32 == 0 or self.iteration == iterations:
                print(
                    f"seed={self.config.seed} update={self.iteration} score={record['rollout_score']:.3f} fallback={record['fallback_rate']:.4f} time={record['wall_seconds']:.1f}s",
                    flush=True,
                )

    def fork(self):
        return copy.deepcopy(self)

    def save(self, directory, *, run_info=None):
        path = Path(directory)
        path.mkdir(parents=True, exist_ok=True)
        info = self.run_info if run_info is None else run_info

        with _atomic_file(path / "model.json") as export:
            self.actor.save_export(export)
            if info is not None:
                info = dict(info, model_sha256=hashlib.sha256(export.read_bytes()).hexdigest())
            with _atomic_file(path / "training.pt") as checkpoint:
                torch.save(
                    dict(
                        config=asdict(self.config),
                        actor=self.actor.state_dict(),
                        critic=self.critic.state_dict(),
                        optimizer=self.optimizer.state_dict(),
                        rng=self.rng.bit_generator.state,
                        population=[a.state_dict() for a in self.population],
                        external_population=[a.state_dict() for a in self.external_population],
                        iteration=self.iteration,
                        elapsed_seconds=self.elapsed_seconds,
                        logs=self.logs,
                        opponent_scores=self.opponent_scores,
                        teacher_bank=self.teacher_bank,
                        teacher_examples=self.teacher_examples,
                        run_info=info,
                    ),
                    checkpoint,
                )
            self.run_info = info
        if info is not None:
            with _atomic_file(path / "run.json") as metadata:
                metadata.write_text(json.dumps(info, indent=2) + "\n")

    @classmethod
    def load(cls, directory):
        saved = torch.load(Path(directory) / "training.pt", weights_only=True, map_location="cpu")
        trainer = cls(Config(**saved["config"]))
        trainer.actor.load_state_dict(saved["actor"])
        trainer.critic.load_state_dict(saved["critic"])
        trainer.optimizer.load_state_dict(saved["optimizer"])
        trainer.rng.bit_generator.state = saved["rng"]
        for field in ("population", "external_population"):
            actors = []
            for state in saved[field]:
                actor = Actor()
                actor.load_state_dict(state)
                actors.append(actor)
            setattr(trainer, field, actors)
        trainer.iteration, trainer.elapsed_seconds, trainer.logs = (
            saved["iteration"],
            saved["elapsed_seconds"],
            saved["logs"],
        )
        trainer.opponent_scores = saved.get("opponent_scores", {})
        trainer.teacher_bank = saved.get("teacher_bank")
        trainer.teacher_examples = saved.get("teacher_examples", 0)
        trainer.run_info = saved.get("run_info")
        return trainer
