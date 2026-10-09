"use client";

import Link from "next/link";
import { formatUnits } from "viem";
import { useReadContracts } from "wagmi";
import { SettlementAbi } from "@/abi";
import { useSeriesList } from "@/hooks/useSeries";
import { fmtDate, fmtNum, fmtStable, fmtToken, fmtUsdWad } from "@/lib/format";
import { tokenSymbol } from "@/lib/tokens";

type Result = {
  level: bigint;
  cash: bigint;
  notes: bigint;
  payoutUnits: bigint;
  reserveUsed: bigint;
  settledAt: bigint;
  manual: boolean;
};

export default function Settlements() {
  const { series, deployment: dep } = useSeriesList();
  const settled = series.filter((s) => s.state === 3).sort((a, b) => Number(b.maturity - a.maturity));
  const results = useReadContracts({
    contracts: settled.map((s) => ({
      address: dep?.Settlement as `0x${string}`,
      abi: SettlementAbi,
      functionName: "resultOf",
      args: [s.id],
    })),
    query: { enabled: !!dep && settled.length > 0 },
  });

  return (
    <>
      <h1>Settlement history</h1>
      <p className="muted">
        Every series settles at the Chainlink price in effect at the US regular-session close on its maturity date.
        The round used is proven on-chain (round time at or before the close, next round after it).
      </p>
      {settled.length === 0 && <p className="empty">No series has settled yet.</p>}
      {settled.length > 0 && (
        <div className="card table-wrap">
          <table>
            <thead>
              <tr>
                <th>Series</th>
                <th>Maturity close</th>
                <th>Strike</th>
                <th>Final level</th>
                <th>Basket return</th>
                <th>Per 1,000 USDG</th>
                <th>Reserve used</th>
                <th>Method</th>
              </tr>
            </thead>
            <tbody>
              {settled.map((s, i) => {
                const raw = results.data?.[i]?.result as readonly [Result, readonly bigint[]] | undefined;
                const r = raw?.[0];
                const pay = raw?.[1];
                const ret = r && s.strike > 0n ? Number(formatUnits(((r.level - s.strike) * 10n ** 18n) / s.strike, 18)) : 0;
                const per1000Cash = r && r.notes > 0n ? (r.cash * 1_000_000_000n) / r.notes : 0n;
                return (
                  <tr key={s.id.toString()}>
                    <td>
                      <Link href={`/series/${s.id}`}>{s.name}</Link>
                    </td>
                    <td className="small">{fmtDate(s.maturity)}</td>
                    <td>{fmtUsdWad(s.strike)}</td>
                    <td>{r ? fmtUsdWad(r.level) : "-"}</td>
                    <td style={{ color: ret >= 0 ? "var(--ok)" : "var(--danger)" }}>{r ? fmtNum(ret * 100, 1) + "%" : "-"}</td>
                    <td className="small">
                      {r ? `${fmtStable(per1000Cash)} USDG` : "-"}
                      {r && pay && r.notes > 0n
                        ? s.tokens.map((t, j) =>
                            pay[j] > 0n ? ` + ${fmtToken((pay[j] * 1_000_000_000n) / r.notes)} ${tokenSymbol(t)}` : "",
                          )
                        : ""}
                    </td>
                    <td>{r ? fmtStable(r.reserveUsed) : "-"}</td>
                    <td>{r ? (r.manual ? "manual (Timelock)" : "oracle") : "-"}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </>
  );
}
