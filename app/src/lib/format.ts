import { formatUnits } from "viem";

export const WAD = 10n ** 18n;

export function fmtNum(v: number, digits = 2) {
  return v.toLocaleString("en-US", { maximumFractionDigits: digits, minimumFractionDigits: digits });
}

export function fmtStable(v: bigint | undefined, decimals = 6, digits = 2) {
  if (v === undefined) return "-";
  return fmtNum(Number(formatUnits(v, decimals)), digits);
}

export function fmtUsdWad(v: bigint | undefined, digits = 2) {
  if (v === undefined) return "-";
  return "$" + fmtNum(Number(formatUnits(v, 18)), digits);
}

export function fmtToken(v: bigint | undefined, digits = 4) {
  if (v === undefined) return "-";
  return fmtNum(Number(formatUnits(v, 18)), digits);
}

export function fmtPctWad(v: bigint | undefined, digits = 1) {
  if (v === undefined) return "-";
  return fmtNum(Number(formatUnits(v * 100n, 18)), digits) + "%";
}

export function fmtBps(v: number | bigint, digits = 1) {
  return fmtNum(Number(v) / 100, digits) + "%";
}

export function fmtDate(ts: bigint | number | undefined) {
  if (ts === undefined) return "-";
  const d = new Date(Number(ts) * 1000);
  return d.toLocaleString("en-US", {
    timeZone: "America/New_York",
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "numeric",
    minute: "2-digit",
    timeZoneName: "short",
  });
}

export function shortAddr(a?: string) {
  return a ? `${a.slice(0, 6)}...${a.slice(-4)}` : "";
}
