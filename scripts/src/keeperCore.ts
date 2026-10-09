// Keeper core: see keeper.ts for usage. Configuration is read from env at call time.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { execFileSync } from "node:child_process";
import { createPublicClient, createWalletClient, encodeFunctionData, http, type Address, type PublicClient } from "viem";
import { robinhoodChain } from "@floorcap/config";
import { SeriesFactoryAbi, SettlementAbi, OracleAdapterAbi } from "./abi/index.js";
import { findRoundAt } from "./rounds.js";

function env() {
  const CHAIN_ID = Number(process.env.CHAIN_ID ?? 4663);
  const RPC_URL = process.env.RPC_URL ?? robinhoodChain.rpcUrls.default.http[0];
  return {
    CHAIN_ID,
    RPC_URL,
    MODE: (process.env.KEEPER_MODE ?? "dry-run") as "dry-run" | "rpc-account" | "cast",
    DEPLOYMENTS_DIR: process.env.DEPLOYMENTS_DIR ?? join(process.cwd(), "..", "deployments"),
    chain: {
      id: CHAIN_ID,
      name: CHAIN_ID === 4663 ? "Robinhood Chain" : "Robinhood Chain fork",
      nativeCurrency: robinhoodChain.nativeCurrency,
      rpcUrls: { default: { http: [RPC_URL] } },
    },
  };
}

function publicClient(): PublicClient {
  const e = env();
  return createPublicClient({ chain: e.chain, transport: http(e.RPC_URL, { retryCount: 5, timeout: 60_000 }) }) as PublicClient;
}

const STATE = { Subscription: 1, Locked: 2 } as const;

type Deployment = { SeriesFactory: Address; Settlement: Address; OracleAdapter: Address };

function loadDeployment(): Deployment {
  const e = env();
  return JSON.parse(readFileSync(join(e.DEPLOYMENTS_DIR, `${e.CHAIN_ID}.json`), "utf8"));
}

async function hintsFor(client: PublicClient, dep: Deployment, id: bigint, ts: bigint) {
  const tokens = (await client.readContract({
    address: dep.SeriesFactory,
    abi: SeriesFactoryAbi,
    functionName: "basketTokens",
    args: [id],
  })) as readonly Address[];
  const primary: bigint[] = [];
  const secondary: bigint[] = [];
  for (const t of tokens) {
    const cfg = (await client.readContract({
      address: dep.OracleAdapter,
      abi: OracleAdapterAbi,
      functionName: "feedOf",
      args: [t],
    })) as { primary: Address; secondary: Address };
    primary.push(await findRoundAt(client, cfg.primary, ts));
    secondary.push(
      cfg.secondary === "0x0000000000000000000000000000000000000000" ? 0n : await findRoundAt(client, cfg.secondary, ts),
    );
  }
  return { primary, secondary };
}

async function send(client: PublicClient, to: Address, abi: readonly unknown[], functionName: string, args: readonly unknown[], label: string) {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const data = encodeFunctionData({ abi: abi as any, functionName, args: args as any });
  // simulate first so we never send a reverting tx
  const { MODE, RPC_URL, chain } = env();
  await client.call({ to, data, account: (process.env.KEEPER_ADDRESS as Address) ?? undefined });
  if (MODE === "dry-run") {
    console.log(`[dry-run] ${label}\n  to=${to}\n  data=${data}`);
    return;
  }
  if (MODE === "rpc-account") {
    const account = process.env.KEEPER_ADDRESS as Address;
    if (!account) throw new Error("KEEPER_ADDRESS required for rpc-account mode");
    const wallet = createWalletClient({ chain, transport: http(RPC_URL) });
    const hash = await wallet.sendTransaction({ account, to, data, chain });
    const rcpt = await client.waitForTransactionReceipt({ hash });
    console.log(`${label}: ${rcpt.status} ${hash}`);
    return;
  }
  const keystore = process.env.KEEPER_KEYSTORE ?? "floorcap-keeper";
  const out = execFileSync("cast", ["send", "--rpc-url", RPC_URL, "--account", keystore, to, data], {
    stdio: ["inherit", "pipe", "inherit"],
  });
  console.log(`${label}: ${out.toString().split("\n").find((l) => l.startsWith("status")) ?? "sent"}`);
}

export async function tick() {
  const client = publicClient();
  const { CHAIN_ID } = env();
  const dep = loadDeployment();
  const now = (await client.getBlock()).timestamp;
  const count = (await client.readContract({ address: dep.SeriesFactory, abi: SeriesFactoryAbi, functionName: "seriesCount" })) as bigint;
  const lockWindow = (await client.readContract({ address: dep.SeriesFactory, abi: SeriesFactoryAbi, functionName: "lockWindow" })) as bigint;
  console.log(`[keeper] chain ${CHAIN_ID} block time ${now}, ${count} series`);
  for (let id = 1n; id <= count; id++) {
    const s = (await client.readContract({ address: dep.SeriesFactory, abi: SeriesFactoryAbi, functionName: "getSeries", args: [id] })) as {
      state: number;
      subscriptionEnd: bigint;
      maturity: bigint;
    };
    try {
      if (s.state === STATE.Subscription && now >= s.subscriptionEnd) {
        if (now > s.subscriptionEnd + lockWindow) {
          await send(client, dep.SeriesFactory, SeriesFactoryAbi, "cancelStale", [id], `cancelStale #${id}`);
        } else {
          const h = await hintsFor(client, dep, id, s.subscriptionEnd);
          await send(client, dep.SeriesFactory, SeriesFactoryAbi, "lock", [id, h.primary, h.secondary], `lock #${id}`);
        }
      } else if (s.state === STATE.Locked && now >= s.maturity) {
        const h = await hintsFor(client, dep, id, s.maturity);
        await send(client, dep.Settlement, SettlementAbi, "settle", [id, h.primary, h.secondary], `settle #${id}`);
      }
    } catch (e) {
      console.error(`[keeper] series #${id}: ${(e as Error).message.split("\n")[0]}`);
    }
  }
}
