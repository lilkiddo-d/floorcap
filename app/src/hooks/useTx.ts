"use client";

import { useState } from "react";
import { usePublicClient, useWriteContract } from "wagmi";
import { useQueryClient } from "@tanstack/react-query";
import type { Abi } from "viem";

type Status = { state: "idle" | "pending" | "mining" | "done" | "error"; message?: string; hash?: string };

/** writeContract + wait for receipt + refresh every query. */
export function useTx() {
  const { writeContractAsync } = useWriteContract();
  const client = usePublicClient();
  const qc = useQueryClient();
  const [status, setStatus] = useState<Status>({ state: "idle" });

  async function send(args: {
    address: `0x${string}`;
    abi: Abi | readonly unknown[];
    functionName: string;
    args?: readonly unknown[];
    label?: string;
  }) {
    try {
      setStatus({ state: "pending", message: `Confirm ${args.label ?? args.functionName} in your wallet` });
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const hash = await writeContractAsync(args as any);
      setStatus({ state: "mining", hash, message: "Waiting for confirmation" });
      const receipt = await client!.waitForTransactionReceipt({ hash });
      if (receipt.status !== "success") throw new Error("Transaction reverted");
      setStatus({ state: "done", hash, message: `${args.label ?? args.functionName} confirmed` });
      await qc.invalidateQueries();
      return receipt;
    } catch (e) {
      const msg = (e as { shortMessage?: string; message?: string }).shortMessage ?? (e as Error).message;
      setStatus({ state: "error", message: msg });
      throw e;
    }
  }

  return { send, status, busy: status.state === "pending" || status.state === "mining" };
}
