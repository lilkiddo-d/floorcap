# Architecture

```
               subscribe / claimAllocation                     earlyExit / claim
  user ──USDG──▶ SeriesFactory ──bond──▶ YieldAdapter ◀──withdrawShare── Settlement ──▶ user
                     │  └─fee──▶ FeeCollector ──staker share──▶ ProjectTokenHooks
                     │                ▲ shortfall reserve ───────────────┘ (coverShortfall)
                     └─premium──▶ UnderwriterPool (IOptionsAdapter) ──exercise (in-kind)──▶ Settlement
  underwriter ──stock tokens──▶ UnderwriterPool          OracleAdapter + MarketClock ──▶ prices at US close
  Note (ERC-1155): minted by SeriesFactory, burned by Settlement, traded via SecondaryListings
  Timelock (48h): DEFAULT_ADMIN_ROLE everywhere
```

## Series lifecycle

| State | Entered by | Who can act |
|---|---|---|
| Subscription | `createSeries` (curator) | subscribers `subscribe/withdrawSubscription`, underwriters `commit/uncommit` |
| Locked | `lock` (anyone, within 3 days of the subscription-end close) | `claimAllocation`, `earlyExit` (regular session), transfers, listings |
| Cancelled | below `minSize`, no capacity, `cancelStale`, or `cancelSeries` | refunds via `claimAllocation`, `withdrawCancelled` |
| Settled | `settle` (anyone, after the maturity close) or `settleManual` (Timelock, ≥7d later) | `claim`, underwriters `claimPremium/claimFinal` |

## Units
- Notes: 1 unit = 1 base unit of the series stablecoin (USDG, 6 decimals) of principal.
- Basket units: 1e18 units = `quantities[i]` wei of each token i. Prices are USD with 18 decimals per whole token.
- Ratios ("wad"): 1e18 = 100%. Fees: bps.

## Keeper
`scripts/src/keeperCore.ts` reads all series. It calls `lock` after the subscription close and `settle` after maturity,
passing the Chainlink round ids that were in effect at the close (binary search over rounds, phase-aware). The
contracts verify those round ids, so the keeper is untrusted.
