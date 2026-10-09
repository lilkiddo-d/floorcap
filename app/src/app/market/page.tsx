"use client";

import { useState } from "react";
import { formatUnits, maxUint256, parseUnits } from "viem";
import { useAccount, useReadContract, useReadContracts } from "wagmi";
import { SecondaryListingsAbi } from "@/abi";
import { TxStatus } from "@/components/TxStatus";
import { useSeriesList } from "@/hooks/useSeries";
import { useErc20, erc20Abi } from "@/hooks/useErc20";
import { useTx } from "@/hooks/useTx";
import { fmtDate, fmtNum, fmtStable, shortAddr } from "@/lib/format";

type Listing = readonly [`0x${string}`, bigint, bigint, bigint, bigint]; // seller, seriesId, remaining, priceWad, expiry

export default function Market() {
  const { address } = useAccount();
  const { series, deployment: dep } = useSeriesList();
  const tx = useTx();
  const [amounts, setAmounts] = useState<Record<string, string>>({});
  const count = useReadContract({
    address: dep?.SecondaryListings,
    abi: SecondaryListingsAbi,
    functionName: "listingCount",
    query: { enabled: !!dep, refetchInterval: 15_000 },
  });
  const n = Number(count.data ?? 0n);
  const ids = Array.from({ length: n }, (_, i) => BigInt(i + 1));
  const listings = useReadContracts({
    contracts: ids.map((id) => ({
      address: dep?.SecondaryListings as `0x${string}`,
      abi: SecondaryListingsAbi,
      functionName: "listings",
      args: [id],
    })),
    query: { enabled: !!dep && n > 0, refetchInterval: 15_000 },
  });
  const usdg = useErc20(dep?.stable, address, dep?.SecondaryListings);
  const now = Math.floor(Date.now() / 1000);

  const active = ids
    .map((id, i) => ({ id, l: listings.data?.[i]?.result as Listing | undefined }))
    .filter((x) => x.l && x.l[2] > 0n && Number(x.l[4]) > now);

  return (
    <>
      <h1>Secondary market</h1>
      <p className="muted">
        Fixed-price listings of notes. Price is USDG per 1 USDG of principal (1.00 = par). A small fee goes to the
        protocol. Only notes of live (locked) series trade here; settled notes should be claimed.
      </p>
      {!dep && <p className="empty">Loading...</p>}
      {dep && active.length === 0 && <p className="empty">No active listings.</p>}
      {active.length > 0 && (
        <div className="table-wrap card">
          <table>
            <thead>
              <tr>
                <th>#</th>
                <th>Series</th>
                <th>Seller</th>
                <th>Available</th>
                <th>Price</th>
                <th>Expires</th>
                <th>Buy</th>
              </tr>
            </thead>
            <tbody>
              {active.map(({ id, l }) => {
                const s = series.find((x) => x.id === l![1]);
                const key = id.toString();
                let amt = 0n;
                try {
                  amt = parseUnits(amounts[key] || "0", 6);
                } catch {}
                const cost = (amt * l![3] + 10n ** 18n - 1n) / 10n ** 18n;
                const mine = address && l![0].toLowerCase() === address.toLowerCase();
                return (
                  <tr key={key}>
                    <td>{key}</td>
                    <td>{s?.name ?? `#${l![1]}`}</td>
                    <td>{shortAddr(l![0])}</td>
                    <td>{fmtStable(l![2])}</td>
                    <td>{fmtNum(Number(formatUnits(l![3], 18)), 4)}</td>
                    <td className="small">{fmtDate(l![4])}</td>
                    <td>
                      {mine ? (
                        <button
                          className="secondary"
                          disabled={tx.busy}
                          onClick={() => tx.send({ address: dep!.SecondaryListings, abi: SecondaryListingsAbi, functionName: "cancel", args: [id], label: "Cancel listing" })}
                        >
                          Cancel
                        </button>
                      ) : (
                        <div className="row">
                          <input
                            style={{ width: 100 }}
                            placeholder="amount"
                            value={amounts[key] ?? ""}
                            onChange={(e) => setAmounts({ ...amounts, [key]: e.target.value })}
                          />
                          {(usdg.allowance ?? 0n) < cost ? (
                            <button
                              disabled={!address || tx.busy}
                              onClick={() => tx.send({ address: dep!.stable, abi: erc20Abi, functionName: "approve", args: [dep!.SecondaryListings, maxUint256], label: "Approve USDG" })}
                            >
                              Approve
                            </button>
                          ) : (
                            <button
                              disabled={!address || tx.busy || amt === 0n || amt > l![2]}
                              onClick={() =>
                                tx.send({
                                  address: dep!.SecondaryListings,
                                  abi: SecondaryListingsAbi,
                                  functionName: "buy",
                                  args: [id, amt, l![3], BigInt(now + 600)],
                                  label: "Buy notes",
                                })
                              }
                            >
                              Buy ({fmtStable(cost)})
                            </button>
                          )}
                        </div>
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
      <TxStatus status={tx.status} />
    </>
  );
}
