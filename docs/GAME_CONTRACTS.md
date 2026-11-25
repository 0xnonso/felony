# Game contracts

The Arena executes individual matches. The tournament runs a single-elimination bracket with a third-place playoff and accounts for deposits. Oracle requests supply randomness after commitments lock.

| Contract | Responsibility |
|---|---|
| `Felony` (`lib.fe`) | PvP invites and queue, proof-checked moves, timeouts and managed matches |
| `FelonyTournament` (`tournament.fe`) | Registration, draws, update windows, bracket and share claims |
| `ChainlinkRandomOracle` (`oracle.fe`) | Chainlink VRF v2.5 requests, authenticated callbacks and expiry |
| `FeeCollector` (`fees.fe`) | Collect earned fees; owner withdraws those fees |
| `UltraHonkVerifier` (generated) | Verify this circuit's inference proofs |
| Configured external ERC-4626 vault | Hold WETH deposits and issue transferable vault shares |

Game configuration addresses are immutable. The oracle sponsor manages its consumer allowlist and subscription. The fee collector owner controls collected fees, not player principal. This guide describes the current source, not a live deployment. Verify the configured addresses, bytecode and ABI provenance before using an immutable deployment.

## Dependencies

- Arena requires deployed verifier and oracle code.
- The tournament requires deployed Arena, WETH and oracle code, and an ERC-4626 vault whose `asset()` matches WETH.
- Addresses and ABI shape alone do not authenticate those implementations.
- The fee recipient may be any nonzero address because settlement records a credit rather than calling it.
- Deployments assume the chain ID fits the circuit's `u64` input.

## Modules

- `types.fe`, `events.fe` and `interfaces.fe` hold shared definitions.
- `rules.fe` implements the game; `bracket.fe` and `merkle.fe` implement the bracket.
- `settlement.fe` is pure accounting code compiled into the tournament, not a separately deployed contract.
- `vault.fe` checks ERC-4626 deposits and share transfers.
- Internal state uses enums; numeric codes are for external views and events.

### Entry accounting

Entries retain an eligibility status, a claim flag, cumulative deductions and the next round they reached:

- Ordinary elimination preserves eligibility to claim the remaining principal.
- Concession or a move timeout forfeits that entitlement.
- A match that ends by default records no losing seat, so a forfeited entrant is never re-seated: the playoff pairs only non-default semifinal losers, including tie-break losers, treating a defaulted loser as an empty seat.
- Defaults in the playoff forfeit those entries and settlement proceeds.
- The controller freezes compact payout parameters at settlement so claims cannot depend on later vault-price changes.

### Reentrancy guard

Arena, tournament and oracle use one shared `std::evm::mutex::Mutex<()>` reentrancy guard per contract. The guard blocks protected entry points during external-call windows and is explicitly released afterwards so sequential calls in one transaction remain possible. Its lock uses EIP-1153 transient storage; game state, balances and participation records remain persistent. These contracts require an EVM with transient-storage support (included in the Osaka target).

## PvP

Arena constructor: `(verifier, oracle, feeCollector, turnSeconds)`, with moves lasting 60–86,400 seconds. Each stake must be at most `(2^256 - 1) / 2` so the two-player pot fits a `u256`.

1. `createChallenge(opponent, commitment, stake, joinSeconds)` escrows exactly the stake. `joinChallenge(id, commitment)` is restricted to the invited player and requires the stake **plus the oracle's quoted fee**.
2. `joinQueue(commitment, stake)` either escrows the stake as the waiting player or matches the existing queue head and pays stake plus oracle fee. There is one waiting slot per stake amount, with a one-hour expiry. Expired heads are refunded when the next entrant arrives. This is not random matchmaking; a player can choose a favorable queue head.
3. Joining locks both commitments and requests randomness atomically. `randomnessRequest(id)` identifies that request. Anyone calls `activateMatch(id)` after delivery to store the match seed and start the first move deadline.
4. Both players submit proofs against the same pre-round board. The second accepted move resolves that round. Eight rounds require **16 proofs**; the forced ninth round resolves automatically.
5. Settlement creates withdrawal credits. A winner receives both stakes minus 5% of the opponent's stake. Draws refund both stakes. The fee collector receives the fee as its own credit.

### Cancellation

- The creator can cancel an unaccepted invitation or queue entry at any time, including at its join deadline. After the deadline, anyone can cancel it.
- Cancellation credits the creator's full stake for withdrawal, immediately clears their busy flag and removes their waiting queue slot; zero-stake entries follow the same lifecycle.
- The invited opponent and unrelated callers cannot cancel before expiry.
- Cancellation and acceptance are ordered by the chain: if cancellation executes first, joining reverts; if joining executes first, cancellation reverts because the match is no longer invited.
- No oracle request or fee is incurred by cancellation.

### Concession and timeouts

- A participant may concede while awaiting randomness or through the exact current move deadline.
- Concession and one-sided move timeout award the opponent the win.
- After the move deadline, anyone calls `claimTimeout`: neither player submitting means both default and both stakes remain unclaimable in `burned()`. There is no completion bond.
- If the oracle request expires before delivery, `claimTimeout` instead cancels the pending game and refunds both stakes. The paid oracle fee is not returned. A ready result never expires, so waiting cannot turn it into a cancellation.
- One address can be busy in only one ordinary PvP game; managed tournament matches are separate.

## Tournament lifecycle

Constructor: `(arena, vault, weth, oracle, feeCollector)`. The vault's `asset()` must equal WETH.

1. `createTournament(capacity, principal, entrySeconds, fundSeconds, windowSeconds, turnSeconds)` fixes the terms. Capacity is a power of two from 4 to 1,024. The full capacity's principal must fit a `u256`: `principal <= (2^256 - 1) / capacity`. Registration lasts 60 seconds–30 days, funding 1 hour–7 days, update windows 60 seconds–24 hours, and moves 60 seconds–24 hours. The caller selects the update window explicitly.
2. `join(id, commitment)` deposits exactly the ETH principal and wraps it to WETH. Admissions close automatically after the timestamp deadline. Filling the roster locks it automatically. Otherwise, after the deadline the creator may `start(id)` with at least 16 entrants or `cancel(id)` for refunds. Entrants may `leave(id)` until lock, even after admissions close. A full 4- or 8-player event remains supported.
3. The locked bracket is the smallest power of two covering the actual count. Locking also reserves its Arena match IDs before funding or randomness. `fund(id)` deposits the total principal into the vault by the funding deadline. Failed deposits are retryable; after that deadline anyone may cancel for refunds. Zero-principal events skip funding.
4. Anyone pays `quoteFee()` separately through `requestDraw(id)`. The initial request can be made immediately after funding or a zero-principal roster lock. A request must be made within `fundSeconds` of the draw window closing. Principal never pays this fee.
5. After delivery, anyone calls `beginRound(id)`. The first call builds the shuffled Merkle root in one transaction. Later calls activate the next round using its stored oracle result. No player reveal or blockhash capture is needed.
6. Anyone proves a first-round pair through `openMatch(id,index,slot0,slot1,siblings[9])`. `advance(id,index)` opens later-round matches or records finished Arena results. A match with one empty seat is a walkover. With two empty seats it resolves empty. Both still need progression calls.
7. The next round waits for every match in the current round to resolve. Where an update window remains, it opens when the last result is recorded. Otherwise the next round activates immediately. The final and third-place playoff share the last round.
8. Once both last-round matches resolve, anyone calls `finalize(id)`. It fixes payouts in vault shares. Eligible entrants `claim(id)` those shares and redeem or transfer them themselves. There is no central redemption or `FallbackToShares` path. Unfunded cancellations instead create ETH withdrawal credits through `claim`, then `withdraw(to)`.

Progression calls are permissionless. A missed Arena deadline requires `claimTimeout` before tournament `advance`.

## Updates and round draws

For the locked bracket capacity, `R = log2(capacity)`, there are `max(1, R - 2)` draws:

- The first supplies both the bracket and first-round seeds under separate hash domains.
- The quarterfinal draw supplies all later match seeds because commitments can no longer change.
- A 1,024-player event therefore uses eight requests and offers seven update windows; 4- and 8-player events offer none.

### Model updates

- `updateModel(id, commitment)` is allowed once per window for an eligible player who reached the next round.
- It deducts `floor(originalPrincipal / 10)` from that entrant's principal entitlement.
- The last window follows the round of 16.
- Updates stop at the deadline, even if nobody has requested the next draw yet.
- Unchanged models need no transaction.

The contract validates the new commitment, not the training method or whether the model improved. The next move proof must match the new commitment under the same fixed architecture. Each Arena match copies both commitments when it opens; an entry update cannot change an existing match. Clients should validate exports and test proving before committing.

### Abort

An expired request, or failure to request within its fixed grace period, allows `abort(id)`. There is no replacement draw.

- Before play, aborted tournaments refund proportional vault shares without a winnings fee.
- After play, all non-forfeited entrants retain their remaining principal entitlement, while only surviving contenders share the net pool without places; see [economics](GAME_ECONOMICS.md).
- A ready request cannot be aborted merely because time passed.
- Timeout recovery does allow a party able to suppress delivery to force an abort.

## Randomness

`ChainlinkRandomOracle` uses [Chainlink VRF v2.5 subscriptions](https://docs.chain.link/vrf/v2-5/overview/subscription). Felony adds these rules:

- Only allowlisted consumers can request, paying exactly `quoteFee()` in native ETH. This adapter fee is separate from the subscription charge and never comes from escrowed principal. Immutable `nativePayment` selects native-token or LINK subscription billing.
- Each consumer/context pair can request only once, even after expiry. The adapter stores one word; zero is valid. Status is pending `1`, ready `2` or expired `3`; unknown IDs revert.
- Delivery is accepted through `request timestamp + timeoutSeconds`, inclusive. Undelivered requests expire after that deadline; late and duplicate callbacks revert. A ready word is permanent.
- Fulfillment stores the result only. Arena `activateMatch` or tournament `beginRound` separately advances play. Ready results have no timed cancellation, and expired requests have no replacement draw.

The sponsor controls future consumer authorization; revocation does not block existing requests. Subscription funding and delivery remain availability dependencies. Refunds and abort allocations are defined in [economics](GAME_ECONOMICS.md#cancellation-and-oracle-failure).

## Seeds, proofs and bracket encoding

Arena supplies all nine verifier inputs from stored state:

```text
[commitment, packedState, chainId, arenaAddress, matchId, playerId, round, seed, action]
```

### Managed match IDs

- Each tournament reserves a contiguous range of Arena IDs when its roster locks.
- The range contains `capacity` IDs: `first + index`, where index 0 is the third-place playoff and indices 1 through `capacity - 1` are the bracket matches.
- This is one reservation record; it does not initialize matches or start deadlines.
- Walkovers leave their IDs unused. Cancelled tournaments never recycle their IDs.

The Arena exposes `reserveManagedMatches(tournament,count)` and `managedMatchId(manager,tournament,index)`. A manager can reserve only once per tournament. `createManagedMatch(player0,player1,commitment0,commitment1,tournament,seed,turnSeconds,index)` opens that manager's reserved position only once. Unrelated PvP games, other managers and match-opening order cannot change its ID.

Fixing IDs before the draw prevents owners from choosing a different sampling context after seeing randomness. The Arena permits independent managers; each must enforce its own pre-randomness reservation rule.

### Seed binding

The seed is an ordinary public input. A proof made for another seed fails against the stored inputs. The private sampler key remains private and committed. All affected commitments must lock before their draw request, preventing selection of weights or keys against known draws.

### Hash domains

Hashes below encode each item as a 32-byte big-endian word, including addresses:

| Purpose | Hash |
|---|---|
| PvP request context | `keccak([520, chainId, arena, matchId, commitment0, commitment1])` |
| PvP seed | `keccak([521, chainId, arena, matchId, oracleWord]) % FIELD` |
| Tournament request context | `keccak([516, chainId, controller, tournamentId, draw])` |
| Bracket seed | `keccak([512, chainId, controller, tournamentId, count, capacity, firstWord])` |
| Managed match seed | `keccak([517, chainId, controller, tournamentId, matchIndex, roundWord]) % FIELD` |
| Fisher–Yates choice | `keccak([505, bracketSeed, remainingCount]) % remainingCount` |
| Merkle context | `keccak([515, chainId, controller, tournamentId, bracketSeed, count, capacity])` |
| Merkle leaf | `keccak([513, context, zeroBasedPosition, storedSlot])` |
| Merkle parent | `keccak([left, right])`, matching Fe's standard indexed Merkle helper |

### Shuffle and Merkle tree

- The shuffle uses one-based entrant slots, with zero for vacancies.
- Vacancies are spread across first-round matches so two byes are never paired together.
- The bracket stores only its root; no shuffled array or Merkle nodes are stored.
- Construction is O(capacity) computation in a single transaction.
- Finalization separately scans at most 1,024 entries to assign every share unit exactly.
- These are bounded loops, not constant-cost operations.

For first-round heap index `i`, leaves are at positions `2*(i-capacity/2)` and the next position. Pair them, then apply leaf-to-root siblings in heap order. Fe's `std::evm::merkle::verify_indexed` checks this ordered proof, not the sorted-pair variant. Leaves hash 128 bytes and internal nodes hash 64 bytes, so their encodings are distinct. The depth is `log2(capacity)-1`; unused elements of the nine-word ABI must be zero. Index 1 is the final, 2 and 3 are semifinals, and 0 is the playoff.

Use `test_vectors/bracket.json` for the current ordered tree format. Proofs must match this encoding and the stored root; sorted-pair proofs are incompatible.

Anyone can reconstruct pair proofs from `drawWord(id,0)`, count and capacity. Proofs must match the stored bracket root; no designated publisher controls openings.

### Tournament tiebreaks

- Tournament matches first compare total scores.
- If scores tie, the player who captured the highest-value prize wins: check 9, then 8, down to 1, skipping burned prizes.
- Only an all-burn 0–0 game uses `keccak([504, matchSeed]) % 2`.
- The Arena applies the highest-capture rule only to managed matches; the controller applies the remaining coin. This uses the existing locked seed, with no replay or new oracle request.
- A tiebreak loser is an ordinary loser, eligible for the semifinal playoff and taxed only if that round is taxable.
- PvP score ties still refund both stakes, even if either player captured prizes.

## Vault and fees

The standard boundary is ERC-4626 with ERC20 shares:

- Entry and cash withdrawal are ETH/WETH only; another asset requires a corresponding entry path.
- Vaults are deployment-selected, not arbitrary user call targets.
- Deposits use exact approvals, clear them afterwards and measure balance changes.
- Claims check sender and recipient share changes.
- Fee-on-transfer and rebasing assets are unsupported.

Shares stay in tournament custody until settlement so later deductions remain enforceable. A claim transfers ordinary vault shares to the entrant. Paused transfers can delay claims; a failed transfer reverts without consuming the claim. A quoted valuation cannot guarantee redemption or prevent vault losses.

Anyone can call the fee collector's `collectArena(arena)` or `collectTournament(tournament,id)`. Only its owner can withdraw collected ETH or tokens. Fee collection is separate from game completion and never charges a second fee. See [economics](GAME_ECONOMICS.md) for the fee base and rounding.

## Accepted moves and claims

### Arena moves

Arena emits `MoveAccepted(uint256 indexed id,uint256 round,uint256 seat,uint256 action)` once for each accepted `submitMove`, after proof and held-card validation and before round resolution.

- The round is the pre-transition, zero-based board round; seat and action are zero-based.
- The second move retains that same round even when it resolves the round or finishes the match.
- The automatic ninth-round cards do not emit move events.
- Reverted submissions emit no accepted move.

### Tournament claims

Tournament emits `EntryClaimed(uint256 indexed id,uint256 slot)` once at the end of each successful `claim`, including zero-entitlement claims and cancelled-tournament refunds.

- Its slot is zero-based, matching `entryInfo` and `entitlement`, rather than the one-based `slotOf` result.
- Failed or repeated claims emit no claim event.

These events expose public actions and claim state; they contain no private model, sampler or witness data.

## View layouts

Arrays below are listed in ABI order. Slots in bracket records and `slotOf` are one-based; entry-view arguments are zero-based.

| View | Fields |
|---|---|
| Arena `matchInfo` | player0, player1, commitment0, commitment1, stake, reserved zero, phase, deadline, reserved zero, seed, round, submitted mask, score0, score1, result, tournamentId, bid0, bid1 |
| Arena `managedInfo` | manager, default flag, zero, zero |
| Arena `settings` | verifier, verifier code hash, turn seconds, oracle, collector |
| Tournament `tournamentInfo` | phase, capacity, count, principal, entry end, funding deadline, round, stage, window end, request ID, unresolved matches, original shares, forfeits, first slot, second slot, third slot, remainder slot, total rounds |
| `roundInfo` | round, stage, window end, request ID, unresolved matches, total rounds, total draws |
| `entryInfo` | player, commitment, status, claimed, deducted principal, reached round; all zero outside the roster |
| `bracketMatch` | state, winner slot, normal loser slot, Arena match ID |
| `payoutInfo` | valuation, principal scale, first prize shares, second prize shares, third prize shares, bonus shares per recipient (surviving contenders on post-play abort), remainder shares, fee shares, unowned shares |
| `accounting` | liquid WETH liabilities, owed vault shares; different units, never add them |
| Tournament `settings` | Arena, vault, WETH, oracle, collector |
| `tournamentConfig` | creator, requested capacity, funding seconds, update-window seconds, move seconds |

### Numeric codes

These numeric codes and reserved view words are part of the public ABI; clients must not infer them from internal enum ordering.

| Category | Codes |
|---|---|
| Arena phases | invited 1, awaiting randomness 2, playing 3, finished 4, cancelled 5 |
| Arena results | seat0 win 1, seat1 win 2, draw 3, double default 4 |
| Tournament phases | open 1, awaiting funding 2, running 3, settled 4, aborted 5, cancelled 6 |
| Round stages | window 0, drawing 1, active 2 |
| Bracket states | pending 0, inArena 1, resolved 2 |
| Entry status | eligible 1, forfeited 2 |

Zero otherwise denotes uninitialized where applicable.

### View semantics

- `round` counts the active round while matches are playing, and the last completed round during an update window or pending draw.
- `entryInfo.reached` records the next round an entrant reached; deductions are cumulative update charges and ordinary-loss tax in principal units.
- `tournamentInfo.shares` remains the original position, not the remaining balance after claims.
- `entitlement(id,slot)` reports the allocation, not proof that it is still unclaimed; check `entryInfo.claimed`.
- `drawWord(id,draw)` stores each result; draw0 is reserved for the bracket seed.

### Constants and validation

`constants.fe` shares Noir's BN254 scalar modulus across contracts. External commitments are validated and seed hashes reduced modulo it. The circuit's chain ID input remains `u64`.

- The verifier owns proof encoding and length validation; Arena does not duplicate a fixed byte count.
- Arena separately checks that the submitted action is a card still held by that seat.
- Both move proofs bind the same pre-round board; a valid proof does not bypass the hand check.
