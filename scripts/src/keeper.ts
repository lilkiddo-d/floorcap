/**
 * Floorcap keeper: drives the series lifecycle. Every action it takes is permissionless on-chain, so anyone can
 * run it, and a malicious keeper cannot pick prices: lock/settle prove the Chainlink round in effect at the close.
 *
 *  - Subscription ended and inside the lock window  -> SeriesFactory.lock(id, hints)   (strike = close price)
 *  - Subscription ended and lock window lapsed      -> SeriesFactory.cancelStale(id)   (full refunds)
 *  - Locked and maturity close passed                -> Settlement.settle(id, hints)
 *
 * Signing (this script never reads or stores a private key):
 *   KEEPER_MODE=dry-run      (default) print the calls and calldata only
 *   KEEPER_MODE=rpc-account  eth_sendTransaction from KEEPER_ADDRESS (node-managed / anvil unlocked account)
 *   KEEPER_MODE=cast         shell out to `cast send --account $KEEPER_KEYSTORE` (Foundry keystore)
 *
 * Env: RPC_URL, CHAIN_ID (4663 | 31337), KEEPER_INTERVAL_SEC (0 = run once), DEPLOYMENTS_DIR (default ../deployments)
 */
import { tick } from "./keeperCore.js";

const INTERVAL = Number(process.env.KEEPER_INTERVAL_SEC ?? 0);

async function main() {
  do {
    await tick();
    if (INTERVAL > 0) await new Promise((r) => setTimeout(r, INTERVAL * 1000));
  } while (INTERVAL > 0);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
