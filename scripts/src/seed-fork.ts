/**
 * LOCAL FORK ONLY. Seeds a freshly deployed fork (chain 31337) with demo series so the frontend can be exercised
 * against real Robinhood Chain tokens and Chainlink feeds:
 *   - funds anvil dev accounts #1 (subscriber) and #2 (underwriter) with real USDG / stock tokens by impersonating
 *     current on-chain holders (found from recent Transfer logs)
 *   - creates three series (account #0 is the curator after Deploy.s.sol on the fork)
 *   - fills and locks one series at today's US close so "My notes" has a live position
 * Uses anvil's unlocked dev accounts; no private keys are read.
 *
 * Usage: RPC_URL=http://127.0.0.1:18645 pnpm --filter @floorcap/scripts seed-fork
 */
import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import {
  createPublicClient,
  createTestClient,
  createWalletClient,
  erc20Abi,
  http,
  parseAbiItem,
  parseUnits,
  type Address,
} from "viem";
import { contracts, stockTokens } from "@floorcap/config";
import { SeriesFactoryAbi, UnderwriterPoolAbi, MarketClockAbi } from "./abi/index.js";
import { tick } from "./keeperCore.js";

const RPC_URL = process.env.RPC_URL ?? "http://127.0.0.1:47391";
const UPSTREAM = process.env.UPSTREAM_RPC ?? "https://rpc.mainnet.chain.robinhood.com";
const MODE = process.argv[2] ?? "all"; // "discover" | "seed" | "all"
const FORK_DIR = join(process.cwd(), "..", ".fork");
const chain = {
  id: 31337,
  name: "fork",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
} as const;
const pub = createPublicClient({ chain, transport: http(RPC_URL, { timeout: 120_000 }) });
// Holder discovery runs against the live chain: the public RPC is not an archive node, so a fork can only read
// state it fetched shortly after it started.
const live = createPublicClient({ transport: http(UPSTREAM, { timeout: 120_000, retryCount: 5 }) });
const test = createTestClient({ chain, mode: "anvil", transport: http(RPC_URL, { timeout: 120_000 }) });
const wallet = createWalletClient({ chain, transport: http(RPC_URL, { timeout: 120_000 }) });

const CURATOR: Address = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"; // anvil #0
const SUBSCRIBER: Address = "0x70997970C51812dc3A010C7d01b50e0d17dc79C8"; // anvil #1
const UNDERWRITER: Address = "0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC"; // anvil #2

const sym = (s: string) => stockTokens.find((t) => t.symbol === s)!.address as Address;
const transferEvent = parseAbiItem("event Transfer(address indexed from, address indexed to, uint256 value)");

async function largestRecentHolder(token: Address, exclude: Address[]): Promise<Address> {
  const latest = await live.getBlockNumber();
  const cands = new Set<Address>();
  // Adaptive window: busy tokens (USDG) exceed the RPC's 10k-log cap on wide ranges.
  let window = 50_000n;
  let to = latest;
  while (latest - to < 2_000_000n && cands.size < 25) {
    try {
      const logs = await live.getLogs({ address: token, event: transferEvent, fromBlock: to - window, toBlock: to });
      for (const l of logs.slice(-200)) cands.add(l.args.to as Address);
      to -= window;
    } catch {
      if (window <= 500n) throw new Error(`cannot scan logs for ${token}`);
      window /= 4n;
    }
  }
  let best: Address | undefined;
  let bestBal = 0n;
  for (const c of cands) {
    if (exclude.includes(c)) continue;
    const b = await live.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [c] });
    if (b > bestBal) {
      bestBal = b;
      best = c;
    }
  }
  if (!best) throw new Error(`no holder found for ${token}`);
  return best;
}

const DEMO_TOKENS = ["USDG", "AAPL", "NVDA", "MSFT"] as const;
const tokenAddr = (s: (typeof DEMO_TOKENS)[number]) => (s === "USDG" ? (contracts.USDG.address as Address) : sym(s));

async function discover() {
  mkdirSync(FORK_DIR, { recursive: true });
  const holders: Record<string, Address> = {};
  for (const s of DEMO_TOKENS) {
    holders[s] = await largestRecentHolder(tokenAddr(s), [SUBSCRIBER, UNDERWRITER]);
    console.log(`holder ${s}: ${holders[s]}`);
  }
  writeFileSync(join(FORK_DIR, "holders.json"), JSON.stringify(holders, null, 2));
  return holders;
}

let HOLDERS: Record<string, Address> = {};

async function fund(token: Address, to: Address, amount: bigint) {
  const symbol = DEMO_TOKENS.find((s) => tokenAddr(s).toLowerCase() === token.toLowerCase())!;
  const holder = HOLDERS[symbol];
  const bal = await pub.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [holder] });
  const amt = amount < bal ? amount : bal;
  await test.impersonateAccount({ address: holder });
  await test.setBalance({ address: holder, value: 10n ** 18n });
  const hash = await wallet.writeContract({ account: holder, address: token, abi: erc20Abi, functionName: "transfer", args: [to, amt], chain });
  await pub.waitForTransactionReceipt({ hash });
  await test.stopImpersonatingAccount({ address: holder });
  console.log(`funded ${to} with ${amt} of ${token} from ${holder}`);
  return amt;
}

async function write(account: Address, address: Address, abi: readonly unknown[], functionName: string, args: readonly unknown[]) {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const hash = await wallet.writeContract({ account, address, abi: abi as any, functionName, args: args as any, chain });
  const r = await pub.waitForTransactionReceipt({ hash });
  if (r.status !== "success") throw new Error(`${functionName} reverted`);
  return r;
}

async function main() {
  if (MODE === "discover") {
    await discover();
    return;
  }
  const holdersFile = join(FORK_DIR, "holders.json");
  HOLDERS = existsSync(holdersFile) && MODE === "seed" ? JSON.parse(readFileSync(holdersFile, "utf8")) : await discover();
  const dep = JSON.parse(readFileSync(join(process.cwd(), "..", "deployments", "31337.json"), "utf8"));
  const factory = dep.SeriesFactory as Address;
  const pool = dep.UnderwriterPool as Address;
  const clock = dep.MarketClock as Address;
  const USDG = contracts.USDG.address as Address;
  const now = (await pub.getBlock()).timestamp;

  // 1. fund demo accounts with real assets
  await fund(USDG, SUBSCRIBER, parseUnits("50000", 6));
  await fund(sym("AAPL"), UNDERWRITER, parseUnits("60", 18));
  await fund(sym("NVDA"), UNDERWRITER, parseUnits("150", 18));
  await fund(sym("MSFT"), UNDERWRITER, parseUnits("20", 18));

  // 2. create series
  const closeSoon = (await pub.readContract({ address: clock, abi: MarketClockAbi, functionName: "closeOnOrAfter", args: [now + 3600n] })) as bigint;
  const closeLater = (await pub.readContract({ address: clock, abi: MarketClockAbi, functionName: "closeOnOrAfter", args: [now + 4n * 86400n] })) as bigint;
  const base = {
    stable: USDG,
    yieldAdapter: dep.HoldYieldAdapter as Address,
    optionsAdapter: pool,
    subscriptionStart: now,
    protectionBps: 9500,
    assumedYieldBps: 0,
    structuringFeeBps: 50,
    exitFeeBps: 100,
    cap: parseUnits("250000", 6),
    minSize: parseUnits("1000", 6),
  };
  const specs = [
    { ...base, name: "NVDA 6M 95%", tokens: [sym("NVDA")], quantities: [10n ** 18n], subscriptionEnd: closeSoon, tenorMonths: 6, premiumBps: 1500 },
    { ...base, name: "AAPL 12M 95%", tokens: [sym("AAPL")], quantities: [10n ** 18n], subscriptionEnd: closeLater, tenorMonths: 12, premiumBps: 1150 },
    {
      ...base,
      name: "Mega-cap tech basket 6M 95%",
      tokens: [sym("AAPL"), sym("MSFT"), sym("NVDA")],
      quantities: [parseUnits("0.3", 18), parseUnits("0.2", 18), parseUnits("0.5", 18)],
      subscriptionEnd: closeLater,
      tenorMonths: 6,
      premiumBps: 850,
    },
  ];
  const startId = ((await pub.readContract({ address: factory, abi: SeriesFactoryAbi, functionName: "seriesCount" })) as bigint) + 1n;
  for (const s of specs) {
    await write(CURATOR, factory, SeriesFactoryAbi, "createSeries", [s]);
    console.log(`created ${s.name}`);
  }

  // 3. underwriter commits to all three; subscriber fills the first
  for (const t of [sym("AAPL"), sym("NVDA"), sym("MSFT")]) {
    await write(UNDERWRITER, t, erc20Abi, "approve", [pool, 2n ** 255n]);
  }
  await write(UNDERWRITER, pool, UnderwriterPoolAbi, "commit", [startId, parseUnits("100", 18)]);
  await write(UNDERWRITER, pool, UnderwriterPoolAbi, "commit", [startId + 1n, parseUnits("40", 18)]);
  await write(UNDERWRITER, pool, UnderwriterPoolAbi, "commit", [startId + 2n, parseUnits("40", 18)]);
  await write(SUBSCRIBER, USDG, erc20Abi, "approve", [factory, 2n ** 255n]);
  await write(SUBSCRIBER, factory, SeriesFactoryAbi, "subscribe", [startId, parseUnits("20000", 6)]);
  await write(SUBSCRIBER, factory, SeriesFactoryAbi, "subscribe", [startId + 1n, parseUnits("5000", 6)]);

  // 4. move the fork past today's close and let the keeper lock series #1 at the proven close price
  const t = (await pub.getBlock()).timestamp;
  await test.increaseTime({ seconds: Number(closeSoon - t + 120n) });
  await test.mine({ blocks: 1 });
  process.env.CHAIN_ID = "31337";
  process.env.RPC_URL = RPC_URL;
  process.env.KEEPER_MODE = "rpc-account";
  process.env.KEEPER_ADDRESS = CURATOR;
  await tick();
  await write(SUBSCRIBER, factory, SeriesFactoryAbi, "claimAllocation", [startId, SUBSCRIBER]);
  console.log("seeded. Subscriber (anvil #1) holds notes of series", startId.toString());

  // Touch every piece of chain state the app reads so the snapshot is self-contained.
  const feedAbi = [
    { type: "function", name: "latestRoundData", stateMutability: "view", inputs: [], outputs: [
      { type: "uint80" }, { type: "int256" }, { type: "uint256" }, { type: "uint256" }, { type: "uint80" }] },
    { type: "function", name: "decimals", stateMutability: "view", inputs: [], outputs: [{ type: "uint8" }] },
  ] as const;
  for (const t of stockTokens) {
    for (const f of [t.feed, t.feedSecondary]) {
      await pub.readContract({ address: f as Address, abi: feedAbi, functionName: "latestRoundData" });
      await pub.readContract({ address: f as Address, abi: feedAbi, functionName: "decimals" });
    }
    await pub.readContract({ address: t.address as Address, abi: erc20Abi, functionName: "totalSupply" });
    await pub.readContract({ address: t.address as Address, abi: erc20Abi, functionName: "decimals" });
  }
  await pub.readContract({ address: USDG, abi: erc20Abi, functionName: "decimals" });
  await pub.getCode({ address: "0xcA11bde05977b3631167028862bE2a173976CA11" });

  const block = await pub.getBlock();
  const state = await test.dumpState();
  writeFileSync(join(FORK_DIR, "state.hex"), state);
  writeFileSync(join(FORK_DIR, "timestamp"), block.timestamp.toString());
  console.log(`dumped fork state (${state.length} chars) at timestamp ${block.timestamp} to .fork/state.hex`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
