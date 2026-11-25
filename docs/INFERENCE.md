# Inference specification

Felony uses the fixed architecture, integer arithmetic, state encoding, commitments, sampling rules and proof inputs defined here. Python, Noir, the verifier and clients must implement the same rules. Training changes the weights, while the architecture and inference rules remain fixed.

Conformance establishes inference correctness, not training quality.

## Scope and statement

The proof statement:

> The private parameters and sampling key behind the registered commitment, evaluated on the supplied pre-round state with the algorithm below, select the public action.

Weights are fixed per match; training happens offchain. The contracts handle seed selection, state transitions and ranking; the circuit checks a single inference result.

The contract must:

- pin the verifier,
- lock model commitments before unpredictable match entropy is revealed,
- construct all public inputs from authoritative storage,
- freeze the same pre-round observation for both players,
- check turn/round authorization, and
- reject stale submissions.

The circuit checks state consistency but cannot establish that a supplied state/context is the live onchain one. Submissions are public and sequential; both players are bound to their committed model and the same pre-round observation.

## ABI

### Private inputs

In order:

| Input | Type | Constraint |
|---|---|---|
| `w` | `[u8; 24576]` | weights |
| `b` | `[u32; 265]` | biases |
| `key` | `Field` | nonzero |
| `salt` | `Field` | may be zero for reproducible tests |

### Public inputs

In order (nine field words):

| Input | Type | Constraint |
|---|---|---|
| `commitment` | `Field` | registered model commitment |
| `state` | `Field` | pre-round state (see [State](#state)) |
| `chain_id` | `u64` | |
| `contract_address` | `Field` | 160 bits |
| `match_id` | `Field` | |
| `player_id` | `u8` | 0 or 1 |
| `round` | `u8` | 0..8 |
| `seed` | `Field` | |
| `action` | `u8` | 0..8 |

Action index `i` means bid card `i+1`. Field inputs are canonical BN254 scalar-field elements.

## State

Little-endian bit offsets:

| Offset | Width | Meaning |
|---|---|---|
| 0 | 9 | own remaining cards, bit i = card i+1 |
| 9 | 9 | opponent remaining cards |
| 18 | 9 | remaining loot, including current loot |
| 27 | 4 | current loot value 1..9 |
| 31 | 7 | own score minus opponent score +45, 0..90 |
| 38 | 36 | own bid for each loot value; nine 4-bit nibbles, lowest = loot1 |
| 74 | 36 | opponent bid for each loot value |

### State validation

- State must fit 110 bits.
- Both hand counts and the loot count equal `9 - round` and are nonzero.
- Current loot belongs to the remaining loot mask.
- Every remaining loot entry has both history bids zero; every removed loot entry has both bids in 1..9.
- Each player's nonzero historical bids are unique and exactly complement that player's remaining hand.
- Recompute the score difference: for each removed loot value `v`, add `v` if `own_bid > opponent_bid`, subtract `v` if less, otherwise add zero. This must equal the encoded score difference.

Thus no independently supplied legal-action mask is accepted. Historical ordering and future loot ordering are not inputs.

## Features

The observation is encoded as 55 integers:

| Indices | Encoding |
|---|---|
| 0..8 | own hand: each bit maps to 0 or 255 |
| 9..17 | opponent hand: each bit maps to 0 or 255 |
| 18..26 | remaining loot: each bit maps to 0 or 255 |
| 27..35 | one-hot current loot, values 0 or 255 |
| 36 | `sign(diff) * floor((abs(diff)*255 + 22) / 45)`, hence -255..255 |
| 37..45 | own history: `floor((bid*255 + 4) / 9)` |
| 46..54 | opponent history: same rule |

These are integer nearest rounding; denominators 45 and 9 are odd, so exact half cases do not arise. Do not replace the signed score with its positive offset.

## Neural network

### Architecture and storage

Fixed fully connected architecture: 55 → 128 → 128 → 9.

Weights are stored layer-by-layer, output-neuron-major then input index:

| Layer | Weight offset |
|---|---|
| 1 | 0 |
| 2 | 7040 |
| 3 | 23424 |

| Layer | Bias offset |
|---|---|
| 1 | 0 |
| 2 | 128 |
| 3 | 256 |

Decoding:

- weight `w` decodes as `w - 128`,
- bias `b` decodes as `b - 2147483648`.

There are 24,576 weights and 265 biases (24,841 parameters). No runtime search or other model is executed.

### Evaluation

For each neuron:

```text
acc = decoded_bias + sum(decoded_weight * integer_input)
```

Python uses signed integers; Noir uses Field arithmetic with range constraints.

Bounds on inputs and parameters give `abs(acc) <= 2^31 + 128*255*128 < 2^32`, so a bounded signed interpretation is unique in BN254. Noir validates `acc + 2^40` in 41 bits before conversion to integer/sign comparisons; both endpoints and integer arithmetic must remain constrained.

### Activations

- Hidden activations: `min(255, floor((max(acc, 0) + 128) / 256))`.
- Output ticket rule: `min(65535, floor((max(acc, 0) + 128) / 256))`.

No softmax. This is a different model from a float softmax policy; training and export must reproduce this rule and validate quality.

## Hashes and commitments

### Poseidon2

Use `noir-lang/poseidon` tag v0.4.0:

```text
Poseidon2::hash(values, values.len())
```

- BN254 scalar field, width 4 / rate 3, IV = `len << 64` as that library specifies.
- Each hash uses a fixed compile-time input length.

### Input prefixes

The hash input prefixes are fixed and are numeric field elements, not text strings or player-selected settings:

| Prefix | Used for |
|---|---|
| `[201, 1]` | model digest |
| `[202, 1]` | commitments |
| `[203, 1]` | sampling |

### Weight packing

Pack weights into 793 fields:

```text
packed[j] = sum(w[31*j + k] * 256^k for k = 0..30, where index < 24576)
```

The final group is padded with zero high bytes. `256^31 <` field modulus, so packing is injective for the fixed length.

### Digests

| Value | Hash input | Length |
|---|---|---|
| `model_digest` | `[201, 1] ++ packed_weights ++ encoded_biases` | 1060 |
| `commitment` | `[202, 1, model_digest, key, salt]` | 5 |
| `sample_hash` | `[203, 1, key, chain_id, contract_address, match_id, player_id, round, seed]` | 9 |

### Key and salt

- The key and salt must be securely generated offchain in real use; range and nonzero checks cannot prove entropy. Do not reuse deterministic test secrets in real matches.
- Commitment registration freezes both key and weights.
- Key is nonzero; salt may be zero for reproducible tests.

## Mask and sample

1. Set tickets for unavailable cards to zero.
2. If the total is zero, set the lowest legal card's tickets to 1. The effective total is now 1..589815, which is below 2^20.

Decompose `sample_hash` canonically as a full 254-bit field integer, including its less-than-modulus condition. Take its least significant 64 bits as `R`. Do **not** constrain the entire hash to 64 bits. Then:

```text
r = R % total    (integer remainder)
```

Enforce bounded arithmetic, `r < total`, and the division relation if using quotient hints.

Modulo sampling has negligible, not zero, bias: for an ideal uniform 64-bit source its total-variation distance is at most `total / (4*2^64) < 8.0e-15`. Truncating a uniform field element adds a negligible finite-field imbalance; cryptographic pseudorandomness is an assumption.

Visit card indices ascending 0..8. Select the unique action with `cumulative_before <= r < cumulative_before + tickets[action]`. This also excludes zero-ticket and illegal bids.

No nonce, retry choice, owner-selected random value, optional model switch or update can influence sampling. Sampling context includes round, match, player and deployment, but is not a neural-network feature.

## Implementations

- Python implements integer inference in `model/felony/inference.py`.
- Noir implements the same rules in `circuit/src/`.
- Python delegates Poseidon2 to Barretenberg; binary configuration is covered in the repository README.
