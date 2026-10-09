import Link from "next/link";
import { formatUnits } from "viem";
import type { Series } from "@/lib/series";
import { stateName } from "@/lib/series";
import { fmtBps, fmtDate, fmtPctWad, fmtStable } from "@/lib/format";
import { tokenSymbol } from "@/lib/tokens";
import { PayoffDiagram } from "./PayoffDiagram";

export function basketLabel(s: Series) {
  return s.tokens
    .map((t, i) =>
      s.tokens.length > 1 ? `${Number(formatUnits(s.quantities[i], 18))} ${tokenSymbol(t)}` : tokenSymbol(t),
    )
    .join(" + ");
}

export function SeriesCard({ s }: { s: Series }) {
  const st = stateName(s.state);
  const raised = s.priorityDeposits + s.regularDeposits;
  return (
    <Link href={`/series/${s.id}`} className="card series-card">
      <div className="row between">
        <h3>{s.name}</h3>
        <span className={`pill ${st.toLowerCase()}`}>{st}</span>
      </div>
      <p className="muted">{basketLabel(s)}</p>
      <PayoffDiagram
        protection={s.protectionBps / 10_000}
        participation={Number(formatUnits(s.participationWad, 18))}
        compact
        height={130}
      />
      <dl className="stats">
        <div>
          <dt>Protection</dt>
          <dd>{fmtBps(s.protectionBps, 0)}</dd>
        </div>
        <div>
          <dt>Participation</dt>
          <dd>{fmtPctWad(s.participationWad)}</dd>
        </div>
        <div>
          <dt>Tenor</dt>
          <dd>{s.tenorMonths}M</dd>
        </div>
        <div>
          <dt>{st === "Subscription" ? "Subscribed" : "Notes"}</dt>
          <dd>{fmtStable(st === "Subscription" ? raised : s.liveNotes, 6, 0)}</dd>
        </div>
      </dl>
      <p className="muted small">
        {st === "Subscription" ? `Subscription closes ${fmtDate(s.subscriptionEnd)}` : `Matures ${fmtDate(s.maturity)}`}
      </p>
    </Link>
  );
}
