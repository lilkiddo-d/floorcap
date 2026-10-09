"use client";

import { useParams } from "next/navigation";
import { useState } from "react";
import { formatUnits, parseUnits, maxUint256 } from "viem";
import { useAccount, useReadContract } from "wagmi";
import { SeriesFactoryAbi, ProjectTokenHooksAbi } from "@/abi";
import { PayoffDiagram } from "@/components/PayoffDiagram";
import { basketLabel } from "@/components/SeriesCard";
import { TxStatus } from "@/components/TxStatus";
import { useSeriesList } from "@/hooks/useSeries";
import { useErc20, erc20Abi } from "@/hooks/useErc20";
import { useTx } from "@/hooks/useTx";
import { fmtBps, fmtDate, fmtNum, fmtPctWad, fmtStable, fmtUsdWad } from "@/lib/format";
import { noteValue } from "@/lib/payoff";
import { stateName } from "@/lib/series";
import { PROJECT_TOKEN } from "@/lib/token";

export default function SeriesDetail() {
  const params = useParams<{ id: string }>();
  const id = BigInt(params.id);
  const { series, deployment: dep } = useSeriesList();
  const s = series.find((x) => x.id === id);
  const { address } = useAccount();
  const [amount, setAmount] = useState("1000");
  const [scenario, setScenario] = useState("20");
  const tx = useTx();

  const usdg = useErc20(s?.stable, address, dep?.SeriesFactory);
  const deposit = useReadContract({
    address: dep?.SeriesFactory,
    abi: SeriesFactoryAbi,
    functionName: "deposits",
    args: [id, address!],
    query: { enabled: !!dep && !!address, refetchInterval: 12_000 },
  });
  const level = useReadContract({
    address: dep?.SeriesFactory,
    abi: SeriesFactoryAbi,
    functionName: "basketLevelLatest",
    args: [id],
    query: { enabled: !!dep, refetchInterval: 30_000 },
  });
  const priority = useReadContract({
    address: dep?.ProjectTokenHooks,
    abi: ProjectTokenHooksAbi,
    functionName: "isPriority",
    args: [address!, s?.createdAt ?? 0n],
    query: { enabled: !!PROJECT_TOKEN && !!dep && !!address && !!s },
  });

  if (!s || !dep) return <p className="empty">Loading series...</p>;

  const st = stateName(s.state);
  const now = BigInt(Math.floor(Date.now() / 1000));
  const open = st === "Subscription" && now >= s.subscriptionStart && now < s.subscriptionEnd;
  const protection = s.protectionBps / 10_000;
  const participation = Number(formatUnits(s.participationWad, 18));
  const bond = Number(formatUnits(s.bondWad, 18));
  const fee = s.structuringFeeBps / 10_000;
  const amt = (() => {
    try {
      return parseUnits(amount || "0", 6);
    } catch {
      return 0n;
    }
  })();
  const needsApproval = (usdg.allowance ?? 0n) < amt;
  const dep_ = deposit.data as readonly [bigint, bigint] | undefined;
  const myDeposit = dep_ ? dep_[0] + dep_[1] : 0n;
  const r = Number(scenario) / 100;
  const per1000 = 1000 * noteValue(isFinite(r) ? r : 0, protection, participation);

  return (
    <>
      <div className="row between">
        <div>
          <h1>{s.name}</h1>
          <p className="muted">
            {basketLabel(s)} · {s.tenorMonths}-month · series #{s.id.toString()}
          </p>
        </div>
        <span className={`pill ${st.toLowerCase()}`}>{st}</span>
      </div>

      <div className="two-col">
        <div className="card">
          <h3>Payoff at maturity</h3>
          <PayoffDiagram protection={protection} participation={participation} width={560} height={300} />
          <p className="small muted">
            Floor of {fmtBps(s.protectionBps, 0)} of principal in USDG, plus {fmtPctWad(s.participationWad, 0)} of any
            basket gain above the strike, paid in the basket&apos;s stock tokens. The floor assumes the yield source stays
            solvent: see <a href="/risk">risks</a>.
          </p>
          <div className="row">
            <label style={{ flex: 1 }}>
              If the basket returns (%)
              <input value={scenario} onChange={(e) => setScenario(e.target.value)} inputMode="decimal" />
            </label>
            <div className="card" style={{ flex: 1 }}>
              <div className="muted small">1,000 USDG note returns</div>
              <div style={{ fontSize: 22, fontWeight: 700 }}>{fmtNum(per1000)} USDG</div>
              <div className="muted small">holding the basket: {fmtNum(1000 * (1 + (isFinite(r) ? r : 0)))}</div>
            </div>
          </div>
        </div>

        <div className="card">
          <h3>Terms</h3>
          <dl className="stats wide">
            <div><dt>Protection</dt><dd>{fmtBps(s.protectionBps, 0)}</dd></div>
            <div><dt>Participation</dt><dd>{fmtPctWad(s.participationWad)}</dd></div>
            <div><dt>Strike</dt><dd>{s.strike > 0n ? fmtUsdWad(s.strike) : "set at close"}</dd></div>
            <div><dt>Basket now</dt><dd>{level.data !== undefined ? fmtUsdWad(level.data as bigint) : "-"}</dd></div>
            <div><dt>Assumed yield</dt><dd>{fmtBps(s.assumedYieldBps)}</dd></div>
            <div><dt>Call premium</dt><dd>{fmtBps(s.premiumBps)}</dd></div>
            <div><dt>Structuring fee</dt><dd>{fmtBps(s.structuringFeeBps)}</dd></div>
            <div><dt>Early exit fee</dt><dd>{fmtBps(s.exitFeeBps)}</dd></div>
            <div><dt>Cap</dt><dd>{fmtStable(s.cap, 6, 0)}</dd></div>
            <div><dt>Subscribed</dt><dd>{fmtStable(s.priorityDeposits + s.regularDeposits, 6, 0)}</dd></div>
            <div><dt>Notes live</dt><dd>{fmtStable(s.liveNotes, 6, 0)}</dd></div>
            <div><dt>Subscription ends</dt><dd className="small">{fmtDate(s.subscriptionEnd)}</dd></div>
            <div><dt>Maturity (US close)</dt><dd className="small">{fmtDate(s.maturity)}</dd></div>
          </dl>
          <h3 style={{ marginTop: 16 }}>Where 1,000 USDG goes</h3>
          <table>
            <tbody>
              <tr><td>Bond leg (yield source, grows to the floor)</td><td>{fmtNum(1000 * bond)}</td></tr>
              <tr><td>Calls bought from underwriters</td><td>{fmtNum(1000 * (1 - bond - fee))}</td></tr>
              <tr><td>Structuring fee</td><td>{fmtNum(1000 * fee)}</td></tr>
            </tbody>
          </table>
        </div>
      </div>

      <div className="two-col" style={{ marginTop: 16 }}>
        <div className="card form">
          <h3>Subscribe</h3>
          {!address && <p className="muted">Connect a wallet to subscribe.</p>}
          {address && (
            <>
              <p className="small muted">
                Wallet: {fmtStable(usdg.balance)} USDG · Your subscription: {fmtStable(myDeposit)} USDG
                {PROJECT_TOKEN && priority.data ? " · priority allocation (staker)" : ""}
              </p>
              <label>
                Amount (USDG)
                <input value={amount} onChange={(e) => setAmount(e.target.value)} inputMode="decimal" disabled={!open} />
              </label>
              <div className="row">
                {needsApproval ? (
                  <button
                    disabled={!open || tx.busy || amt === 0n}
                    onClick={() =>
                      tx.send({ address: s.stable, abi: erc20Abi, functionName: "approve", args: [dep.SeriesFactory, maxUint256], label: "Approve USDG" })
                    }
                  >
                    Approve USDG
                  </button>
                ) : (
                  <button
                    disabled={!open || tx.busy || amt === 0n}
                    onClick={() => tx.send({ address: dep.SeriesFactory, abi: SeriesFactoryAbi, functionName: "subscribe", args: [id, amt], label: "Subscribe" })}
                  >
                    Subscribe
                  </button>
                )}
                <button
                  className="secondary"
                  disabled={!open || tx.busy || myDeposit === 0n || amt === 0n || amt > myDeposit}
                  onClick={() => tx.send({ address: dep.SeriesFactory, abi: SeriesFactoryAbi, functionName: "withdrawSubscription", args: [id, amt], label: "Withdraw" })}
                >
                  Withdraw
                </button>
              </div>
              {!open && st === "Subscription" && <p className="small muted">Subscription window is not open.</p>}
              <p className="small muted">
                If the series is oversubscribed, stakers are filled first and everyone else pro-rata; any unallocated
                amount is refunded when you claim your allocation.
              </p>
            </>
          )}
          <TxStatus status={tx.status} />
        </div>

        <div className="card form">
          <h3>Allocation</h3>
          {st === "Subscription" && <p className="muted">Allocations are set when the series locks at the subscription close.</p>}
          {(st === "Locked" || st === "Settled" || st === "Cancelled") && (
            <>
              <p className="muted">
                {st === "Cancelled"
                  ? "This series was cancelled. Your full subscription is refundable."
                  : `Priority fill ${fmtPctWad(s.priorityFillWad)} · regular fill ${fmtPctWad(s.regularFillWad)}.`}
              </p>
              <p>Pending: {fmtStable(myDeposit)} USDG</p>
              <button
                disabled={!address || myDeposit === 0n || tx.busy}
                onClick={() => tx.send({ address: dep.SeriesFactory, abi: SeriesFactoryAbi, functionName: "claimAllocation", args: [id, address!], label: "Claim allocation" })}
              >
                {st === "Cancelled" ? "Claim refund" : "Claim notes + refund"}
              </button>
            </>
          )}
          <p className="small muted">
            Lock and settlement are permissionless and run by the keeper using the Chainlink round in effect at the US
            close.
          </p>
        </div>
      </div>
    </>
  );
}
