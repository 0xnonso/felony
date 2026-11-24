from dataclasses import dataclass
from functools import cached_property

from .poseidon2 import field, hash_fields

SPEC_VERSION = 1
NW, NB = 24576, 265
ALL_CARDS = 511
BIAS_OFFSET = 1 << 31
PUBLIC_INPUT_NAMES = (
    "commitment",
    "state",
    "chain_id",
    "contract_address",
    "match_id",
    "player_id",
    "round",
    "seed",
    "action",
)


def bounded(value: int, low: int, high: int, name: str) -> int:
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f"{name} out of range")
    return value


@dataclass(frozen=True)
class State:
    own_hand: int
    opponent_hand: int
    loot: int
    current: int
    difference: int
    own_history: tuple[int, ...]
    opponent_history: tuple[int, ...]

    @property
    def round(self) -> int:
        return 9 - self.loot.bit_count()

    def validate(self) -> None:
        for name in ("own_hand", "opponent_hand", "loot"):
            bounded(getattr(self, name), 1, ALL_CARDS, name)
        bounded(self.current, 1, 9, "current loot")
        bounded(self.difference, -45, 45, "score difference")
        if not self.loot & (1 << (self.current - 1)):
            raise ValueError("current loot unavailable")
        if not self.own_hand.bit_count() == self.opponent_hand.bit_count() == self.loot.bit_count():
            raise ValueError("hand/loot counts disagree")
        for history, hand in (
            (self.own_history, self.own_hand),
            (self.opponent_history, self.opponent_hand),
        ):
            if len(history) != 9:
                raise ValueError("history length")
            used = 0
            for i, card in enumerate(history):
                bounded(card, 0, 9, "historical card")
                if self.loot & (1 << i):
                    if card != 0:
                        raise ValueError("unplayed loot has history")
                else:
                    if card == 0:
                        raise ValueError("played loot lacks history")
                    bit = 1 << (card - 1)
                    if used & bit:
                        raise ValueError("duplicate historical card")
                    used |= bit
            if used != (ALL_CARDS ^ hand):
                raise ValueError("history does not complement hand")
        score = sum(
            (i + 1) * ((a > b) - (a < b))
            for i, (a, b) in enumerate(zip(self.own_history, self.opponent_history))
        )
        if score != self.difference:
            raise ValueError("history/score disagree")

    def pack(self) -> int:
        self.validate()
        result = self.own_hand | (self.opponent_hand << 9) | (self.loot << 18)
        result |= self.current << 27
        result |= (self.difference + 45) << 31
        for start, history in ((38, self.own_history), (74, self.opponent_history)):
            for i, card in enumerate(history):
                result |= card << (start + 4 * i)
        return result

    @classmethod
    def unpack(cls, value: int) -> "State":
        bounded(value, 0, (1 << 110) - 1, "packed state")
        result = cls(
            value & 511,
            (value >> 9) & 511,
            (value >> 18) & 511,
            (value >> 27) & 15,
            ((value >> 31) & 127) - 45,
            tuple((value >> (38 + 4 * i)) & 15 for i in range(9)),
            tuple((value >> (74 + 4 * i)) & 15 for i in range(9)),
        )
        result.validate()
        return result

    def features(self) -> list[int]:
        self.validate()
        result = [
            255 * ((mask >> i) & 1)
            for mask in (self.own_hand, self.opponent_hand, self.loot)
            for i in range(9)
        ]
        result += [255 * (i + 1 == self.current) for i in range(9)]
        magnitude = (abs(self.difference) * 255 + 22) // 45
        result.append(-magnitude if self.difference < 0 else magnitude)
        result += [(card * 255 + 4) // 9 for card in (*self.own_history, *self.opponent_history)]
        return result


@dataclass(frozen=True)
class Context:
    chain_id: int
    contract_address: int
    match_id: int
    player_id: int
    round: int
    seed: int

    def validate(self) -> None:
        bounded(self.chain_id, 0, (1 << 64) - 1, "chain id")
        bounded(self.contract_address, 0, (1 << 160) - 1, "contract address")
        field(self.match_id)
        bounded(self.player_id, 0, 1, "player id")
        bounded(self.round, 0, 8, "round")
        field(self.seed)


@dataclass(frozen=True)
class Model:
    w: tuple[int, ...]
    b: tuple[int, ...]

    def __post_init__(self):
        object.__setattr__(self, "w", tuple(self.w))
        object.__setattr__(self, "b", tuple(self.b))
        if len(self.w) != NW or len(self.b) != NB:
            raise ValueError("model parameter dimensions")
        for w in self.w:
            bounded(w, 0, 255, "encoded weight")
        for b in self.b:
            bounded(b, 0, (1 << 32) - 1, "encoded bias")

    def packed_weights(self) -> list[int]:
        return [
            int.from_bytes(bytes(self.w[start : start + 31]), "little")
            for start in range(0, NW, 31)
        ]

    @cached_property
    def digest(self) -> int:
        return hash_fields([201, SPEC_VERSION, *self.packed_weights(), *self.b])

    def commitment(self, key: int, salt: int) -> int:
        field(key)
        field(salt)
        if key == 0:
            raise ValueError("zero sampling key")
        return hash_fields([202, SPEC_VERSION, self.digest, key, salt])


def requantize(acc: int, maximum: int) -> int:
    bounded(acc, -(1 << 40), (1 << 40) - 1, "shifted accumulator")
    return min(maximum, (max(acc, 0) + 128) // 256)


def dense(
    inputs: list[int], model: Model, width: int, weight_offset: int, bias_offset: int
) -> list[int]:
    size = len(inputs)
    outputs = []
    for neuron in range(width):
        start = weight_offset + neuron * size
        acc = model.b[bias_offset + neuron] - BIAS_OFFSET
        acc += sum((model.w[start + i] - 128) * x for i, x in enumerate(inputs))
        if abs(acc) >= 1 << 32:
            raise ValueError("network accumulator exceeds analytic bound")
        outputs.append(acc)
    return outputs


def forward(model: Model, state: State) -> dict:
    x = state.features()
    z1 = dense(x, model, 128, 0, 0)
    h1 = [requantize(z, 255) for z in z1]
    z2 = dense(h1, model, 128, 7040, 128)
    h2 = [requantize(z, 255) for z in z2]
    z3 = dense(h2, model, 9, 23424, 256)
    raw_tickets = [requantize(z, 65535) for z in z3]
    tickets = [t if state.own_hand & (1 << i) else 0 for i, t in enumerate(raw_tickets)]
    if not any(tickets):
        tickets[(state.own_hand & -state.own_hand).bit_length() - 1] = 1
    return {
        "features": x,
        "z1": z1,
        "h1": h1,
        "z2": z2,
        "h2": h2,
        "z3": z3,
        "raw_tickets": raw_tickets,
        "tickets": tickets,
    }


def sampling_hash(key: int, context: Context) -> int:
    context.validate()
    field(key)
    if key == 0:
        raise ValueError("zero sampling key")
    return hash_fields(
        [
            203,
            SPEC_VERSION,
            key,
            context.chain_id,
            context.contract_address,
            context.match_id,
            context.player_id,
            context.round,
            context.seed,
        ]
    )


def categorical(tickets: list[int], random_u64: int) -> tuple[int, int, int]:
    if len(tickets) != 9:
        raise ValueError("ticket dimensions")
    for t in tickets:
        bounded(t, 0, 65535, "ticket weight")
    bounded(random_u64, 0, (1 << 64) - 1, "random value")
    total = sum(tickets)
    if total == 0:
        raise ValueError("empty distribution")
    ticket = random_u64 % total
    cumulative = 0
    for action, mass in enumerate(tickets):
        cumulative += mass
        if ticket < cumulative:
            return action, ticket, total
    raise AssertionError("unreachable cumulative sum")


def infer(model: Model, state: State, context: Context, key: int, salt: int) -> dict:
    context.validate()
    state.validate()
    if context.round != state.round:
        raise ValueError("context/state round mismatch")
    trace = forward(model, state)
    random_hash = sampling_hash(key, context)
    random_u64 = random_hash & ((1 << 64) - 1)
    action, ticket, total = categorical(trace["tickets"], random_u64)
    trace.update(
        model_digest=model.digest,
        commitment=model.commitment(key, salt),
        sample_hash=random_hash,
        random_u64=random_u64,
        ticket=ticket,
        total=total,
        action=action,
    )
    return trace


def public_inputs(state: State, context: Context, trace: dict) -> list[int]:
    return [
        trace["commitment"],
        state.pack(),
        context.chain_id,
        context.contract_address,
        context.match_id,
        context.player_id,
        context.round,
        context.seed,
        trace["action"],
    ]
