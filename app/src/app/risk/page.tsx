export const metadata = { title: "Risk disclosure | Floorcap" };

export default function Risk() {
  return (
    <article className="prose">
      <h1>Risk disclosure</h1>
      <p className="notice">
        &quot;Principal-protected&quot; describes how the note is built, not a guarantee. Nobody insures these notes. You
        can lose money, including part of the protected floor, if the risks below materialise. Read all of it.
      </p>

      <h2>1. How a note works</h2>
      <p>
        Each note splits your deposit in two. The <strong>bond leg</strong> (most of it) goes to a yield source
        and is sized so that, at the series&apos; <em>assumed</em> yield, it grows back to the protected floor (100% or 95%
        of principal) by maturity. The rest, minus a structuring fee, buys <strong>call options</strong> on a stock
        basket from underwriters. At maturity you receive the floor in USDG plus your participation in any basket gain
        above the strike, paid in the basket&apos;s stock tokens.
      </p>

      <h2>2. Yield-source risk: the main risk to your floor</h2>
      <p>
        <strong>The floor is only as good as the yield source behind the bond leg.</strong> The note contract does not
        hold your full principal: it holds a claim on the yield source that is expected to grow to the floor.
      </p>
      <ul>
        <li>
          <strong>If the yield source loses money</strong> (a hack, bad debt, a depeg of the stablecoin it holds, a
          failed borrower, a governance attack), the bond leg can be worth less than the floor at maturity. Holders
          then receive their pro-rata share of what is actually recovered, plus whatever the protocol&apos;s shortfall
          reserve can add. The reserve is funded by a share of fees and can be exhausted.
        </li>
        <li>
          <strong>If the yield source earns less than assumed</strong>, the bond leg ends below the floor by the
          difference. Series assume a conservative, haircut yield, but rates can fall.
        </li>
        <li>
          <strong>If the yield source is illiquid or paused</strong> at maturity (withdrawal queue, utilisation at
          100%, emergency pause), settlement and early exits can be delayed until liquidity returns.
        </li>
        <li>
          <strong>Series using the zero-yield &quot;hold&quot; adapter</strong> just custody USDG. Their floor does not
          depend on any lending protocol, which is why at launch only 95%-protected series have upside: the 5% you
          put at risk is what buys the calls.
        </li>
        <li>
          <strong>Stablecoin risk.</strong> Payouts are in USDG. If USDG loses its peg, your floor is a floor in USDG,
          not in US dollars.
        </li>
      </ul>
      <p>
        Each series page shows which yield adapter it uses and its assumed yield. The current yield source choice and
        the reasons for it are documented in the protocol&apos;s DECISIONS.md and THREAT_MODEL.md.
      </p>

      <h2>3. Oracle and settlement-price risk</h2>
      <ul>
        <li>
          Final payouts use the Chainlink price in effect at the US regular-session close on the maturity date. If the
          oracle is wrong, stale or paused (for example during a corporate action), settlement can be delayed, and
          after a waiting period it can be set manually through the protocol&apos;s 48-hour Timelock.
        </li>
        <li>
          Prices of tokenized stocks can differ from the listed share, especially outside US market hours. Settlement
          only uses the regular-session close to limit this.
        </li>
        <li>The protocol rejects stale prices and prices where its two independent Chainlink reads disagree by over 1%.</li>
      </ul>

      <h2>4. Upside and underwriter risk</h2>
      <ul>
        <li>
          If the basket ends at or below the strike, the calls expire worthless and you receive only the floor. A
          95%-protected note then loses 5% (plus the opportunity cost of the yield you could have earned).
        </li>
        <li>
          Calls are sold by underwriters who post the stock tokens up front. Their collateral always covers the
          maximum payout, so there is no counterparty default. But if underwriters do not commit enough collateral,
          the series accepts less than was subscribed and refunds the rest.
        </li>
        <li>Upside is paid in stock tokens, whose value keeps moving after settlement.</li>
      </ul>

      <h2>5. Liquidity and early exit</h2>
      <ul>
        <li>
          Early exit pays the current value of the bond leg (below the floor before maturity) plus only the
          calls&apos; <em>intrinsic</em> value, minus an exit fee. You give up the calls&apos; remaining time value.
          Exiting early can return less than the floor.
        </li>
        <li>Early exits are only available during the US regular session, when prices are reliable.</li>
        <li>The secondary market is a simple fixed-price board. There may be no buyer at your price.</li>
      </ul>

      <h2>6. Smart contract, chain and governance risk</h2>
      <ul>
        <li>The contracts may contain bugs despite tests and static analysis. They have not been audited unless stated.</li>
        <li>
          Admin actions go through a 48-hour Timelock, and a guardian can pause new activity (never maturity claims).
          The chain&apos;s sequencer can halt or drop transactions, and stock tokens can be paused during corporate actions.
        </li>
        <li>
          Stock tokens and the issuer&apos;s offering have their own eligibility rules. They are not offered to persons
          in restricted jurisdictions, including the US and UK, under the issuer&apos;s terms. You are responsible for
          complying with the laws that apply to you.
        </li>
      </ul>

      <h2>7. Not advice</h2>
      <p>
        Nothing here is investment, legal or tax advice. Floorcap is independent software. It is not affiliated with,
        endorsed by or sponsored by any stock-token issuer, chain operator, exchange or broker.
      </p>
    </article>
  );
}
