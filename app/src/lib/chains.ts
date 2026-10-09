import { defineChain } from "viem";
import { robinhoodChain } from "@floorcap/config";

/** 4663 = Robinhood Chain mainnet, 31337 = local anvil fork of mainnet (same token/oracle addresses). */
export const CHAIN_ID = Number(process.env.NEXT_PUBLIC_CHAIN_ID || 4663);
export const IS_FORK = CHAIN_ID === 31337;

const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11" as const; // deployed on Robinhood Chain

const rpc =
  process.env.NEXT_PUBLIC_RPC_URL || (IS_FORK ? "http://127.0.0.1:18645" : robinhoodChain.rpcUrls.default.http[0]);

export const robinhood = defineChain({
  id: robinhoodChain.id,
  name: robinhoodChain.name,
  nativeCurrency: robinhoodChain.nativeCurrency,
  rpcUrls: { default: { http: [IS_FORK ? robinhoodChain.rpcUrls.default.http[0] : rpc] } },
  blockExplorers: robinhoodChain.blockExplorers,
  contracts: { multicall3: { address: MULTICALL3 } },
});

export const robinhoodFork = defineChain({
  id: 31337,
  name: "Robinhood Chain (local fork)",
  nativeCurrency: robinhoodChain.nativeCurrency,
  rpcUrls: { default: { http: [rpc] } },
  contracts: { multicall3: { address: MULTICALL3 } },
  testnet: true,
});

export const activeChain = IS_FORK ? robinhoodFork : robinhood;

export function explorerTx(hash: string) {
  return IS_FORK ? undefined : `${robinhoodChain.blockExplorers.default.url}/tx/${hash}`;
}

export function explorerAddress(addr: string) {
  return IS_FORK ? undefined : `${robinhoodChain.blockExplorers.default.url}/address/${addr}`;
}
