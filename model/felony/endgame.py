from dataclasses import dataclass
from fractions import Fraction
from functools import lru_cache
from itertools import combinations
from typing import Sequence

import numpy as np

CARDS = 9
ALL_CARDS = (1 << CARDS) - 1
MAX_ENDGAME_CARDS = 3
MAX_MATRIX_SIDE = 4
MAX_SCORE_DIFFERENCE = 45

OWN_HAND_START = 0
OPPONENT_HAND_START = 9
LOOT_START = 18
CURRENT_START = 27
SCORE_INDEX = 36
NUM_FEATURES = 55
FEATURE_ON = 255

HALF = Fraction(1, 2)
CACHE_SIZE = 1 << 20


@dataclass(frozen=True)
class MatrixSolution:
    value: Fraction
    row: tuple[Fraction, ...]
    column: tuple[Fraction, ...]
    row_guarantee: Fraction
    column_bound: Fraction

    @property
    def duality_gap(self) -> Fraction:
        return self.column_bound - self.row_guarantee


@dataclass(frozen=True)
class EndgameState:
    own_hand: int
    opponent_hand: int
    loot: int
    current: int
    difference: int

    def __post_init__(self):
        for name in ("own_hand", "opponent_hand", "loot", "current", "difference"):
            if type(getattr(self, name)) is not int:
                raise TypeError(f"{name} must be an integer")
        for name in ("own_hand", "opponent_hand", "loot"):
            if not 1 <= getattr(self, name) <= ALL_CARDS:
                raise ValueError(f"{name} must be a nonempty subset of 1..9")
        count = self.loot.bit_count()
        if self.own_hand.bit_count() != count or self.opponent_hand.bit_count() != count:
            raise ValueError("hands and loot must have the same size")
        if not 1 <= self.current <= CARDS or not self.loot >> (self.current - 1) & 1:
            raise ValueError("current loot must be in the remaining loot")

    @property
    def cards_left(self) -> int:
        return self.loot.bit_count()

    def swapped(self) -> "EndgameState":
        return EndgameState(
            self.opponent_hand, self.own_hand, self.loot, self.current, -self.difference
        )


@dataclass(frozen=True)
class EndgameSolution:
    own_policy: tuple[Fraction, ...]
    opponent_policy: tuple[Fraction, ...]
    value: Fraction
    own_guarantee: Fraction
    opponent_bound: Fraction
    payoff: tuple[tuple[Fraction, ...], ...]
    own_cards: tuple[int, ...]
    opponent_cards: tuple[int, ...]

    @property
    def duality_gap(self) -> Fraction:
        return self.opponent_bound - self.own_guarantee

    def float_residual(self) -> float:
        own = [float(self.own_policy[card - 1]) for card in self.own_cards]
        opponent = [float(self.opponent_policy[card - 1]) for card in self.opponent_cards]
        payoff = [[float(cell) for cell in row] for row in self.payoff]
        guarantee = min(
            sum(p * row[j] for p, row in zip(own, payoff)) for j in range(len(opponent))
        )
        bound = max(sum(q * cell for q, cell in zip(opponent, row)) for row in payoff)
        return max(abs(bound - guarantee), abs(sum(own) - 1.0), abs(sum(opponent) - 1.0))


def _exact_matrix(matrix: Sequence[Sequence]) -> tuple[tuple[Fraction, ...], ...]:
    rows = tuple(tuple(row) for row in matrix)
    if not rows or not rows[0] or any(len(row) != len(rows[0]) for row in rows):
        raise ValueError("matrix must be rectangular and nonempty")
    if len(rows) > MAX_MATRIX_SIDE or len(rows[0]) > MAX_MATRIX_SIDE:
        raise ValueError("matrix is too large for vertex enumeration")
    for row in rows:
        for cell in row:
            if type(cell) not in (int, Fraction):
                raise TypeError("matrix entries must be integers or fractions")
    return tuple(tuple(Fraction(cell) for cell in row) for row in rows)


def _solve_linear(system: list[list[Fraction]]) -> list[Fraction] | None:
    size = len(system)
    rows = [row[:] for row in system]
    for column in range(size):
        pivot = next((r for r in range(column, size) if rows[r][column] != 0), None)
        if pivot is None:
            return None
        rows[column], rows[pivot] = rows[pivot], rows[column]
        divisor = rows[column][column]
        rows[column] = [cell / divisor for cell in rows[column]]
        for r in range(size):
            factor = rows[r][column]
            if r != column and factor != 0:
                rows[r] = [a - factor * b for a, b in zip(rows[r], rows[column])]
    return [row[-1] for row in rows]


def _guarantee(matrix: Sequence[Sequence[Fraction]], strategy: Sequence[Fraction]) -> Fraction:
    return min(
        sum((p * row[j] for p, row in zip(strategy, matrix)), start=Fraction(0))
        for j in range(len(matrix[0]))
    )


def _optimal_vertices(matrix) -> tuple[Fraction, list[tuple[Fraction, ...]]]:
    rows, columns = len(matrix), len(matrix[0])
    candidates = set()
    for size in range(1, min(rows, columns) + 1):
        for support in combinations(range(rows), size):
            for tight in combinations(range(columns), size):
                system = [
                    [matrix[r][c] for r in support] + [Fraction(-1), Fraction(0)] for c in tight
                ]
                system.append([Fraction(1)] * size + [Fraction(0), Fraction(1)])
                solved = _solve_linear(system)
                if solved is None or any(p < 0 for p in solved[:size]):
                    continue
                strategy = [Fraction(0)] * rows
                for r, p in zip(support, solved):
                    strategy[r] = p
                candidates.add(tuple(strategy))
    scored = [(_guarantee(matrix, strategy), strategy) for strategy in candidates]
    value = max(score for score, _ in scored)
    return value, sorted(strategy for score, strategy in scored if score == value)


def _centroid(vertices: list[tuple[Fraction, ...]]) -> tuple[Fraction, ...]:
    return tuple(sum(values, Fraction(0)) / len(vertices) for values in zip(*vertices))


def solve_matrix(matrix: Sequence[Sequence]) -> MatrixSolution:
    exact = _exact_matrix(matrix)
    row_value, row_vertices = _optimal_vertices(exact)
    mirrored = tuple(tuple(-cell for cell in column) for column in zip(*exact))
    negative_value, column_vertices = _optimal_vertices(mirrored)
    row = _centroid(row_vertices)
    column = _centroid(column_vertices)
    guarantee = _guarantee(exact, row)
    bound = -_guarantee(mirrored, column)
    if not row_value == -negative_value == guarantee == bound:
        raise ArithmeticError("minimax certificate failed")
    return MatrixSolution(row_value, row, column, guarantee, bound)


def _cards(mask: int) -> tuple[int, ...]:
    return tuple(card for card in range(1, CARDS + 1) if mask >> (card - 1) & 1)


def _without(mask: int, card: int) -> int:
    return mask & ~(1 << (card - 1))


def _terminal_score(difference: int) -> Fraction:
    return Fraction(1) if difference > 0 else HALF if difference == 0 else Fraction(0)


def _round_payoff(own, opponent, loot, current, difference):
    remaining = _without(loot, current)
    payoff = []
    for own_card in _cards(own):
        row = []
        for opponent_card in _cards(opponent):
            sign = (own_card > opponent_card) - (own_card < opponent_card)
            row.append(
                _position_value(
                    _without(own, own_card),
                    _without(opponent, opponent_card),
                    remaining,
                    difference + sign * current,
                )
            )
        payoff.append(tuple(row))
    return tuple(payoff)


@lru_cache(maxsize=CACHE_SIZE)
def _solved_round(own, opponent, loot, current, difference):
    payoff = _round_payoff(own, opponent, loot, current, difference)
    return payoff, solve_matrix(payoff)


@lru_cache(maxsize=CACHE_SIZE)
def _position_value(own, opponent, loot, difference) -> Fraction:
    if loot == 0:
        return _terminal_score(difference)
    prizes = _cards(loot)
    total = sum(
        (_solved_round(own, opponent, loot, prize, difference)[1].value for prize in prizes),
        Fraction(0),
    )
    return total / len(prizes)


def _require_endgame(cards_left: int) -> None:
    if cards_left > MAX_ENDGAME_CARDS:
        raise ValueError(f"the teacher covers at most {MAX_ENDGAME_CARDS} remaining cards")


def position_value(own_hand: int, opponent_hand: int, loot: int, difference: int) -> Fraction:
    any_prize = _cards(loot)[0] if loot else 0
    state = EndgameState(own_hand, opponent_hand, loot, any_prize, difference)
    _require_endgame(state.cards_left)
    return _position_value(own_hand, opponent_hand, loot, difference)


def solve_endgame(state: EndgameState) -> EndgameSolution:
    _require_endgame(state.cards_left)
    payoff, solution = _solved_round(
        state.own_hand, state.opponent_hand, state.loot, state.current, state.difference
    )
    own_cards = _cards(state.own_hand)
    opponent_cards = _cards(state.opponent_hand)
    own_policy = [Fraction(0)] * CARDS
    opponent_policy = [Fraction(0)] * CARDS
    for card, probability in zip(own_cards, solution.row):
        own_policy[card - 1] = probability
    for card, probability in zip(opponent_cards, solution.column):
        opponent_policy[card - 1] = probability
    return EndgameSolution(
        tuple(own_policy),
        tuple(opponent_policy),
        solution.value,
        solution.row_guarantee,
        solution.column_bound,
        payoff,
        own_cards,
        opponent_cards,
    )


def _score_feature(difference: int) -> int:
    magnitude = (abs(difference) * FEATURE_ON + 22) // MAX_SCORE_DIFFERENCE
    return -magnitude if difference < 0 else magnitude


SCORE_FROM_FEATURE = {
    _score_feature(difference): difference
    for difference in range(-MAX_SCORE_DIFFERENCE, MAX_SCORE_DIFFERENCE + 1)
}


def _mask_from_features(values) -> int:
    mask = 0
    for index, value in enumerate(values):
        if value == FEATURE_ON:
            mask |= 1 << index
        elif value != 0:
            raise ValueError("mask features must be 0 or 255")
    return mask


def decode_features(features) -> EndgameState:
    row = np.asarray(features)
    if row.shape != (NUM_FEATURES,) or not np.issubdtype(row.dtype, np.integer):
        raise ValueError("expected 55 integer features")
    values = row.tolist()
    current = _mask_from_features(values[CURRENT_START : CURRENT_START + CARDS])
    if current.bit_count() != 1:
        raise ValueError("current loot must be one-hot")
    if values[SCORE_INDEX] not in SCORE_FROM_FEATURE:
        raise ValueError("score feature is not a valid encoding")
    return EndgameState(
        _mask_from_features(values[OWN_HAND_START : OWN_HAND_START + CARDS]),
        _mask_from_features(values[OPPONENT_HAND_START : OPPONENT_HAND_START + CARDS]),
        _mask_from_features(values[LOOT_START : LOOT_START + CARDS]),
        current.bit_length(),
        SCORE_FROM_FEATURE[values[SCORE_INDEX]],
    )


def teacher_targets(features, legal=None) -> dict[str, np.ndarray]:
    batch = np.asarray(features)
    if batch.ndim != 2 or batch.shape[1] != NUM_FEATURES:
        raise ValueError("features must have shape (batch, 55)")
    if legal is not None:
        legal = np.asarray(legal, dtype=bool)
        if legal.shape != (len(batch), CARDS):
            raise ValueError("legal must have shape (batch, 9)")
    size = len(batch)
    covered = np.zeros(size, dtype=bool)
    policy = np.zeros((size, CARDS), dtype=np.float64)
    value = np.zeros(size, dtype=np.float64)
    residual = np.zeros(size, dtype=np.float64)
    for index, row in enumerate(batch):
        state = decode_features(row)
        if legal is not None:
            expected = [bool(state.own_hand >> card & 1) for card in range(CARDS)]
            if legal[index].tolist() != expected:
                raise ValueError("legal mask disagrees with the own-hand features")
        if state.cards_left > MAX_ENDGAME_CARDS:
            continue
        solution = solve_endgame(state)
        covered[index] = True
        policy[index] = [float(p) for p in solution.own_policy]
        value[index] = float(solution.value)
        residual[index] = solution.float_residual()
    return {"covered": covered, "policy": policy, "value": value, "residual": residual}
