import { stockTokens, contracts } from "@floorcap/config";
import type { Address } from "viem";

const bySymbol = new Map(stockTokens.map((t) => [t.address.toLowerCase(), t]));

export function tokenSymbol(addr: Address | string): string {
  if (addr.toLowerCase() === contracts.USDG.address.toLowerCase()) return "USDG";
  return bySymbol.get(addr.toLowerCase())?.symbol ?? `${addr.slice(0, 6)}...`;
}

export function tokenName(addr: Address | string): string {
  return bySymbol.get(addr.toLowerCase())?.name ?? tokenSymbol(addr);
}

export const STABLE_DECIMALS = contracts.USDG.decimals;
