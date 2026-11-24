# Game economics

Tournament entrants deposit equal ETH principals. The controller wraps ETH to WETH, deposits the locked roster's funds into an ERC-4626 vault, and holds the shares until settlement. It then gives each eligible entrant vault shares to redeem or transfer independently. There is no completion bond or central cash redemption.

Giving transferable shares to entrants at registration would let them redeem before deductions became enforceable. The tournament therefore retains custody during play. A player can leave for a full cash credit until the roster locks, including after admissions close.

## Charges and prizes

| Event | Effect |
|---|---|
| Model replacement | Deduct `floor(originalPrincipal / 10)` once per allowed update window |
| Ordinary loss through the quarterfinals | Deduct `floor(originalPrincipal / 40)` (2.5%) |
| Ordinary semifinal, final or third-place loss | No loss tax |
| Concession or move default | Forfeit the entire remaining principal entitlement |
| Prize distribution | 5% of the gross prize pool goes to the fee collector; the rest uses 50/30/20 |
| Oracle request | Caller pays the quoted fee separately; no principal deduction |

The pool consists of yield, update deductions, loss taxes and forfeited principal, as valued at settlement. Returned principal is excluded from the 5% fee. Missing prize places are omitted and remaining weights rescaled. Prize rounding goes to the highest filled place. Managed matches do not also charge a PvP fee.

A tournament tiebreak loss counts as an ordinary loss. Tied scores use the highest captured prize; only an all-burn game uses the seed-derived coin. Walkovers and defaults do not add a loss tax; a default already forfeits the entrant's remaining entitlement. Previously deducted amounts are not charged again.

Updates close after the round of 16. There is one replacement per advancing entrant per window: at most seven in a locked 1,024-player bracket, costing at most 70% of original principal. There is no separate two-update cap. In single elimination an entrant can incur at most one taxable ordinary loss; the top four's remaining losses are exempt.

For a full N-player event with normal results, `N - 4` entrants pay the loss tax. With principal P divisible by 40, that contributes 0.30 P at 16 entrants and 25.5 P at 1,024, before vault losses. A player making no update and losing before the semifinals retains 97.5% of their principal entitlement before vault losses and rounding.

## Settlement in shares

Let N be entrants, P original principal, S this tournament's shares and d_i entrant i's total deductions. Forfeited entrants receive zero. Settlement freezes a valuation; later changes in the vault's share price do not change the share allocation.

For a positive principal P and a usable `previewRedeem(S)` quote V, let `scale = min(V, N*P)`. Each eligible entrant retains this base value:

`base_i = floor(max(P - d_i, 0) * scale / (N*P))`.

Free tournaments (P = 0) have no deposited shares or payouts; the division above does not apply.

The gross pool is `V - sum(base_i)`. Five percent is deducted once as the fee; filled places split the rest 50/30/20. Each value converts to shares proportionally, rounding down. On normal completion, conversion dust goes to the lowest eligible registration slot. `finalize` or a post-play `abort` completes the calculation in one transaction: one scan of at most 1,024 entrants totals retained bases and their rounded share conversions, then fixed payout parameters record the split and remaining dust. Claims recompute each allocation from those frozen parameters; there is no later valuation or incremental settlement batch. Every share unit is accounted for:

`sum(entrant share entitlements) + fee shares + unowned shares == S`.

Nothing guarantees principal. If the vault quote is below total principal, everyone's deposited value shares that shortfall before deductions. Forfeited principal shares the same loss; it does not retain its face value at other entrants' expense. If the vault quote exceeds principal, the excess joins the prize pool.

For example, four entrants deposit 1 ETH each, one forfeits, none updates, and the position is quoted at 4.04 ETH. Three eligible entrants each retain a 1 ETH base. The 1.04 ETH pool pays a 0.052 ETH fee, leaving prizes valued at 0.494 / 0.2964 / 0.1976 ETH. These are converted to shares at settlement, not promised as cash. Four-player ordinary losses are exempt from the loss tax because every match is a semifinal, final or playoff.

A quote is usable only when `0 < V < 2^128` and `S < 2^128`. If the quote fails, returns malformed data or falls outside these bounds, settlement instead treats the shares themselves as the accounting unit: `V = scale = S`. The same deductions and prize split apply proportionally to that position. No yield is invented or separately allocated in this path. The quote call has a fixed gas allowance and a caller gas check to prevent choosing the fallback by deliberately starving the quote. A quote is still only a valuation, not a guarantee that redemption will succeed.

For normal completion with no filled prize places but eligible entrants remaining, the net pool is an equal bonus, with the remainder to the lowest eligible slot. Aborts use the distinct rules below. If everyone forfeited, there is no fee and all shares remain unowned in the controller. There is no administrator recovery right over that allocation.

Share claims check both sides' balance changes. A failed transfer does not consume the claim. A vault pause that blocks transfers can delay claims; receiving shares cannot bypass the vault's own restrictions. Once received, subsequent yield, losses and redemption decisions belong to the recipient.

## Cancellation and oracle failure

Before funding, the creator may cancel an underfilled roster only after its entry deadline. Anyone may cancel a locked roster after its funding deadline. Both paths refund original principal. These refunds use `claim` to create a WETH-backed cash credit, then `withdraw` unwraps it to ETH. Leaving before lock also creates such a credit. No winnings fee applies.

After funding, a tournament may abort only when a draw expires or nobody pays for the next draw within the fixed request grace period. A ready result cannot be cancelled merely by waiting. There is no replacement draw. Abort settles in shares with no places:

- Before the first round starts, each entrant receives `floor(S / N)` shares; the lowest registration slot receives the remaining dust. Equal deposits thus receive proportional shares of the actual vault position, including any yield or loss. No valuation call or winnings fee is needed. This is not a guarantee of original cash principal.
- After play, every non-forfeited entrant retains the base calculated from their confirmed deductions and the settlement valuation. Only surviving contenders split the net pool equally, after its existing 5% fee. Eliminated entrants receive no pool bonus. Pool/conversion dust goes to the lowest surviving registration slot. Forfeits and update/loss deductions are not undone.
- If no contenders survive, non-forfeited eliminated entrants still receive their remaining base. The undistributable pool and conversion dust remain unowned in the controller, with no fee and no administrator recovery right. No eliminated player is promoted to a prize recipient by an abort.

Aborts are permitted only between rounds or while their draw is pending. The stored round is the last completed round and an eligible entrant survives exactly when `reached > round`; the initial window/draw has round zero. Aborting during a partially completed active round remains forbidden. Oracle fees already paid are not refunded. These are the current source rules; verify the code and provenance of the selected deployment.

Expiry is not proof of permanent oracle failure. Suppressing an unfavorable delivery until expiry can force an abort. The recovery path prevents indefinite escrow but does not eliminate that selective-abort risk.

## PvP and the fee collector

Ordinary PvP wagers remain liquid ETH; they do not use the vault. A winner receives their own stake plus the opponent's stake minus `floor(opponentStake / 20)`. With two 1 ETH stakes, the winner receives 1.95 ETH and the collector receives 0.05 ETH. This also applies to a concession or one-sided move timeout. A draw or expired-oracle cancellation refunds both stakes without a winnings fee. Double move default makes both stakes unclaimable, with no beneficiary.

Fee entitlements are recorded independently of collection. Anyone may trigger the collector to pull its Arena credit or tournament share fee. Only its owner may withdraw those collected funds. A failed collection cannot block game settlement. Claiming or withdrawing already-net awards does not charge a second fee.

## Accounting and incentives

Each tournament owns a separate recorded share amount. Its deductions redistribute its own position; they do not burn or reduce another tournament's shares. A loss in the underlying vault can reduce the redemption value of every shareholder's position, including unrelated depositors. Accounting isolation is not protection against a shared vault loss.

Liquid WETH credits and owed vault shares have different units and are tracked separately. Never add them as if they were one balance. The recorded original share amount is retained after claims for reproducible entitlement calculations.

Short events earn little lending interest, so taxes and updates may contribute more than yield. Rewarding forfeits gives competitors an incentive to cause defaults; censorship, unreliable clients, collusion and multiple-address entries remain risks. The loss tax adds a modest cost to deliberate losing but does not prevent collusion. Creators should choose practical move windows and make all charges visible before entry.

The vault, Chainlink subscription, request price and fee recipient are deployment configuration.
