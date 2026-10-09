"use client";

import { erc20Abi, type Address } from "viem";
import { useReadContracts } from "wagmi";

/** Balance + allowance of `owner` for `token` towards `spender`. */
export function useErc20(token?: Address, owner?: Address, spender?: Address) {
  const enabled = !!token && !!owner;
  const r = useReadContracts({
    contracts: [
      { address: token!, abi: erc20Abi, functionName: "balanceOf", args: [owner!] },
      { address: token!, abi: erc20Abi, functionName: "allowance", args: [owner!, spender ?? owner!] },
    ],
    query: { enabled, refetchInterval: 12_000 },
  });
  return {
    balance: r.data?.[0]?.result as bigint | undefined,
    allowance: r.data?.[1]?.result as bigint | undefined,
    refetch: r.refetch,
  };
}

export { erc20Abi };
