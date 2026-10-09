# Deploy

Everything below is what you run. The deploy script never sees a private key: it signs only through the Foundry
keystore account `floorcap-deployer`, which you create yourself in step 1.

Prerequisites: [Foundry](https://getfoundry.sh) (`forge`, `cast`), Node 20+, pnpm 10, and a funded deployer
address. Gas for the full deploy is about 28M gas, roughly **0.0012 ETH** at the time of the dry run.

## 0. (Optional) choose your operational addresses

The defaults make the deployer the guardian, curator and Timelock proposer. For production, use a multisig:

```bash
export FLOORCAP_TIMELOCK_PROPOSER=0xYourSafe   # can schedule admin actions (48h delay)
export FLOORCAP_GUARDIAN=0xYourSafe            # can pause new activity, manages the compliance allowlist
export FLOORCAP_CURATOR=0xYourCuratorAddress   # creates series within Timelock-set limits
# export FLOORCAP_YIELD_VAULT=0x...            # only after vetting an ERC-4626 USDG vault (see DECISIONS.md)
```

## 1. Import the deployer key into an encrypted Foundry keystore

```bash
cast wallet import floorcap-deployer --interactive
```

You will be prompted for the private key and an encryption password. Nothing is written in plain text.

## 2. Deploy, wire, hand over to the Timelock, verify, write config (one command)

```bash
cd contracts && forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc.mainnet.chain.robinhood.com --account floorcap-deployer --broadcast --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/ --slow
```

This single run:
- deploys MarketClock, OracleAdapter, Note, ComplianceRegistry (off), FeeCollector, ProjectTokenHooks (inert),
  SeriesFactory, UnderwriterPool, Settlement, SecondaryListings, HoldYieldAdapter (+ ERC4626YieldAdapter if
  `FLOORCAP_YIELD_VAULT` is set) and the 48h Timelock
- wires every role, seeds the 2026–2027 NYSE holiday calendar and the Chainlink feeds for 12 stock tokens
- grants every admin role to the Timelock, renounces all of the deployer's admin roles, and asserts this on-chain
  in post-flight
- verifies every contract on Blockscout
- writes `deployments/4663.json` and the frontend config `app/public/deployments/4663.json`. Commit both.

If verification is interrupted (Blockscout's API sits behind Cloudflare), resume without redeploying:

```bash
cd contracts && forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc.mainnet.chain.robinhood.com --account floorcap-deployer --broadcast --resume --verify --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
```

To rehearse first without spending gas (simulation against mainnet, no broadcast, no files written):

```bash
cd contracts && forge script script/Deploy.s.sol:Deploy --rpc-url https://rpc.mainnet.chain.robinhood.com --account floorcap-deployer
```

## 3. Later: wire the project token (once, through the Timelock)

After $FCAP is launched, schedule `setProjectToken` and execute it 48h later. Run from the repo root, with
`FCAP` set to the launched token address:

```bash
FCAP=0xYourLaunchedTokenAddress; TL=$(jq -r .Timelock deployments/4663.json); H=$(jq -r .ProjectTokenHooks deployments/4663.json); Z=0x0000000000000000000000000000000000000000000000000000000000000000; cast send $TL "schedule(address,uint256,bytes,bytes32,bytes32,uint256)" $H 0 $(cast calldata "setProjectToken(address)" $FCAP) $Z $Z 172800 --account floorcap-deployer --rpc-url https://rpc.mainnet.chain.robinhood.com
```

48 hours later:

```bash
FCAP=0xYourLaunchedTokenAddress; TL=$(jq -r .Timelock deployments/4663.json); H=$(jq -r .ProjectTokenHooks deployments/4663.json); Z=0x0000000000000000000000000000000000000000000000000000000000000000; cast send $TL "execute(address,uint256,bytes,bytes32,bytes32)" $H 0 $(cast calldata "setProjectToken(address)" $FCAP) $Z $Z --account floorcap-deployer --rpc-url https://rpc.mainnet.chain.robinhood.com
```

Then set `NEXT_PUBLIC_PROJECT_TOKEN` in Vercel and redeploy the app. If the Timelock proposer is a multisig,
submit the same `schedule` and `execute` calls from the Safe instead. See TOKEN_INTEGRATION.md.

## 4. Deploy the app to Vercel

1. Push the repo (with `app/public/deployments/4663.json` committed) to GitHub.
2. In Vercel: **New Project** → import the repo → set **Root Directory** to `app`. The framework is detected as
   Next.js, and Vercel detects pnpm from the workspace lockfile automatically.
3. Environment variables (Production):

| Name | Value |
|---|---|
| `NEXT_PUBLIC_CHAIN_ID` | `4663` |
| `NEXT_PUBLIC_RPC_URL` | your RPC provider URL (the public RPC is rate-limited) |
| `NEXT_PUBLIC_WC_PROJECT_ID` | WalletConnect Cloud project id (optional; without it only browser wallets) |
| `NEXT_PUBLIC_PROJECT_TOKEN` | empty until step 3, then the $FCAP address |
| `NEXT_PUBLIC_GEOBLOCK` | optional, e.g. `US,GB,CU,IR,KP,SY,RU` |

4. Deploy. Or from the CLI: `cd app && npx vercel --prod`.

## 5. Run the keeper

Lock and settle are permissionless. Anyone can run the keeper; it proves the Chainlink round at the US close.

```bash
cast wallet import floorcap-keeper --interactive
```

```bash
cd scripts && CHAIN_ID=4663 KEEPER_MODE=cast KEEPER_KEYSTORE=floorcap-keeper KEEPER_INTERVAL_SEC=300 pnpm keeper
```

`KEEPER_MODE=dry-run` (the default) prints the calls without sending anything.

## 6. After deploy: create the first series (curator)

Example: a 12-month, 95%-protected AAPL note on the hold adapter (0% assumed yield, 11.5% ATM call premium). The
subscription must end at a US regular-session close; read one from `MarketClock.closeOnOrAfter`:

```bash
D=deployments/4663.json; F=$(jq -r .SeriesFactory $D); C=$(jq -r .MarketClock $D); END=$(cast call $C "closeOnOrAfter(uint256)(uint256)" $(( $(date +%s) + 7*86400 )) --rpc-url https://rpc.mainnet.chain.robinhood.com | cut -d' ' -f1); cast send $F "createSeries((string,address,address,address,address[],uint256[],uint64,uint64,uint8,uint16,uint16,uint16,uint16,uint16,uint256,uint256))" "(\"AAPL 12M 95%\",0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168,$(jq -r .HoldYieldAdapter $D),$(jq -r .UnderwriterPool $D),[0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9],[1000000000000000000],$(date +%s),$END,12,9500,0,1150,50,100,250000000000,1000000000)" --account floorcap-deployer --rpc-url https://rpc.mainnet.chain.robinhood.com
```

---

## Local rehearsal (what was run to prove the deploy)

```bash
anvil --fork-url https://rpc.mainnet.chain.robinhood.com --chain-id 31337 --port 18645
```

```bash
cd contracts && forge script script/Deploy.s.sol:Deploy --rpc-url http://127.0.0.1:18645 --unlocked --sender 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 --broadcast --slow
```

```bash
cd scripts && RPC_URL=http://127.0.0.1:18645 pnpm seed-fork
```

```bash
cd app && NEXT_PUBLIC_CHAIN_ID=31337 NEXT_PUBLIC_RPC_URL=http://127.0.0.1:18645 pnpm dev
```

`--unlocked` uses anvil's built-in dev account, so no key is involved. The fork uses chain id 31337, so it can never
overwrite `deployments/4663.json`. In your wallet, add network `http://127.0.0.1:18645` (chain id 31337). The seed
script funds anvil accounts #1 (subscriber) and #2 (underwriter) with real USDG and stock tokens from on-chain holders.
