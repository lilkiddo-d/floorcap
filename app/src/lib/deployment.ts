"use client";

import { useQuery } from "@tanstack/react-query";
import type { Address } from "viem";
import { CHAIN_ID } from "./chains";

export type Deployment = {
  chainId: number;
  deployedAtBlock: number;
  stable: Address;
  Timelock: Address;
  MarketClock: Address;
  OracleAdapter: Address;
  Note: Address;
  ComplianceRegistry: Address;
  FeeCollector: Address;
  ProjectTokenHooks: Address;
  SeriesFactory: Address;
  UnderwriterPool: Address;
  Settlement: Address;
  SecondaryListings: Address;
  HoldYieldAdapter: Address;
  ERC4626YieldAdapter: Address;
};

/** Written by contracts/script/Deploy.s.sol to app/public/deployments/<chainId>.json. */
export function useDeployment() {
  return useQuery({
    queryKey: ["deployment", CHAIN_ID],
    queryFn: async (): Promise<Deployment | null> => {
      const res = await fetch(`/deployments/${CHAIN_ID}.json`, { cache: "no-store" });
      if (!res.ok) return null;
      return (await res.json()) as Deployment;
    },
    staleTime: Infinity,
  });
}
