"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { ConnectButton } from "@rainbow-me/rainbowkit";
import { IS_FORK } from "@/lib/chains";
import { PROJECT_TOKEN } from "@/lib/token";

const links = [
  { href: "/", label: "Series" },
  { href: "/portfolio", label: "My notes" },
  { href: "/market", label: "Secondary" },
  { href: "/underwriters", label: "Underwrite" },
  { href: "/settlements", label: "Settlements" },
  ...(PROJECT_TOKEN ? [{ href: "/stake", label: "Stake" }] : []),
  { href: "/risk", label: "Risks" },
];

export function Logo() {
  return (
    <svg width="26" height="26" viewBox="0 0 32 32" aria-hidden>
      <rect x="3" y="22" width="26" height="4" rx="2" fill="currentColor" opacity="0.45" />
      <path d="M5 20 L13 12 L18 16 L27 6" stroke="currentColor" strokeWidth="3" fill="none" strokeLinecap="round" />
    </svg>
  );
}

export function Nav() {
  const path = usePathname();
  return (
    <header className="nav">
      <Link href="/" className="brand">
        <Logo />
        <span>Floorcap</span>
        {IS_FORK && <span className="pill warn">local fork</span>}
      </Link>
      <nav>
        {links.map((l) => (
          <Link key={l.href} href={l.href} className={path === l.href ? "active" : ""}>
            {l.label}
          </Link>
        ))}
      </nav>
      <ConnectButton chainStatus="icon" showBalance={false} accountStatus="address" />
    </header>
  );
}
