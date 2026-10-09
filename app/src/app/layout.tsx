import type { Metadata } from "next";
import Link from "next/link";
import "./globals.css";
import { Providers } from "./providers";
import { Nav } from "@/components/Nav";

export const metadata: Metadata = {
  title: "Floorcap: principal-protected notes",
  description:
    "Principal-protected structured notes on tokenized stocks. Deposit stablecoins, get your floor back at maturity, keep a share of the upside.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>
        <Providers>
          <Nav />
          <div className="banner">
            Notes are protected only as far as the yield source and oracle hold.{" "}
            <Link href="/risk">Read the risk disclosure</Link> before subscribing.
          </div>
          <main>{children}</main>
          <footer>
            <span>Floorcap. Not investment advice. Smart contracts can fail.</span>
            <Link href="/risk">Risk disclosure</Link>
          </footer>
        </Providers>
      </body>
    </html>
  );
}
