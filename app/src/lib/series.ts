import type { Address } from "viem";

export const STATES = ["None", "Subscription", "Locked", "Settled", "Cancelled"] as const;
export type SeriesStateName = (typeof STATES)[number];

export type Series = {
  id: bigint;
  name: string;
  stable: Address;
  yieldAdapter: Address;
  optionsAdapter: Address;
  createdAt: bigint;
  subscriptionStart: bigint;
  subscriptionEnd: bigint;
  maturity: bigint;
  tenorMonths: number;
  state: number;
  protectionBps: number;
  assumedYieldBps: number;
  premiumBps: number;
  structuringFeeBps: number;
  exitFeeBps: number;
  bondWad: bigint;
  participationWad: bigint;
  cap: bigint;
  minSize: bigint;
  priorityDeposits: bigint;
  regularDeposits: bigint;
  accepted: bigint;
  liveNotes: bigint;
  priorityFillWad: bigint;
  regularFillWad: bigint;
  strike: bigint;
  units: bigint;
  tokens: Address[];
  quantities: bigint[];
};

export function stateName(s: number): SeriesStateName {
  return STATES[s] ?? "None";
}
