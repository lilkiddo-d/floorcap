# Floorcap

Principal-protected structured notes on Robinhood Chain (chain id 4663). Deposit USDG, get your protected floor
(100% or 95%) back at maturity, and keep a share of a tokenized-stock basket's gain.

## How it works

Classic "bond + call":

1. **Subscription.** Users deposit USDG into a series (underlying = one stock token or a basket; tenor 3/6/12
   months; protection 100% or 95%). Underwriters post the basket's stock tokens as collateral.
2. **Lock** at the subscription-end US close (permissionless, run by the keeper). The strike is the Chainlink close
   price, proven on-chain. Per 1 USDG of principal:
   - `bond = protection / (1 + assumedYield × T)` goes to the series' yield adapter;
   - the structuring fee goes to the FeeCollector;
   - the rest pays the premium for fully collateralized ATM calls from the UnderwriterPool.
   - Participation = (1 − bond − fee) / premium, fixed and shown before you subscribe.
   - Oversubscribed series fill $FCAP stakers first (once the token is live), then everyone pro-rata. Users claim
     notes (ERC-1155, id = series) plus any refund.
3. **Life of the note.** Notes are transferable and can be listed on the fixed-price secondary board. Early exit
   during the US regular session pays mark-to-market: the bond leg now, plus the calls' intrinsic value at the live
   price, minus an exit fee.
4. **Maturity.** Settlement uses the Chainlink price at the US close. Holders get the floor in USDG plus
   participation × gain in the basket's stock tokens. Underwriters keep the premium and the remaining collateral.

## Repo layout

| Path | What |
|---|---|
| `contracts/` | Foundry project: `src/` contracts, `test/` (unit, fuzz, invariant, fork), `script/Deploy.s.sol` |
| `app/` | Next.js + wagmi + RainbowKit frontend: series list with payoff diagrams, subscribe, my notes (live mark value), secondary, underwrite, settlement history, risk disclosure, stake (token-gated) |
| `scripts/` | Keeper (`pnpm keeper`) for lock/settle, fork seeding, ABI export |
| `config/chains.ts` | Every chain, token and oracle address, each with its source link |
| `deployments/` | `<chainId>.json` written by the deploy script |
| `docs/` | Architecture notes |

## Contracts

| Contract | Role |
|---|---|
| `SeriesFactory` | Series registry, subscription, allocation, lock, deploys capital into the two legs |
| `Note` | ERC-1155 notes, optional compliance gate on transfers |
| `YieldAdapter` → `HoldYieldAdapter`, `ERC4626YieldAdapter` | Bond leg with per-series segregated shares |
| `IOptionsAdapter` → `UnderwriterPool` | Fully collateralized in-kind basket calls sold by underwriters |
| `Settlement` | Maturity settlement, claims, early exit, mark-to-market preview |
| `SecondaryListings` | Fixed-price escrowed listings |
| `OracleAdapter` | Chainlink: staleness, primary/SVR deviation, round proofs at the close, sequencer hook |
| `MarketClock` | US close times (DST plus NYSE holidays and early closes) |
| `FeeCollector` | Fee split: shortfall reserve, stakers, treasury |
| `ProjectTokenHooks` | $FCAP staking, priority and fee share. Inert until `setProjectToken` |
| `ComplianceRegistry` | Per-action allowlist, off by default |
| `Timelock` | 48h OpenZeppelin TimelockController that holds every admin role |

## Develop

```bash
pnpm install
```

```bash
cd contracts && forge test --no-match-contract ForkTest
```

```bash
cd contracts && forge test --match-contract ForkTest
```

```bash
cd contracts && forge coverage --no-match-coverage "(test|script)/" --report summary
```

```bash
cd contracts && slither . --filter-paths "lib/|test/|script/"
```

```bash
pnpm abi && pnpm app:dev
```

## Status

- Tests: unit, fuzz, invariant and mainnet-fork tests pass. Line coverage on `src/` is 99.8%. Slither: 0 high, 0 medium.
- The deploy script is proven by a full deploy on a local mainnet fork and a mainnet dry run.
- **Not audited.** Read THREAT_MODEL.md and the app's /risk page.

## Docs

- [DEPLOY.md](DEPLOY.md): the exact commands to deploy, verify, wire the token, and ship the app to Vercel
- [DECISIONS.md](DECISIONS.md): every product and technical choice, with reasoning
- [THREAT_MODEL.md](THREAT_MODEL.md): risks (yield source, settlement price, underwriter solvency) and mitigations
- [TOKEN_INTEGRATION.md](TOKEN_INTEGRATION.md): how $FCAP plugs in without the protocol deploying a token
