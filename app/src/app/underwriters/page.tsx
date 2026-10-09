"use client";

import Link from "next/link";
import { useState } from "react";
import { erc20Abi, formatUnits, maxUint256, parseUnits } from "viem";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { UnderwriterPoolAbi } from "@/abi";
import { TxStatus } from "@/components/TxStatus";
import { basketLabel } from "@/components/SeriesCard";
import { useSeriesList } from "@/hooks/useSeries";
import { useTx } from "@/hooks/useTx";
import type { Deployment } from "@/lib/deployment";
import type { Series } from "@/lib/series";
import { stateName } from "@/lib/series";
import { fmtBps, fmtDate, fmtStable, fmtToken } from "@/lib/format";
import { tokenSymbol } from "@/lib/tokens";

const POOL_STATUS = ["Collecting", "Active", "Closed", "Cancelled"];

export default function Underwriters() {
  const { series, deployment: dep } = useSeriesList();
  const relevant = series.filter((s) => s.state !== 0).sort((a, b) => Number(b.id - a.id));
  return (
    <>
      <h1>Underwrite</h1>
      <p className="muted">
        Sell fully collateralized (covered) calls to a note series and earn its call premium. You post the basket&apos;s
        stock tokens; at maturity note holders receive the basket&apos;s gain above the strike out of the pooled
        collateral, and you keep the premium plus everything else. Your collateral always covers the maximum payout, so
        no liquidations, but you give up upside above the strike on the portion that is sold.
      </p>
      {!dep && <p className="empty">Loading...</p>}
      {dep && relevant.length === 0 && <p className="empty">No series to underwrite yet.</p>}
      {dep && relevant.map((s) => <PoolCard key={s.id.toString()} s={s} dep={dep} />)}
    </>
  );
}

type PoolSeries = {
  status: number;
  totalCommitted: bigint;
  used: bigint;
  open: bigint;
  paid: bigint;
  strike: bigint;
  premiumToken: `0x${string}`;
  premium: bigint;
};

function PoolCard({ s, dep }: { s: Series; dep: Deployment }) {
  const { address } = useAccount();
  const tx = useTx();
  const [units, setUnits] = useState("10");
  const pool = useReadContract({
    address: dep.UnderwriterPool,
    abi: UnderwriterPoolAbi,
    functionName: "poolOf",
    args: [s.id],
    query: { refetchInterval: 15_000 },
  });
  const pos = useReadContract({
    address: dep.UnderwriterPool,
    abi: UnderwriterPoolAbi,
    functionName: "positions",
    args: [s.id, address!],
    query: { enabled: !!address, refetchInterval: 15_000 },
  });
  const allowances = useReadContracts({
    contracts: s.tokens.map((t) => ({
      address: t,
      abi: erc20Abi,
      functionName: "allowance",
      args: [address!, dep.UnderwriterPool],
    })),
    query: { enabled: !!address, refetchInterval: 15_000 },
  });
  const p = pool.data as PoolSeries | undefined;
  const position = pos.data as readonly [bigint, boolean, boolean, boolean] | undefined;
  const st = stateName(s.state);
  let u = 0n;
  try {
    u = parseUnits(units || "0", 18);
  } catch {}
  const needs = s.tokens.map((t, i) => ({ t, amount: (u * s.quantities[i] + 10n ** 18n - 1n) / 10n ** 18n }));
  const missingApproval = needs.find((n, i) => ((allowances.data?.[i]?.result as bigint | undefined) ?? 0n) < n.amount);
  const committed = position?.[0] ?? 0n;
  const share = p && p.totalCommitted > 0n ? Number(formatUnits((committed * 10n ** 18n) / p.totalCommitted, 18)) : 0;
  const poolStatus = p ? POOL_STATUS[p.status] : "-";
  const collecting = st === "Subscription" && p?.status === 0 && Date.now() / 1000 < Number(s.subscriptionEnd);

  const call = (functionName: string, label: string, args: readonly unknown[] = [s.id]) =>
    tx.send({ address: dep.UnderwriterPool, abi: UnderwriterPoolAbi, functionName, args, label });

  return (
    <div className="card" style={{ marginBottom: 12 }}>
      <div className="row between">
        <div>
          <h3>
            <Link href={`/series/${s.id}`}>{s.name}</Link>
          </h3>
          <p className="muted small">
            {basketLabel(s)} · premium {fmtBps(s.premiumBps)} of notional · subscription ends {fmtDate(s.subscriptionEnd)}
          </p>
        </div>
        <span className="pill">{poolStatus}</span>
      </div>
      <dl className="stats wide">
        <div><dt>Committed (basket units)</dt><dd>{fmtToken(p?.totalCommitted, 2)}</dd></div>
        <div><dt>Sold to note</dt><dd>{fmtToken(p?.used, 2)}</dd></div>
        <div><dt>Open calls</dt><dd>{fmtToken(p?.open, 2)}</dd></div>
        <div><dt>Premium pool</dt><dd>{fmtStable(p?.premium)} USDG</dd></div>
        <div><dt>Paid to holders</dt><dd>{fmtToken(p?.paid, 4)}</dd></div>
        <div><dt>Your commitment</dt><dd>{fmtToken(committed, 2)} ({(share * 100).toFixed(1)}%)</dd></div>
      </dl>
      {collecting && address && (
        <div className="form" style={{ maxWidth: 520 }}>
          <label>
            Basket units to commit (1 unit = {s.tokens.map((t, i) => `${formatUnits(s.quantities[i], 18)} ${tokenSymbol(t)}`).join(" + ")})
            <input value={units} onChange={(e) => setUnits(e.target.value)} />
          </label>
          <p className="small muted">
            Posts {needs.map((n) => `${fmtToken(n.amount)} ${tokenSymbol(n.t)}`).join(" + ")}
          </p>
          <div className="row">
            {missingApproval ? (
              <button
                disabled={tx.busy}
                onClick={() => tx.send({ address: missingApproval.t, abi: erc20Abi, functionName: "approve", args: [dep.UnderwriterPool, maxUint256], label: `Approve ${tokenSymbol(missingApproval.t)}` })}
              >
                Approve {tokenSymbol(missingApproval.t)}
              </button>
            ) : (
              <button disabled={tx.busy || u === 0n} onClick={() => call("commit", "Commit", [s.id, u])}>
                Commit collateral
              </button>
            )}
            <button className="secondary" disabled={tx.busy || u === 0n || u > committed} onClick={() => call("uncommit", "Uncommit", [s.id, u])}>
              Uncommit
            </button>
          </div>
        </div>
      )}
      {address && committed > 0n && p && p.status >= 1 && (
        <div className="row" style={{ marginTop: 8 }}>
          {(p.status === 1 || p.status === 2) && !position?.[1] && (
            <button className="secondary" disabled={tx.busy} onClick={() => call("withdrawUnused", "Withdraw unused")}>
              Withdraw unsold collateral
            </button>
          )}
          {(p.status === 1 || p.status === 2) && !position?.[2] && (
            <button disabled={tx.busy} onClick={() => call("claimPremium", "Claim premium")}>
              Claim premium
            </button>
          )}
          {p.status === 2 && !position?.[3] && (
            <button disabled={tx.busy} onClick={() => call("claimFinal", "Claim collateral")}>
              Claim remaining collateral
            </button>
          )}
          {p.status === 3 && (
            <button disabled={tx.busy} onClick={() => call("withdrawCancelled", "Withdraw")}>
              Withdraw (series cancelled)
            </button>
          )}
        </div>
      )}
      <TxStatus status={tx.status} />
    </div>
  );
}
