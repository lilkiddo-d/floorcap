"use client";

import { useState } from "react";
import { SeriesCard } from "@/components/SeriesCard";
import { useSeriesList } from "@/hooks/useSeries";
import { CHAIN_ID } from "@/lib/chains";

const FILTERS = ["All", "Subscription", "Locked", "Settled"] as const;

export default function SeriesPage() {
  const { series, isLoading, error, deployment } = useSeriesList();
  const [filter, setFilter] = useState<(typeof FILTERS)[number]>("All");
  const shown = series
    .filter((s) => filter === "All" || ["None", "Subscription", "Locked", "Settled", "Cancelled"][s.state] === filter)
    .sort((a, b) => Number(b.id - a.id));

  return (
    <>
      <section className="hero">
        <h1>Principal-protected notes on tokenized stocks</h1>
        <p>
          Deposit USDG. At maturity you get your protected floor back plus a share of the stock basket&apos;s gain. Most
          of your deposit sits in the bond leg; the rest buys fully collateralized calls from underwriters.
        </p>
      </section>
      <div className="row between" style={{ margin: "16px 0" }}>
        <div className="row">
          {FILTERS.map((f) => (
            <button key={f} className={f === filter ? "" : "secondary"} onClick={() => setFilter(f)}>
              {f}
            </button>
          ))}
        </div>
        <div className="legend">
          <span>
            <span className="swatch" />
            note
          </span>
          <span>
            <span className="swatch dash" />
            holding the basket
          </span>
        </div>
      </div>
      {deployment === null && (
        <p className="notice">No deployment found for chain {CHAIN_ID}. Deploy the contracts first (see DEPLOY.md).</p>
      )}
      {error && <p className="notice">Could not load series: {error.message}</p>}
      {isLoading && <p className="empty">Loading series...</p>}
      {!isLoading && deployment && shown.length === 0 && <p className="empty">No series yet.</p>}
      <div className="grid-cards">
        {shown.map((s) => (
          <SeriesCard key={s.id.toString()} s={s} />
        ))}
      </div>
    </>
  );
}
