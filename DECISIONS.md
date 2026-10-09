# Decisions

One line of reasoning per decision. Newest considerations at the bottom of each section.

## Chain and assets
- **Target Robinhood Chain mainnet, chain id 4663**: confirmed on-chain (`eth_chainId` = 0x1237) and in docs.robinhood.com/chain; public RPC `https://rpc.mainnet.chain.robinhood.com`, explorer `robinhoodchain.blockscout.com`, gas token ETH.
- **Stablecoin = USDG (6 decimals)**: the only stablecoin listed on Robinhood's own token-contracts page; USDC/USDT token addresses are not published by an official source, so they are not used.
- **Stock-token addresses come from Robinhood's registry API** (`api.robinhood.com/rhj/assets`, which backs the docs "Token Contracts" page). Feeds come from Chainlink's Robinhood feed list. Nothing was guessed. Each address was checked with an on-chain call.
- **Launch universe = 12 tokens with both a stock token and a Chainlink feed** (AAPL, NVDA, TSLA, MSFT, GOOGL, AMZN, META, SPY, QQQ, AMD, PLTR, COIN). More can be added through `OracleAdapter.setFeed` via the Timelock.
- **Contracts hold stock tokens directly**: I verified on-chain that transfers to contracts work. The docs describe no token-level allowlist; sanctions screening happens at the sequencer.

## Yield source (bond leg)
- **No permissionless, instantly redeemable, institutional-grade USDG yield source exists on-chain today.** syrupUSDG is a CCIP-bridged share with no deposit/redeem on this chain (redeem only on Ethereum, behind Maple's permission manager and a withdrawal queue). Morpho is deployed and has USDG Vault V2s, but the biggest held about $1k at research time and none is officially published. The SGOV T-bill ETF token exists but can only be bought via DEX/RFQ, which adds swap slippage to the floor.
- **Shipped `ERC4626YieldAdapter`** (the target is a curated Morpho Vault V2 on USDG, e.g. the one behind "Robinhood Earn" once its address is published) **plus `HoldYieldAdapter`** (zero-yield custody of USDG). Both sit behind the swappable `IYieldAdapter`, so a vetted vault can be added later without redeploying.
- **The default deployment uses HoldYieldAdapter only.** The floor must not depend on an unvetted vault. Consequence: only 95%-protected series have an upside budget at launch; 100% series need a real yield source (`FLOORCAP_YIELD_VAULT`) and an allowlisting through the Timelock.
- **Per-series segregated shares inside each adapter**: one series can never redeem another series' bond leg.
- **The ERC-4626 deposit has a max-loss guard (default 0.10%)**: catches donation/inflation games and silent entry fees.
- **Assumed yield is a curator input with a hard cap (10%, Timelock-adjustable)**: the protocol never trusts a live APY for payouts. The UI shows the assumed yield on every series.
- **Shortfall reserve**: 20% of every fee accrues to a reserve that `Settlement` draws on automatically if the bond leg is short of the floor. It is a buffer, not insurance.

## Options leg
- **No on-chain options venue exists on Robinhood Chain** (research covered Derive/Lyra, Panoptic, Opyn, Rysk, Premia, Stryke and Aevo; only perp DEXes such as Lighter and Arcus exist). So the built-in **UnderwriterPool** implements `IOptionsAdapter`; a future venue can plug into the same interface.
- **Fully collateralized, in-kind covered calls**: underwriters post the basket's stock tokens. A call on U units pays U·(L−K)/L units in kind, which is always less than U, so collateral covers the maximum payout for any price and no liquidation engine is needed.
- **Calls are paid in kind (stock tokens), not cash**: this avoids depending on DEX liquidity and slippage at settlement. The value equals participation × gain at the settlement price.
- **Baskets are "basket units"** (fixed token quantities per unit, up to 10 tokens), so single stocks and baskets share one code path.
- **Premium is a curator-set % of notional (from off-chain implied vol), and underwriters opt in at that price**: this is simple and transparent, and needs no on-chain auction. Participation = (1 − bond − fee) / premium is fixed at creation and shown up front.
- **Strike is ATM at the subscription-end close**, proven with Chainlink round hints. This removes any lock-timing games.
- **Underwriter claims are lazy and pro-rata to commitment** (unused, premium, final): no loops over underwriters.

## Primary market
- **One ERC-1155 id per series; 1 note = 1 base unit of USDG principal**: it is self-describing and keeps balances and principal identical.
- **Oversubscription is lazy**: two fill ratios (priority, regular) are stored at lock, and each subscriber claims notes plus refund in O(1). Stakers fill first, everyone else pro-rata.
- **Priority requires a stake made before the series was created** (and ≥ the minimum): this defeats flash or just-in-time staking.
- **Acceptance = min(deposits, cap, underwriter capacity at this participation)**. Below `minSize` the series cancels and everything is refundable.
- **A lock window of 3 days, then anyone can `cancelStale`**: funds never get stuck behind an oracle outage.

## Settlement, exits, secondary
- **Settlement price = the Chainlink round in effect at the US regular-session close**, proven on-chain (round.updatedAt ≤ close < nextRound.updatedAt, phase-aware), cross-checked against Chainlink's independent "Shared SVR" proxy (≤1% deviation), staleness ≤ 26h.
- **MarketClock computes 16:00 America/New_York with US DST rules and a Timelock-maintained NYSE holiday/early-close table** (2026–2027 seeded). Maturity rolls to the next trading close.
- **Manual settlement fallback**: only the Timelock (48h public delay) and only ≥7 days after maturity. A broken feed can delay payouts but can't freeze them forever.
- **Early exit = pro-rata bond leg now + the calls' intrinsic value at the live price − exit fee**. It is only allowed during the regular session, so stale weekend prices can't be exploited. The exiter forfeits time value to underwriters, which is conservative for remaining holders (their pro-rata claims are unaffected; covered by fuzz tests).
- **Claims and refunds are never pausable**; the guardian can only pause new risk (subscribe, lock, commit, settle, exit, list/buy).
- **The secondary market is a fixed-price, escrowed, partially fillable listing book** with a buyer price cap, a deadline, a 0.5% fee and no trading after settlement.

## Governance and security
- **Every admin role is held by a 48h OpenZeppelin TimelockController**, and the deployer renounces all admin roles in the same deploy script (asserted in post-flight). The guardian and curator are operational roles only.
- **Adapters, stablecoins and options venues must be allowlisted by the Timelock**: a curator cannot point a series at a malicious adapter.
- **Slither: 0 high / 0 medium.** The remaining notes are documented intentional patterns (bounded loops over ≤10 basket tokens, block.timestamp for market hours, unused tuple fields from Chainlink).
- **Compiler 0.8.28 without via-IR**: functions were split to avoid stack-too-deep so coverage instrumentation stays accurate.

## Project token
- **No token is written or deployed.** `ProjectTokenHooks.setProjectToken` is one-shot, admin-only (the Timelock). Until it's set, `isActive()` is false and every token feature is inert. Fee sharing is in USDG to stakers.

## Compliance and branding
- **`ComplianceRegistry` is off by default and gates subscribe/transfer/buy/underwrite per action** once enabled. A geoblock runs as Next.js middleware on Vercel's IP-country header, with a risk disclosure page.
- **No Robinhood name or logo in the brand**: the app is "Floorcap" with its own mark. "Robinhood Chain" appears only as the factual network name.

## Tooling
- **pnpm monorepo** with `/contracts` (Foundry), `/app` (Next.js 15, wagmi 2, RainbowKit 2), `/scripts` (keeper, fork seeding), `/config` (addresses) and `/docs`.
- **wagmi 2.x instead of 3.x**: RainbowKit 2.2.11's peer dependency is `wagmi ^2.9`.
- **The fork runs on chain id 31337**, so fork deployments can never overwrite `deployments/4663.json` or confuse wallets.
- **Fork tests use the latest block**: the public RPC is not an archive node (historical state is unavailable). New oracle rounds after the fork block are simulated with `vm.mockCall` on the real feed addresses.
- **The keeper never reads keys**: it supports dry-run (prints calldata), node-managed accounts, or `cast send --account <keystore>`.
- **Verification uses Blockscout** (`--verifier blockscout`), the method documented in Robinhood's docs. The Blockscout API sits behind Cloudflare, so DEPLOY.md includes a retry/fallback command.
