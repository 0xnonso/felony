from dataclasses import asdict
import json
import random

from .inference import BIAS_OFFSET, NB, NW, Context, Model, State, infer, public_inputs


def synthetic_model(seed: int = 7, mode: str = "dense") -> Model:
    if mode == "zero":
        return Model((128,) * NW, (BIAS_OFFSET,) * NB)
    if mode == "maximum":
        return Model((255,) * NW, ((1 << 32) - 1,) * NB)
    if mode == "minimum":
        return Model((0,) * NW, (0,) * NB)
    if mode != "dense":
        raise ValueError("unknown fixture model")
    rng = random.Random(seed)
    weights = tuple(rng.randrange(96, 161) for _ in range(NW))
    biases = tuple(BIAS_OFFSET + rng.randrange(-24000, 24001) for _ in range(NB))
    return Model(weights, biases)


def legal_states(seed: int = 19) -> list[State]:
    rng = random.Random(seed)
    prizes = list(range(1, 10))
    mine = prizes.copy()
    other = prizes.copy()
    rng.shuffle(prizes)
    rng.shuffle(mine)
    rng.shuffle(other)
    own_history, opponent_history = [0] * 9, [0] * 9
    own_hand = opponent_hand = loot = 511
    difference = 0
    states = []
    for prize, a, b in zip(prizes, mine, other):
        states.append(
            State(
                own_hand,
                opponent_hand,
                loot,
                prize,
                difference,
                tuple(own_history),
                tuple(opponent_history),
            )
        )
        own_hand ^= 1 << (a - 1)
        opponent_hand ^= 1 << (b - 1)
        loot ^= 1 << (prize - 1)
        own_history[prize - 1], opponent_history[prize - 1] = a, b
        difference += prize * ((a > b) - (a < b))
    return states


def build_vectors() -> dict:
    definitions = {
        "dense7": synthetic_model(7),
        "dense29": synthetic_model(29),
        "zero": synthetic_model(mode="zero"),
        "maximum": synthetic_model(mode="maximum"),
        "minimum": synthetic_model(mode="minimum"),
    }
    cases = []

    selections = [("dense7", 19, r) for r in (0, 1, 3, 6, 8)]
    selections += [("dense29", 23, r) for r in (0, 2, 5, 7)]
    selections += [(mode, 19, 3) for mode in ("zero", "maximum", "minimum")]

    selections += [("dense7", seed, r) for seed, r in ((2, 2), (3, 1), (4, 1), (6, 1))]
    selections += [("dense29", seed, r) for seed, r in ((53, 4), (79, 5))]
    for index, (model_name, game_seed, round_index) in enumerate(selections):
        state = legal_states(game_seed)[round_index]
        context = Context(
            31337, 0x123456789ABCDEF, 100 + index, index % 2, round_index, 0xCAFE123456789 + index
        )
        key, salt = 0xDEADBEEF123456789 + index, 0xABCDEF + index
        trace = infer(definitions[model_name], state, context, key, salt)

        cases.append(
            {
                "name": f"{model_name}_game{game_seed}_round{round_index}",
                "model": model_name,
                "state": str(state.pack()),
                "context": {k: str(v) for k, v in asdict(context).items()},
                "key": str(key),
                "salt": str(salt),
                "expected": {
                    k: [str(x) for x in v] if isinstance(v, list) else str(v)
                    for k, v in trace.items()
                },
                "public_inputs": [str(v) for v in public_inputs(state, context, trace)],
            }
        )
    models = {name: {"w": list(model.w), "b": list(model.b)} for name, model in definitions.items()}
    return {
        "spec_version": 1,
        "warning": "Public synthetic test models and secrets; not trained agents.",
        "models": models,
        "cases": cases,
    }


def prover_toml(data: dict, case: dict) -> str:
    model = data["models"][case["model"]]
    values = {
        "w": model["w"],
        "b": model["b"],
        "key": case["key"],
        "salt": case["salt"],
        "commitment": case["expected"]["commitment"],
        "state": case["state"],
        **case["context"],
        "action": case["expected"]["action"],
    }
    return (
        "# PUBLIC SYNTHETIC TEST WITNESS; NOT A REAL PLAYER MODEL\n"
        + "\n".join(f"{k} = {json.dumps(v)}" for k, v in values.items())
        + "\n"
    )
