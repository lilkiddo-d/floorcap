import { explorerTx } from "@/lib/chains";

export function TxStatus({ status }: { status: { state: string; message?: string; hash?: string } }) {
  if (status.state === "idle") return null;
  const url = status.hash ? explorerTx(status.hash) : undefined;
  return (
    <p className={`tx ${status.state}`} role="status">
      {status.message}
      {url && (
        <>
          {" "}
          <a href={url} target="_blank" rel="noreferrer">
            view
          </a>
        </>
      )}
    </p>
  );
}
