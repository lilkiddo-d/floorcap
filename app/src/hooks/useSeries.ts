"use client";

import { useReadContract, useReadContracts } from "wagmi";
import { SeriesFactoryAbi } from "@/abi";
import { useDeployment } from "@/lib/deployment";
import type { Series } from "@/lib/series";

/** Loads every series (bounded by seriesCount) with its basket and name. */
export function useSeriesList() {
  const { data: dep } = useDeployment();
  const factory = dep?.SeriesFactory;
  const count = useReadContract({
    address: factory,
    abi: SeriesFactoryAbi,
    functionName: "seriesCount",
    query: { enabled: !!factory, refetchInterval: 15_000 },
  });
  const n = Number(count.data ?? 0n);
  const ids = Array.from({ length: n }, (_, i) => BigInt(i + 1));
  const reads = useReadContracts({
    contracts: ids.flatMap((id) => [
      { address: factory!, abi: SeriesFactoryAbi, functionName: "getSeries", args: [id] } as const,
      { address: factory!, abi: SeriesFactoryAbi, functionName: "getBasket", args: [id] } as const,
      { address: factory!, abi: SeriesFactoryAbi, functionName: "seriesName", args: [id] } as const,
    ]),
    query: { enabled: !!factory && n > 0, refetchInterval: 15_000 },
  });
  const series: Series[] = [];
  if (reads.data) {
    for (let i = 0; i < n; i++) {
      const s = reads.data[i * 3]?.result as Omit<Series, "id" | "name" | "tokens" | "quantities"> | undefined;
      const b = reads.data[i * 3 + 1]?.result as readonly [readonly `0x${string}`[], readonly bigint[]] | undefined;
      const name = reads.data[i * 3 + 2]?.result as string | undefined;
      if (!s || !b) continue;
      series.push({
        ...s,
        id: ids[i],
        name: name ?? `Series ${i + 1}`,
        tokens: [...b[0]],
        quantities: [...b[1]],
        tenorMonths: Number(s.tenorMonths),
        state: Number(s.state),
        protectionBps: Number(s.protectionBps),
        assumedYieldBps: Number(s.assumedYieldBps),
        premiumBps: Number(s.premiumBps),
        structuringFeeBps: Number(s.structuringFeeBps),
        exitFeeBps: Number(s.exitFeeBps),
      });
    }
  }
  return {
    series,
    isLoading: count.isLoading || reads.isLoading,
    error: count.error ?? reads.error,
    deployment: dep,
    refetch: () => {
      count.refetch();
      reads.refetch();
    },
  };
}
