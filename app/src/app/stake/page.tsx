"use client";

import { useState } from "react";
import { maxUint256, parseUnits } from "viem";
import { useAccount, useReadContracts } from "wagmi";
import { ProjectTokenHooksAbi } from "@/abi";
import { TxStatus } from "@/components/TxStatus";
import { useErc20, erc20Abi } from "@/hooks/useErc20";
import { useTx } from "@/hooks/useTx";
import { useDeployment } from "@/lib/deployment";
import { fmtDate, fmtStable, fmtToken } from "@/lib/format";
import { PROJECT_TOKEN } from "@/lib/token";

export default function Stake() {
  const { data: dep } = useDeployment();
  const { address } = useAccount();
  const tx = useTx();
  const [amount, setAmount] = useState("");
  const hooks = dep?.ProjectTokenHooks;
  const reads = useReadContracts({
    contracts: [
      { address: hooks!, abi: ProjectTokenHooksAbi, functionName: "isActive" },
      { address: hooks!, abi: ProjectTokenHooksAbi, functionName: "stakedOf", args: [address!] },
      { address: hooks!, abi: ProjectTokenHooksAbi, functionName: "earned", args: [address!] },
      { address: hooks!, abi: ProjectTokenHooksAbi, functionName: "pendingUnstake", args: [address!] },
      { address: hooks!, abi: ProjectTokenHooksAbi, functionName: "totalStaked" },
      { address: hooks!, abi: ProjectTokenHooksAbi, functionName: "minPriorityStake" },
    ],
    query: { enabled: !!hooks && !!address && !!PROJECT_TOKEN, refetchInterval: 15_000 },
  });
  const tok = useErc20(PROJECT_TOKEN, address, hooks);

  if (!PROJECT_TOKEN) return <p className="empty">Token features are not enabled.</p>;
  const [active, staked, earned, pending, total, minPriority] = (reads.data ?? []).map((r) => r.result) as [
    boolean?, bigint?, bigint?, (readonly [bigint, bigint])?, bigint?, bigint?,
  ];
  let amt = 0n;
  try {
    amt = parseUnits(amount || "0", 18);
  } catch {}

  return (
    <>
      <h1>Stake $FCAP</h1>
      <p className="muted">
        Stakers get priority allocation in oversubscribed series (if staked before the series was created and at least
        the minimum) and a share of structuring fees, paid in USDG. Unstaking has a cooldown.
      </p>
      {active === false && <p className="notice">The token is configured in the app but not yet wired on-chain (setProjectToken pending in the Timelock).</p>}
      {!address && <p className="empty">Connect a wallet.</p>}
      {address && (
        <div className="two-col">
          <div className="card">
            <dl className="stats wide">
              <div><dt>Your stake</dt><dd>{fmtToken(staked, 2)}</dd></div>
              <div><dt>Total staked</dt><dd>{fmtToken(total, 0)}</dd></div>
              <div><dt>Priority minimum</dt><dd>{fmtToken(minPriority, 0)}</dd></div>
              <div><dt>Rewards</dt><dd>{fmtStable(earned)} USDG</dd></div>
              <div><dt>Unstaking</dt><dd>{fmtToken(pending?.[0], 2)}</dd></div>
              <div><dt>Available</dt><dd className="small">{pending && pending[0] > 0n ? fmtDate(pending[1]) : "-"}</dd></div>
            </dl>
            <div className="row">
              <button disabled={tx.busy || !earned} onClick={() => tx.send({ address: hooks!, abi: ProjectTokenHooksAbi, functionName: "claimRewards", label: "Claim rewards" })}>
                Claim rewards
              </button>
              <button
                className="secondary"
                disabled={tx.busy || !pending || pending[0] === 0n || Number(pending[1]) > Date.now() / 1000}
                onClick={() => tx.send({ address: hooks!, abi: ProjectTokenHooksAbi, functionName: "withdraw", label: "Withdraw" })}
              >
                Withdraw unstaked
              </button>
            </div>
          </div>
          <div className="card form">
            <label>
              Amount ($FCAP) · wallet {fmtToken(tok.balance, 2)}
              <input value={amount} onChange={(e) => setAmount(e.target.value)} />
            </label>
            <div className="row">
              {(tok.allowance ?? 0n) < amt ? (
                <button disabled={tx.busy} onClick={() => tx.send({ address: PROJECT_TOKEN!, abi: erc20Abi, functionName: "approve", args: [hooks!, maxUint256], label: "Approve" })}>
                  Approve
                </button>
              ) : (
                <button disabled={tx.busy || amt === 0n || !active} onClick={() => tx.send({ address: hooks!, abi: ProjectTokenHooksAbi, functionName: "stake", args: [amt], label: "Stake" })}>
                  Stake
                </button>
              )}
              <button className="secondary" disabled={tx.busy || amt === 0n || !staked || amt > staked} onClick={() => tx.send({ address: hooks!, abi: ProjectTokenHooksAbi, functionName: "requestUnstake", args: [amt], label: "Unstake" })}>
                Request unstake
              </button>
            </div>
          </div>
        </div>
      )}
      <TxStatus status={tx.status} />
    </>
  );
}
