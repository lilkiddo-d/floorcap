import { NextResponse, type NextRequest } from "next/server";

/**
 * Optional geoblock. NEXT_PUBLIC_GEOBLOCK = comma-separated ISO-3166 alpha-2 codes (e.g. "US,GB,CU,IR,KP,SY").
 * Uses the `x-vercel-ip-country` header set by Vercel's edge (absent locally, so local dev is never blocked).
 * This is a UX-level control only; on-chain gating is the ComplianceRegistry.
 */
const BLOCKED = (process.env.NEXT_PUBLIC_GEOBLOCK ?? "")
  .split(",")
  .map((c) => c.trim().toUpperCase())
  .filter(Boolean);

export function middleware(req: NextRequest) {
  if (BLOCKED.length === 0) return NextResponse.next();
  const country = req.headers.get("x-vercel-ip-country")?.toUpperCase();
  if (country && BLOCKED.includes(country) && !req.nextUrl.pathname.startsWith("/blocked")) {
    const url = req.nextUrl.clone();
    url.pathname = "/blocked";
    return NextResponse.rewrite(url);
  }
  return NextResponse.next();
}

export const config = {
  matcher: ["/((?!_next/|deployments/|favicon.ico).*)"],
};
