import type { Address } from "viem";

/** Project token address from env. Empty = every token feature is hidden (see TOKEN_INTEGRATION.md). */
const raw = (process.env.NEXT_PUBLIC_PROJECT_TOKEN ?? "").trim();
export const PROJECT_TOKEN: Address | undefined = /^0x[0-9a-fA-F]{40}$/.test(raw) ? (raw as Address) : undefined;
