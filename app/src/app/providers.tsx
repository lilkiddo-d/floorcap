"use client";

import "@rainbow-me/rainbowkit/styles.css";
import { ReactNode, useState } from "react";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { WagmiProvider, createConfig, http } from "wagmi";
import { RainbowKitProvider, connectorsForWallets, darkTheme, getDefaultConfig } from "@rainbow-me/rainbowkit";
import { injectedWallet } from "@rainbow-me/rainbowkit/wallets";
import { activeChain, robinhood, robinhoodFork } from "@/lib/chains";

const projectId = process.env.NEXT_PUBLIC_WC_PROJECT_ID;
const rpc = activeChain.rpcUrls.default.http[0];
const transports = { [robinhood.id]: http(rpc), [robinhoodFork.id]: http(rpc) } as const;

// With a WalletConnect project id: full RainbowKit wallet list. Without: injected wallets only.
const config = projectId
  ? getDefaultConfig({ appName: "Floorcap", projectId, chains: [activeChain], transports, ssr: true })
  : createConfig({
      chains: [activeChain],
      transports,
      ssr: true,
      connectors: connectorsForWallets([{ groupName: "Browser wallet", wallets: [injectedWallet] }], {
        appName: "Floorcap",
        projectId: "unused",
      }),
    });

export function Providers({ children }: { children: ReactNode }) {
  const [qc] = useState(() => new QueryClient({ defaultOptions: { queries: { retry: 1 } } }));
  return (
    <WagmiProvider config={config}>
      <QueryClientProvider client={qc}>
        <RainbowKitProvider theme={darkTheme({ accentColor: "#7c83ff", borderRadius: "medium" })}>
          {children}
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
}
