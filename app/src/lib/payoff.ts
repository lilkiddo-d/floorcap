/**
 * Note payoff at maturity per 1 unit of principal, as a function of the basket return r:
 *   value(r) = protection + participation * max(r, 0)
 * (assuming a solvent yield source; see /risk).
 */
export function noteValue(r: number, protection: number, participation: number) {
  return protection + participation * Math.max(r, 0);
}

export function payoffSeries(protection: number, participation: number, from = -0.5, to = 1.0, steps = 60) {
  const pts: { r: number; note: number; stock: number }[] = [];
  for (let i = 0; i <= steps; i++) {
    const r = from + ((to - from) * i) / steps;
    pts.push({ r, note: noteValue(r, protection, participation) - 1, stock: r });
  }
  return pts;
}

/** The note outperforms holding the basket whenever the basket falls by more than (1 - protection). */
export function downsideCrossover(protection: number) {
  return protection - 1;
}
