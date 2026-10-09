import { payoffSeries } from "@/lib/payoff";

/** Return at maturity of the note vs. holding the basket, for basket returns from -50% to +100%. */
export function PayoffDiagram({
  protection,
  participation,
  width = 320,
  height = 180,
  compact = false,
}: {
  protection: number;
  participation: number;
  width?: number;
  height?: number;
  compact?: boolean;
}) {
  const pts = payoffSeries(protection, participation);
  const pad = compact ? 14 : 38;
  const [xMin, xMax, yMin, yMax] = [-0.5, 1.0, -0.5, 1.0];
  const x = (r: number) => pad + ((r - xMin) / (xMax - xMin)) * (width - pad - 8);
  const y = (v: number) => height - pad - ((v - yMin) / (yMax - yMin)) * (height - pad - 10);
  const path = (key: "note" | "stock") =>
    pts.map((p, i) => `${i ? "L" : "M"}${x(p.r).toFixed(1)},${y(p[key]).toFixed(1)}`).join(" ");
  const ticks = [-0.5, 0, 0.5, 1.0];
  const floor = protection - 1;
  const label = `Payoff: floor ${(protection * 100).toFixed(0)}% of principal, ${(participation * 100).toFixed(0)}% participation in basket gains`;
  return (
    <svg viewBox={`0 0 ${width} ${height}`} width="100%" role="img" aria-label={label} className="payoff">
      {ticks.map((t) => (
        <g key={t}>
          <line x1={x(t)} x2={x(t)} y1={y(yMin)} y2={y(yMax)} className="grid" />
          <line x1={x(xMin)} x2={x(xMax)} y1={y(t)} y2={y(t)} className="grid" />
          {!compact && (
            <>
              <text x={x(t)} y={height - pad + 14} textAnchor="middle" className="tick">{`${t * 100}%`}</text>
              <text x={pad - 6} y={y(t) + 4} textAnchor="end" className="tick">{`${t * 100}%`}</text>
            </>
          )}
        </g>
      ))}
      <line x1={x(xMin)} x2={x(xMax)} y1={y(0)} y2={y(0)} className="axis" />
      <line x1={x(0)} x2={x(0)} y1={y(yMin)} y2={y(yMax)} className="axis" />
      <path d={path("stock")} className="stock" />
      <path d={path("note")} className="note" />
      {!compact && (
        <>
          <text x={x(xMin) + 4} y={y(floor) - 6} className="label floorlabel">{`floor ${(floor * 100).toFixed(0)}%`}</text>
          <text x={x(0.75)} y={y(0.75 * participation + floor) + 16} className="label notelabel">note</text>
          <text x={x(0.62)} y={y(0.62) - 8} className="label stocklabel">basket</text>
          <text x={(width + pad) / 2} y={height - 4} textAnchor="middle" className="tick">
            basket return at maturity
          </text>
        </>
      )}
    </svg>
  );
}
