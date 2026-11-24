from dataclasses import dataclass
import hashlib
from functools import partial
from typing import Callable, Mapping, Sequence

import numpy as np

SEED_DOMAIN = "felony-evaluation-v1"
DEVELOPMENT = "development"
HELDOUT = "heldout"
SPLITS = (DEVELOPMENT, HELDOUT)
STATISTICS = ("score", "win", "draw", "loss", "margin")
SCORE = STATISTICS.index("score")

DEFAULT_CHUNK_GROUPS = 1000
DEFAULT_REPLICATES = 10_000
DEFAULT_CONFIDENCE = 0.95
BOOTSTRAP_BATCH = 128


def derive_seed(*parts: str | int) -> int:
    digest = hashlib.sha256()
    for part in (SEED_DOMAIN, *parts):
        if isinstance(part, bool) or not isinstance(part, (str, int)):
            raise TypeError("seed parts must be strings or integers")
        tag, data = (b"s", part.encode()) if isinstance(part, str) else (b"i", str(part).encode())
        digest.update(tag + len(data).to_bytes(8, "big") + data)
    return int.from_bytes(digest.digest()[:8], "big") >> 1


@dataclass(frozen=True)
class SeedSchedule:
    split: str
    secret: str = ""

    def __post_init__(self):
        if self.split not in SPLITS:
            raise ValueError(f"unknown split {self.split!r}")
        if self.split == HELDOUT and not self.secret:
            raise ValueError("the held-out schedule requires a secret")

    @property
    def fingerprint(self) -> str:
        data = f"{SEED_DOMAIN}\0{self.split}\0{self.secret}".encode()
        return hashlib.sha256(data).hexdigest()[:16]

    def seed(self, *parts: str | int) -> int:
        return derive_seed(self.split, self.secret, *parts)


@dataclass(frozen=True)
class Estimate:
    value: float
    low: float
    high: float
    standard_error: float
    confidence: float
    replicates: int

    def to_json(self) -> dict:
        return dict(self.__dict__)


@dataclass(frozen=True)
class MatchupResult:
    candidate_id: str
    opponent_id: str
    split: str
    schedule: str
    seed_label: str
    chunk_groups: int
    outcomes: np.ndarray
    margins: np.ndarray
    scoring: str = "pvp"

    def __post_init__(self):
        if self.split not in SPLITS:
            raise ValueError(f"unknown split {self.split!r}")
        _check_games(self.outcomes, self.margins, self.scoring)

    @property
    def groups(self) -> int:
        return len(self.outcomes)

    @property
    def group_values(self) -> np.ndarray:
        return group_statistics(self.outcomes, self.margins, self.scoring)

    def to_json(self, include_groups: bool = False, **bootstrap) -> dict:
        report = {
            "scoring": self.scoring,
            "candidate": self.candidate_id,
            "opponent": self.opponent_id,
            "split": self.split,
            "schedule": self.schedule,
            "seed_label": self.seed_label,
            "chunk_groups": self.chunk_groups,
            "groups": self.groups,
            "estimates": _estimates_json(summarize_matchup(self, **bootstrap)),
        }
        if include_groups:
            report["outcomes"] = self.outcomes.tolist()
            report["margins"] = self.margins.astype(int).tolist()
        return report


def _check_games(outcomes: np.ndarray, margins: np.ndarray, scoring="pvp") -> None:
    if scoring not in ("pvp", "tournament"):
        raise ValueError("unknown scoring rule")
    if outcomes.ndim != 2 or outcomes.shape[1] != 2 or outcomes.shape[0] == 0:
        raise ValueError("outcomes must have shape (groups, 2) with at least one group")
    if margins.shape != outcomes.shape:
        raise ValueError("margins must have the same shape as outcomes")
    if not np.isin(outcomes, (0.0, 0.5, 1.0)).all():
        raise ValueError("outcomes must be 0, 0.5 or 1")
    checked = np.ones(margins.shape, dtype=bool) if scoring == "pvp" else margins != 0
    if not np.array_equal(np.sign(margins[checked]), 2 * outcomes[checked] - 1):
        raise ValueError("outcomes disagree with the sign of the score margins")


def group_statistics(outcomes: np.ndarray, margins: np.ndarray, scoring="pvp") -> np.ndarray:
    _check_games(outcomes, margins, scoring)
    return np.column_stack(
        (
            outcomes.mean(axis=1),
            (outcomes == 1.0).mean(axis=1),
            (outcomes == 0.5).mean(axis=1),
            (outcomes == 0.0).mean(axis=1),
            margins.mean(axis=1),
        )
    )


def _played(play: Callable, first, second, games: int, seed: int) -> tuple[np.ndarray, np.ndarray]:
    result = play(first, second, games, seed)
    outcome = np.asarray(result["outcome"], dtype=np.float64)
    difference = np.asarray(result["difference"])
    if outcome.shape != (games,) or difference.shape != (games,):
        raise ValueError("play returned arrays of the wrong shape")
    if not np.issubdtype(difference.dtype, np.integer):
        raise ValueError("score differences must be integers")
    return outcome, difference.astype(np.float64)


def evaluate_matchup(
    candidate,
    opponent,
    candidate_id: str,
    opponent_id: str,
    schedule: SeedSchedule,
    groups: int,
    chunk_groups: int = DEFAULT_CHUNK_GROUPS,
    seed_label: str | None = None,
    play: Callable | None = None,
    scoring: str = "pvp",
) -> MatchupResult:
    if groups <= 0 or chunk_groups <= 0:
        raise ValueError("groups and chunk_groups must be positive")
    if play is None:
        from .simulator import play as simulate

        play = partial(simulate, scoring=scoring)
    label = opponent_id if seed_label is None else seed_label
    outcomes = np.empty((groups, 2))
    margins = np.empty((groups, 2))
    for chunk, start in enumerate(range(0, groups, chunk_groups)):
        kept = min(chunk_groups, groups - start)
        stop = start + kept
        seed = schedule.seed("matchup", label, chunk_groups, chunk)
        first_outcome, first_margin = _played(play, candidate, opponent, chunk_groups, seed)
        second_outcome, second_margin = _played(play, opponent, candidate, chunk_groups, seed)
        outcomes[start:stop, 0] = first_outcome[:kept]
        margins[start:stop, 0] = first_margin[:kept]
        outcomes[start:stop, 1] = 1.0 - second_outcome[:kept]
        margins[start:stop, 1] = -second_margin[:kept]
    return MatchupResult(
        candidate_id,
        opponent_id,
        schedule.split,
        schedule.fingerprint,
        label,
        chunk_groups,
        outcomes,
        margins,
        scoring,
    )


def _bootstrap_means(
    values: np.ndarray, replicates: int, seed: int, batch_size: int = BOOTSTRAP_BATCH
) -> np.ndarray:
    if replicates < 2 or batch_size <= 0:
        raise ValueError("need at least two replicates and a positive batch size")
    rng = np.random.default_rng(seed)
    rows = len(values)
    means = np.empty((replicates, values.shape[1]))
    for start in range(0, replicates, batch_size):
        stop = min(start + batch_size, replicates)
        indices = rng.integers(0, rows, size=(stop - start, rows), dtype=np.int64)
        for column in range(values.shape[1]):
            means[start:stop, column] = values[indices, column].mean(axis=1)
    return means


def _estimate(value: float, replicated: np.ndarray, confidence: float) -> Estimate:
    if not 0.0 < confidence < 1.0:
        raise ValueError("confidence must be between 0 and 1")
    tail = (1.0 - confidence) / 2.0
    low, high = np.quantile(replicated, (tail, 1.0 - tail))
    return Estimate(
        float(value),
        float(low),
        float(high),
        float(replicated.std(ddof=1)),
        confidence,
        len(replicated),
    )


def _estimates(
    values: np.ndarray, replicated: np.ndarray, confidence: float
) -> dict[str, Estimate]:
    return {
        name: _estimate(values[column], replicated[:, column], confidence)
        for column, name in enumerate(STATISTICS)
    }


def _estimates_json(estimates: Mapping[str, Estimate]) -> dict:
    return {name: estimate.to_json() for name, estimate in estimates.items()}


def summarize_matchup(
    result: MatchupResult,
    replicates: int = DEFAULT_REPLICATES,
    confidence: float = DEFAULT_CONFIDENCE,
    batch_size: int = BOOTSTRAP_BATCH,
) -> dict[str, Estimate]:
    values = result.group_values
    seed = derive_seed(
        "bootstrap", "matchup", result.candidate_id, result.seed_label, result.groups
    )
    return _estimates(
        values.mean(axis=0), _bootstrap_means(values, replicates, seed, batch_size), confidence
    )


def _stratified(
    strata: Sequence[np.ndarray],
    labels: Sequence[Sequence[str | int]],
    replicates: int,
    confidence: float,
    batch_size: int,
) -> dict[str, Estimate]:
    if not strata:
        raise ValueError("at least one opponent is required")
    point = np.mean([values.mean(axis=0) for values in strata], axis=0)
    total = np.zeros((replicates, len(STATISTICS)))
    for values, label in zip(strata, labels):
        total += _bootstrap_means(values, replicates, derive_seed("bootstrap", *label), batch_size)
    return _estimates(point, total / len(strata), confidence)


def _require_one_split(results: Sequence[MatchupResult]) -> str:
    if len({result.scoring for result in results}) != 1:
        raise ValueError("results with different scoring rules cannot be combined")
    splits = {result.split for result in results}
    if len(splits) != 1:
        raise ValueError("results from development and held-out splits cannot be combined")
    return splits.pop()


def _require_distinct_opponents(results: Sequence[MatchupResult]) -> None:
    opponents = [result.opponent_id for result in results]
    if len(set(opponents)) != len(opponents):
        raise ValueError("each opponent may appear only once")


def summarize_panel(
    results: Sequence[MatchupResult],
    replicates: int = DEFAULT_REPLICATES,
    confidence: float = DEFAULT_CONFIDENCE,
    batch_size: int = BOOTSTRAP_BATCH,
) -> dict:
    _require_one_split(results)
    _require_distinct_opponents(results)
    if len({result.candidate_id for result in results}) != 1:
        raise ValueError("a panel summary covers one candidate")
    strata = [result.group_values for result in results]
    labels = [("panel", r.candidate_id, r.seed_label, r.groups) for r in results]
    per_opponent = {
        r.opponent_id: summarize_matchup(r, replicates, confidence, batch_size) for r in results
    }
    scores = {opponent: estimates["score"].value for opponent, estimates in per_opponent.items()}
    worst = min(scores, key=scores.__getitem__)
    return {
        "candidate": results[0].candidate_id,
        "split": results[0].split,
        "panel": _estimates_json(_stratified(strata, labels, replicates, confidence, batch_size)),
        "per_opponent": {name: _estimates_json(values) for name, values in per_opponent.items()},
        "worst_opponent": worst,
        "worst_opponent_score": scores[worst],
    }


def _paired_values(candidate: MatchupResult, control: MatchupResult) -> np.ndarray:
    for field in (
        "opponent_id",
        "split",
        "schedule",
        "seed_label",
        "chunk_groups",
        "groups",
        "scoring",
    ):
        if getattr(candidate, field) != getattr(control, field):
            raise ValueError(f"paired results must share the same {field}")
    return candidate.group_values - control.group_values


def classify_gain(estimate: Estimate, threshold: float) -> str:
    if estimate.low >= threshold:
        return "meets_threshold"
    if estimate.high < threshold:
        return "below_threshold"
    return "inconclusive"


def compare_paired(
    candidate: MatchupResult,
    control: MatchupResult,
    threshold: float,
    replicates: int = DEFAULT_REPLICATES,
    confidence: float = DEFAULT_CONFIDENCE,
    batch_size: int = BOOTSTRAP_BATCH,
) -> dict:
    values = _paired_values(candidate, control)
    seed = derive_seed(
        "bootstrap", "paired", candidate.candidate_id, control.candidate_id, candidate.seed_label
    )
    means = _bootstrap_means(values, replicates, seed, batch_size)
    estimates = _estimates(values.mean(axis=0), means, confidence)
    return {
        "candidate": candidate.candidate_id,
        "control": control.candidate_id,
        "opponent": candidate.opponent_id,
        "split": candidate.split,
        "groups": candidate.groups,
        "threshold": threshold,
        "classification": classify_gain(estimates["score"], threshold),
        "gain": _estimates_json(estimates),
    }


def compare_panel(
    candidate_results: Sequence[MatchupResult],
    control_results: Sequence[MatchupResult],
    threshold: float,
    replicates: int = DEFAULT_REPLICATES,
    confidence: float = DEFAULT_CONFIDENCE,
    batch_size: int = BOOTSTRAP_BATCH,
) -> dict:
    _require_one_split([*candidate_results, *control_results])
    _require_distinct_opponents(candidate_results)
    _require_distinct_opponents(control_results)
    controls = {result.opponent_id: result for result in control_results}
    if set(controls) != {result.opponent_id for result in candidate_results}:
        raise ValueError("candidate and control must face the same opponents")
    pairs = [(result, controls[result.opponent_id]) for result in candidate_results]
    strata = [_paired_values(candidate, control) for candidate, control in pairs]
    labels = [("panel-gain", a.candidate_id, b.candidate_id, a.seed_label) for a, b in pairs]
    estimates = _stratified(strata, labels, replicates, confidence, batch_size)
    return {
        "split": candidate_results[0].split,
        "threshold": threshold,
        "classification": classify_gain(estimates["score"], threshold),
        "panel_gain": _estimates_json(estimates),
        "per_opponent": {
            a.opponent_id: compare_paired(a, b, threshold, replicates, confidence, batch_size)
            for a, b in pairs
        },
    }


def qualify_candidate(
    results: Sequence[MatchupResult],
    required_opponents: Sequence[str],
    min_advantage: float,
    training_opponents: Sequence[str] = (),
    replicates: int = DEFAULT_REPLICATES,
    confidence: float = DEFAULT_CONFIDENCE,
    batch_size: int = BOOTSTRAP_BATCH,
) -> dict:
    if not required_opponents:
        raise ValueError("at least one required opponent is needed")
    if _require_one_split(results) != HELDOUT:
        raise ValueError("qualification requires held-out results")
    _require_distinct_opponents(results)
    leaked = sorted(set(required_opponents) & set(training_opponents))
    if leaked:
        raise ValueError(f"opponents used in training cannot qualify a candidate: {leaked}")
    by_opponent = {result.opponent_id: result for result in results}
    missing = sorted(set(required_opponents) - set(by_opponent))
    if missing:
        raise ValueError(f"missing required opponents: {missing}")
    required = 0.5 + min_advantage
    opponents = {}
    for opponent in required_opponents:
        score = summarize_matchup(by_opponent[opponent], replicates, confidence, batch_size)[
            "score"
        ]
        opponents[opponent] = {"score": score.to_json(), "passed": score.low > required}
    return {
        "candidate": results[0].candidate_id,
        "required_score_lower_bound": required,
        "passed": all(entry["passed"] for entry in opponents.values()),
        "failed_opponents": [name for name, entry in opponents.items() if not entry["passed"]],
        "opponents": opponents,
    }


def qualify_runs(reports: Mapping[str, Mapping], required_passes: int) -> dict:
    if required_passes <= 0:
        raise ValueError("required_passes must be positive")
    passed = sorted(run for run, report in reports.items() if report["passed"])
    return {
        "runs": len(reports),
        "passed_runs": passed,
        "failed_runs": sorted(set(reports) - set(passed)),
        "required_passes": required_passes,
        "qualified": len(passed) >= required_passes,
    }


def summarize_runs(
    estimates: Mapping[str, Estimate | float], threshold: float | None = None
) -> dict:
    if not estimates:
        raise ValueError("at least one run is required")
    values = {
        run: float(item.value if isinstance(item, Estimate) else item)
        for run, item in estimates.items()
    }
    array = np.array(list(values.values()))
    report = {
        "runs": len(array),
        "values": values,
        "mean": float(array.mean()),
        "standard_deviation": float(array.std(ddof=1)) if len(array) > 1 else None,
        "minimum": float(array.min()),
        "maximum": float(array.max()),
    }
    if threshold is not None:
        report["threshold"] = threshold
        report["runs_at_or_above_threshold"] = int((array >= threshold).sum())
        intervals = [item for item in estimates.values() if isinstance(item, Estimate)]
        if len(intervals) == len(array):
            report["runs_with_interval_above_threshold"] = sum(
                e.low >= threshold for e in intervals
            )
    return report


@dataclass(frozen=True)
class CrossPlay:
    policy_ids: tuple[str, ...]
    results: Mapping[tuple[str, str], MatchupResult]

    def score_matrix(self) -> np.ndarray:
        index = {policy: i for i, policy in enumerate(self.policy_ids)}
        matrix = np.full((len(index), len(index)), np.nan)
        for (a, b), result in self.results.items():
            score = float(result.group_values[:, SCORE].mean())
            matrix[index[a], index[b]] = score
            matrix[index[b], index[a]] = 1.0 - score
        return matrix

    def clear_wins(
        self,
        replicates: int = DEFAULT_REPLICATES,
        confidence: float = DEFAULT_CONFIDENCE,
        batch_size: int = BOOTSTRAP_BATCH,
    ) -> set[tuple[str, str]]:
        wins = set()
        for (a, b), result in self.results.items():
            score = summarize_matchup(result, replicates, confidence, batch_size)["score"]
            if score.low > 0.5:
                wins.add((a, b))
            elif score.high < 0.5:
                wins.add((b, a))
        return wins

    def three_cycles(self, **bootstrap) -> list[tuple[str, str, str]]:
        wins = self.clear_wins(**bootstrap)
        cycles = []
        for a, b in sorted(wins):
            for c in self.policy_ids:
                if (b, c) in wins and (c, a) in wins and a < b and a < c:
                    cycles.append((a, b, c))
        return cycles

    def to_json(self, include_groups: bool = False, **bootstrap) -> dict:
        matrix = self.score_matrix()
        return {
            "policies": list(self.policy_ids),
            "score_matrix": [[None if np.isnan(x) else float(x) for x in row] for row in matrix],
            "three_cycles": [list(cycle) for cycle in self.three_cycles(**bootstrap)],
            "matchups": [
                result.to_json(include_groups=include_groups, **bootstrap)
                for result in self.results.values()
            ],
        }


def cross_play(
    policies: Mapping[str, object],
    schedule: SeedSchedule,
    groups: int,
    chunk_groups: int = DEFAULT_CHUNK_GROUPS,
    play: Callable | None = None,
) -> CrossPlay:
    policy_ids = tuple(sorted(policies))
    if len(policy_ids) < 2:
        raise ValueError("cross-play needs at least two policies")
    results = {}
    for i, a in enumerate(policy_ids):
        for b in policy_ids[i + 1 :]:
            results[(a, b)] = evaluate_matchup(
                policies[a],
                policies[b],
                a,
                b,
                schedule,
                groups,
                chunk_groups,
                derive_label("crossplay", a, b),
                play,
            )
    return CrossPlay(policy_ids, results)


def derive_label(*parts: str) -> str:
    return hashlib.sha256("\0".join(parts).encode()).hexdigest()[:32]
