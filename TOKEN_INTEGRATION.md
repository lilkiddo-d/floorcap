# Project token ($FCAP) integration

**This repository does not contain, write or deploy any ERC-20 for the project.** $FCAP will be launched separately on
a launchpad. The protocol is fully functional without it, and every token feature stays switched off until the token
address is wired once, through the 48-hour Timelock.

## What the token does

| Feature | Where | Behaviour |
|---|---|---|
| Staking | `ProjectTokenHooks.stake / requestUnstake / withdraw` | Stake $FCAP. Unstaking has a cooldown (default 7 days). Stake removed by `requestUnstake` stops earning and loses priority immediately. |
| Priority allocation | `SeriesFactory.subscribe` → `ProjectTokenHooks.isPriority(account, series.createdAt)` | In an oversubscribed series, priority deposits are filled before everyone else (who are then filled pro-rata). To qualify, the stake must be ≥ `minPriorityStake` (default 1,000 $FCAP) and must have been made **before the series was created** (anti flash-stake). |
| Fee share | `FeeCollector.recordFee(..., structuring=true)` → `ProjectTokenHooks.notifyReward` | `stakerShareBps` (default 30%) of every structuring fee is streamed to stakers in USDG, pro-rata to stake (claim with `claimRewards`). Exit and secondary fees are not shared. |

## How it stays inert until set

- `ProjectTokenHooks.projectToken` starts as `address(0)`, so `isActive()` returns false.
- `isPriority` returns false for everyone, so every deposit is "regular" and fills are pure pro-rata.
- `stake` reverts with `Inactive()`.
- `FeeCollector` only routes a staker share when the hooks are active **and** `totalStaked > 0`. Otherwise the share goes to the treasury.
- The frontend hides the Stake page and every token badge while `NEXT_PUBLIC_PROJECT_TOKEN` is empty.

Tests use a mock ERC-20 (`test/mocks/Mocks.sol: MockERC20`) only.

## Wiring the token after launch

`setProjectToken(address)` can be called **exactly once** (`AlreadySet()` afterwards), **only** by `DEFAULT_ADMIN_ROLE`,
which is held by the Timelock. It rejects `address(0)` and the reward token.

1. Schedule the call on the Timelock (from the proposer account, normally your multisig). With the Foundry keystore
   account used for the deploy:

```bash
TIMELOCK=$(jq -r .Timelock deployments/4663.json)
HOOKS=$(jq -r .ProjectTokenHooks deployments/4663.json)
FCAP=0xYourLaunchedTokenAddress
DATA=$(cast calldata "setProjectToken(address)" $FCAP)
cast send $TIMELOCK "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" \
  $HOOKS 0 $DATA 0x0000000000000000000000000000000000000000000000000000000000000000 \
  0x0000000000000000000000000000000000000000000000000000000000000000 172800 \
  --account floorcap-deployer --rpc-url https://rpc.mainnet.chain.robinhood.com
```

2. After 48 hours, execute it (executor = anyone by default):

```bash
cast send $TIMELOCK "execute(address,uint256,bytes,bytes32,bytes32)" \
  $HOOKS 0 $DATA 0x0000000000000000000000000000000000000000000000000000000000000000 \
  0x0000000000000000000000000000000000000000000000000000000000000000 \
  --account floorcap-deployer --rpc-url https://rpc.mainnet.chain.robinhood.com
```

3. Check: `cast call $HOOKS "isActive()(bool)" --rpc-url https://rpc.mainnet.chain.robinhood.com` should return `true`.
4. Set `NEXT_PUBLIC_PROJECT_TOKEN=$FCAP` in Vercel and redeploy the app. The Stake page and priority badges appear.

## Tunables (Timelock)

- `ProjectTokenHooks.setParams(minPriorityStake, unstakeCooldown)` (cooldown ≤ 30 days)
- `FeeCollector.setShares(reserveShareBps, stakerShareBps)` (sum ≤ 100%)

## Launchpad token caveats

- Fee-on-transfer and rebasing tokens: `stake` credits the measured balance delta, so taxes are handled. Rebasing
  tokens are not supported (stake accounting is static).
- If the launchpad token has blacklist or pausing powers, stakers' withdrawals depend on them. Review this before wiring.
