"use client";

import Link from "next/link";
import { useState } from "react";
import { parseUnits } from "viem";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { NoteAbi, SettlementAbi, SecondaryListingsAbi } from "@/abi";
import { TxStatus } from "@/components/TxStatus";
import { basketLabel } from "@/components/SeriesCard";
import { useSeriesList } from "@/hooks/useSeries";
import { useTx } from "@/hooks/useTx";
import type { Series } from "@/lib/series";
import { stateName } from "@/lib/series";
import type { Deployment } from "@/lib/deployment";
import { fmtDate, fmtStable, fmtToken, fmtUsdWad } from "@/lib/format";
import { tokenSymbol } from "@/lib/tokens";

export default function Portfolio() {
  const { address } = useAccount();
  const { series, deployment: dep } = useSeriesList();
  const held = useReadContracts({
    contracts: series.map((s) => ({
      address: dep?.Note as `0x${string}`,
      abi: NoteAbi,
      functionName: "balanceOf",
      args: [address!, s.id],
    })),
    query: { enabled: !!dep && !!address && series.length > 0, refetchInterval: 15_000 },
  });

  if (!address) return <p className="empty">Connect a wallet to see your notes.</p>;
  if (!dep) return <p className="empty">Loading...</p>;

  const rows = series
    .map((s, i) => ({ s, bal: (held.data?.[i]?.result as bigint | undefined) ?? 0n }))
    .filter((r) => r.bal > 0n);

  return (
    <>
      <h1>My notes</h1>
      <p className="muted">
        Mark value = what an early exit would pay right now (bond leg at its current value plus the calls&apos; intrinsic
        value at the live oracle price, net of the exit fee). Pending allocations are on each{" "}
        <Link href="/">series page</Link>.
      </p>
      {rows.length === 0 && <p className="empty">You hold no notes yet.</p>}
      {rows.map(({ s, bal }) => (
        <NoteRow key={s.id.toString()} s={s} bal={bal} dep={dep} />
      ))}
    </>
  );
}

function NoteRow({ s, bal, dep }: { s: Series; bal: bigint; dep: Deployment }) {
  const st = stateName(s.state);
  const tx = useTx();
  const [exitAmt, setExitAmt] = useState("");
  const [listAmt, setListAmt] = useState("");
  const [listPrice, setListPrice] = useState("1.00");
  const { address } = useAccount();

  const mark = useReadContract({
    address: dep.Settlement,
    abi: SettlementAbi,
    functionName: "previewValue",
    args: [s.id, bal],
    query: { enabled: st === "Locked" || st === "Settled", refetchInterval: 20_000 },
  });
  const approved = useReadContract({
    address: dep.Note,
    abi: NoteAbi,
    functionName: "isApprovedForAll",
    args: [address!, dep.SecondaryListings],
    query: { enabled: !!address },
  });
  const m = mark.data as readonly [bigint, readonly bigint[], bigint] | undefined;
  const parse = (v: string) => {
    try {
      return parseUnits(v || "0", 6);
    } catch {
      return 0n;
    }
  };
  const exitAmount = parse(exitAmt);
  const listAmount = parse(listAmt);
  const nowSec = Math.floor(Date.now() / 1000);

  async function doExit() {
    // Slippage guard: accept up to 0.5% less cash than previewed for this amount.
    const preview = m && bal > 0n ? (m[0] * exitAmount) / bal : 0n;
    await tx.send({
      address: dep.Settlement,
      abi: SettlementAbi,
      functionName: "earlyExit",
      args: [s.id, exitAmount, (preview * 995n) / 1000n, BigInt(nowSec + 600)],
      label: "Early exit",
    });
  }

  return (
    <div className="card" style={{ marginBottom: 12 }}>
      <div className="row between">
        <div>
          <h3>
            <Link href={`/series/${s.id}`}>{s.name}</Link>
          </h3>
          <p className="muted small">
            {basketLabel(s)} · matures {fmtDate(s.maturity)}
          </p>
        </div>
        <span className={`pill ${st.toLowerCase()}`}>{st}</span>
      </div>
      <dl className="stats wide">
        <div><dt>Principal</dt><dd>{fmtStable(bal)} USDG</dd></div>
        <div><dt>Floor at maturity</dt><dd>{fmtStable((bal * BigInt(s.protectionBps)) / 10_000n)} USDG</dd></div>
        <div>
          <dt>{st === "Settled" ? "Claim value" : "Mark value now"}</dt>
          <dd>{m ? fmtUsdWad(m[2]) : mark.isError ? "oracle unavailable" : "..."}</dd>
        </div>
        <div>
          <dt>Paid as</dt>
          <dd className="small">
            {m
              ? `${fmtStable(m[0])} USDG` +
                s.tokens.map((t, i) => (m[1][i] > 0n ? ` + ${fmtToken(m[1][i])} ${tokenSymbol(t)}` : "")).join("")
              : "-"}
          </dd>
        </div>
      </dl>

      {st === "Settled" && (
        <button
          disabled={tx.busy}
          onClick={() => tx.send({ address: dep.Settlement, abi: SettlementAbi, functionName: "claim", args: [s.id, bal], label: "Claim" })}
        >
          Claim payout
        </button>
      )}

      {st === "Locked" && (
        <div className="two-col" style={{ marginTop: 8 }}>
          <div className="form">
            <label>
              Early exit amount (notes, regular US session only, {s.exitFeeBps / 100}% fee)
              <input value={exitAmt} onChange={(e) => setExitAmt(e.target.value)} placeholder="e.g. 500" />
            </label>
            <button disabled={tx.busy || exitAmount === 0n || exitAmount > bal || !m} onClick={doExit}>
              Exit early
            </button>
          </div>
          <div className="form">
            <label>
              List on secondary: amount and price per note (USDG)
              <div className="row">
                <input value={listAmt} onChange={(e) => setListAmt(e.target.value)} placeholder="amount" style={{ flex: 1 }} />
                <input value={listPrice} onChange={(e) => setListPrice(e.target.value)} style={{ width: 90 }} />
              </div>
            </label>
            {approved.data ? (
              <button
                className="secondary"
                disabled={tx.busy || listAmount === 0n || listAmount > bal}
                onClick={() =>
                  tx.send({
                    address: dep.SecondaryListings,
                    abi: SecondaryListingsAbi,
                    functionName: "list",
                    args: [s.id, listAmount, parseUnits(listPrice || "0", 18), BigInt(nowSec + 30 * 86400)],
                    label: "List notes",
                  })
                }
              >
                List for 30 days
              </button>
            ) : (
              <button
                className="secondary"
                disabled={tx.busy}
                onClick={() =>
                  tx.send({ address: dep.Note, abi: NoteAbi, functionName: "setApprovalForAll", args: [dep.SecondaryListings, true], label: "Approve listings" })
                }
              >
                Approve listing contract
              </button>
            )}
          </div>
        </div>
      )}
      <TxStatus status={tx.status} />
    </div>
  );
}
