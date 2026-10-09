# Threat model

Scope: `contracts/src/*`, the keeper (`scripts/`), and the deploy script. Assets at risk: subscriber USDG (bond leg
and premium), underwriter stock-token collateral, fee reserve, and the correctness of settlement prices.

## Actors and trust

| Actor | Powers | Trust assumption |
|---|---|---|
| Timelock (48h) | All `DEFAULT_ADMIN_ROLE`s: allowlist adapters/stables, oracle feeds, calendar, limits, manual settlement (≥7d after maturity), `setProjectToken` (once), treasury | Proposer is a multisig. Every action is public for 48h before it executes. |
| Guardian | Pause/unpause new activity on each contract; cancel unlocked series | Can delay but cannot take funds. Claims and refunds are never pausable. |
| Curator | Create series within Timelock-set limits, cancel unlocked series | Can create bad terms, which subscribers can see before depositing. Cannot choose adapters outside the allowlist. |
| Keeper (anyone) | `lock`, `settle`, `cancelStale` | Untrusted: prices are proven on-chain, so hints can't be cherry-picked. |
| Subscribers, underwriters, traders | Normal use | Untrusted. |
| External: Chainlink, yield vault, USDG issuer, stock-token issuer, sequencer | Price data, bond leg, settlement asset, collateral asset, ordering | See risks below. |

## Top risks

### 1. Yield-source failure breaks the floor
*Scenario:* the ERC-4626 vault behind the bond leg is hacked, takes bad debt, gets paused, or under-earns the assumed yield. At maturity the bond leg redeems for less than the floor (`notes × protection`).

Mitigations:
- **Default deployment uses `HoldYieldAdapter`** (pure USDG custody: no lending, no counterparty). A real vault requires the Timelock to allowlist a new adapter (48h public notice).
- **Assumed yield is capped** (`maxAssumedYieldBps`, default 10%) and set by the curator with a haircut. Payouts never read a live APY.
- **Segregated per-series shares**: a loss or exploit in one series cannot drain another series' position.
- **Deposit max-loss guard** in `ERC4626YieldAdapter` (default 0.10%) blocks entry-fee, donation and inflation attacks at lock.
- **Shortfall reserve**: 20% of every fee accrues to `FeeCollector.reserve`. `Settlement._settle` automatically draws `min(shortfall, reserve)`. Tested in `test_settle_shortfall_*`.
- **Graceful degradation**: if the reserve is exhausted, holders get their exact pro-rata share of what was recovered (no first-come-first-served race), and the shortfall is recorded on-chain (`Result.reserveUsed`, `cash`).
- **Illiquid vault**: `settle` and `earlyExit` revert until liquidity returns. The pending state is safe because nothing has been paid out yet.
- **Disclosure**: the `/risk` page explains this first and most prominently.

Residual: a total vault loss above the reserve does break the floor. That is inherent to "bond + call" and is disclosed.

### 2. Settlement-price manipulation
*Scenarios:* (a) the keeper submits a favourable round; (b) a stale or paused oracle; (c) the oracle disagrees with the market; (d) lock timing is used to pick a low strike; (e) a sequencer outage; (f) a weekend or holiday mispricing during early exits.

Mitigations:
- (a) **Round proofs**: `OracleAdapter.priceAt` requires `round.updatedAt ≤ close` and `nextRound.updatedAt > close` (or `round == latest`), phase-aware. A hint can't select any round other than the one in effect at the close. Tested in `test_priceAt_*`.
- (b) **Staleness**: `answer > 0`, `updatedAt ≤ ts`, and `ts − updatedAt ≤ maxStaleness` (26h vs the 24h heartbeat). A paused feed (corporate action) makes settlement revert rather than use a bad price.
- (c) **Cross-check**: each token reads Chainlink's primary proxy and its independent "Shared SVR" proxy, and rejects > 1% deviation.
- (d) **Strike = close at `subscriptionEnd`**, proven with round hints; lock timing has no influence.
- (e) **Sequencer feed hook**: if Chainlink publishes a Robinhood Chain uptime feed, the Timelock can set it (`setSequencerFeed` with a grace period). None is published today.
- (f) **Early exit only during the regular session** (`MarketClock.isTradingSession`), with a live-price staleness check and a slippage floor (`minCashOut`) plus a deadline.
- **US close definition**: `MarketClock` handles DST and NYSE holidays and early closes. Maturity is always a real close.
- **Last resort**: `settleManual` by the Timelock only, ≥7 days after maturity, publicly queued for 48h.

Residual: Chainlink itself reporting a wrong price inside the 1% band. This is accepted; the protocol cannot do better than its oracle.

### 3. Underwriter insolvency
*Scenario:* underwriters can't pay the call payoff.

Mitigations:
- **Full collateralization in kind**: committing U basket units transfers `ceil(U × qᵢ)` of each token up front. Payoff for U units = U × (L−K)/L < U for every level L, so collateral ≥ maximum payout by construction. There is no margin, no liquidation and no oracle dependency for solvency.
- **Rounding**: deposits round up and every withdrawal or payout rounds down; pro-rata claims sum to at most the pool.
- **Invariant test** `invariant_collateralCoversMaxPayout`: pool balance ≥ open units × quantity across random sequences. Fuzz test `testFuzz_underwriterSolvency`.
- **Capacity check at lock**: units sold ≤ committed. Acceptance scales down if capacity is short.

Residual: none for solvency. Underwriters bear the opportunity cost of capped upside.

## Other threats

| Threat | Mitigation |
|---|---|
| Reentrancy (ERC-777/1155 callbacks, malicious tokens) | `nonReentrant` on every state-changing external function. Checks-effects-interactions: notes burned and `liveNotes` reduced before external calls. Only allowlisted stablecoins and oracle-configured stock tokens. |
| Malicious adapter or token in a series | Stables, yield adapters and options adapters must be Timelock-allowlisted. Basket tokens must have an oracle feed (Timelock-configured). |
| Unbounded loops / DoS | Baskets ≤ 10 tokens. Claims are pull-based and O(1). No iteration over users or underwriters. Calendar batches ≤ 64. Compliance batches ≤ 200. |
| Flash-stake for priority allocation | Priority requires `stakedSince ≤ series.createdAt` plus a minimum stake. Unstaking removes priority immediately and has a 7-day cooldown. |
| Fee-on-transfer project token | `stake` credits the measured balance delta. |
| Inflation/donation on vault entry | Max-loss guard on deposit (see 1). |
| Admin key compromise | 48h Timelock on every admin path. Guardian can pause entry. Deployer renounces all admin roles (asserted in `Deploy._postflight`). |
| Griefing lock (oracle down) | `cancelStale` after the 3-day lock window refunds everyone. |
| Secondary market front-running / stale listings | Buyer `maxPriceWad` + `deadline`. Listings escrowed. Trading disabled once a series settles. |
| Compliance bypass via transfer | `Note._update` checks the recipient on every non-mint, non-burn transfer when enabled. Protocol escrows are allowlisted at deploy. |
| Stock-token corporate actions | Chainlink prices already include the ERC-8056 `uiMultiplier`, so payouts use token units consistently. A paused oracle defers settlement. |
| Sequencer censorship | Chain-level risk, disclosed. All functions are permissionless, so any account can complete lock and settle. |
| Rounding drain | Every pro-rata division rounds against the claimer (Math.mulDiv floor). The bond deposit rounds up in favour of the floor. |

## Static analysis (Slither 0.11.x)

`slither . --filter-paths "lib/|test/|script/"`: **0 high, 0 medium.** The remaining low and informational findings are triaged:
- `calls-loop`: external calls inside loops over basket tokens (≤10) and to protocol-owned contracts. Intentional and bounded.
- `timestamp`: market-hours, maturity and staleness logic must use `block.timestamp`. Granularity is hours, and sequencer drift is seconds.
- `missing-zero-check` on optional wiring (`compliance`, `hooks` may be zero by design).
- `reentrancy-benign` in `Settlement._settle`: state written after calls to protocol-owned, allowlisted adapters, under `nonReentrant`, after `markSettled` already flipped the series state.
- Suppressed with justification inline: `unused-return` (unused Chainlink tuple fields), `incorrect-equality` (zero checks on accounting values, not balances), `divide-before-multiply` (calendar integer algorithm, round-trip fuzzed).

## Test evidence
- Unit, fuzz (512 runs) and invariant tests (128 runs × 64 depth, 4 invariants), including *every note can claim at least its floor when the yield source is solvent* and *underwriter collateral always covers the max call payout*.
- Fork tests against Robinhood Chain mainnet with real USDG, real AAPL, and the real Chainlink primary and SVR proxies.
- Line coverage on `src/`: 99.8% overall, 100% on SeriesFactory, Settlement, UnderwriterPool, OracleAdapter, MarketClock, FeeCollector, SecondaryListings, ProjectTokenHooks and Note.

## Not covered / recommendations before mainnet TVL
- An independent audit. This codebase has not been audited.
- A multisig as Timelock proposer and as guardian (`FLOORCAP_TIMELOCK_PROPOSER`, `FLOORCAP_GUARDIAN`).
- Vet any ERC-4626 vault (curator, markets, liquidity, admin powers) before allowlisting it.
- Monitor feed heartbeat during US holidays. Extend the NYSE calendar every year.
