import type { Address, PublicClient } from "viem";
import { IAggregatorV3Abi } from "./abi/index.js";

const PHASE_SHIFT = 64n;
const MASK = (1n << 64n) - 1n;

type Round = { id: bigint; updatedAt: bigint };

async function tryRound(client: PublicClient, feed: Address, id: bigint): Promise<Round | null> {
  try {
    const r = await client.readContract({ address: feed, abi: IAggregatorV3Abi, functionName: "getRoundData", args: [id] });
    const updatedAt = r[3];
    return updatedAt === 0n ? null : { id, updatedAt };
  } catch {
    return null;
  }
}

/**
 * Finds the Chainlink round that was current at `ts` (updatedAt <= ts < next.updatedAt) — exactly what
 * OracleAdapter.priceAt verifies on-chain. Binary search inside the phase, falling back to earlier phases.
 */
export async function findRoundAt(client: PublicClient, feed: Address, ts: bigint): Promise<bigint> {
  const latest = await client.readContract({ address: feed, abi: IAggregatorV3Abi, functionName: "latestRoundData" });
  const latestId = latest[0];
  if (latest[3] <= ts) return latestId;

  let phase = latestId >> PHASE_SHIFT;
  let hi = latestId & MASK;
  while (phase > 0n) {
    const first = await tryRound(client, feed, (phase << PHASE_SHIFT) | 1n);
    if (first && first.updatedAt <= ts) {
      // invariant: round lo has updatedAt <= ts, round hi has updatedAt > ts (or is missing)
      let lo = 1n;
      if (hi === 0n) {
        // unknown upper bound in an older phase: exponential search
        hi = 2n;
        for (;;) {
          const r = await tryRound(client, feed, (phase << PHASE_SHIFT) | hi);
          if (!r || r.updatedAt > ts) break;
          lo = hi;
          hi *= 2n;
        }
      }
      while (hi - lo > 1n) {
        const mid = (lo + hi) / 2n;
        const r = await tryRound(client, feed, (phase << PHASE_SHIFT) | mid);
        if (r && r.updatedAt <= ts) lo = mid;
        else hi = mid;
      }
      return (phase << PHASE_SHIFT) | lo;
    }
    phase -= 1n;
    hi = 0n;
  }
  throw new Error(`no round at or before ${ts} on feed ${feed}`);
}
