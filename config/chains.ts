// Robinhood Chain configuration. Every address below was taken from an official source and checked on-chain.
// Never add an address here without a source link.
//
// Sources:
//  [1] Robinhood Chain docs: https://docs.robinhood.com/chain (network details, protocol contracts, token contracts)
//  [2] Robinhood stock token registry API (backs the docs "Token Contracts" page): https://api.robinhood.com/rhj/assets
//  [3] Chainlink Robinhood Chain feeds: https://docs.chain.link/data-feeds/price-feeds/addresses?network=robinhood
//      machine-readable: https://reference-data-directory.vercel.app/feeds-robinhood-mainnet.json
//  [4] Contract verification: docs.robinhood.com/chain "Deploy smart contracts" (forge verify-contract --verifier blockscout)
//  [5] Morpho deployment addresses: https://github.com/morpho-org/sdks/blob/main/packages/morpho-ts/src/addresses.ts
//  [6] Uniswap deployment addresses: https://github.com/Uniswap/sdks/blob/main/sdks/sdk-core/src/addresses.ts
//  [7] Maple syrupUSDG (CCIP-bridged, not ERC-4626 on this chain): https://docs.maple.finance/llms-full.txt

export type StockToken = {
  symbol: string;
  name: string;
  address: `0x${string}`;
  decimals: number;
  feed: `0x${string}`; // Chainlink primary proxy [3]
  feedSecondary: `0x${string}`; // Chainlink "Shared SVR" proxy, same DON, used as an independent cross-check [3]
  heartbeatSec: number;
  deviationPct: number;
};

export const robinhoodChain = {
  id: 4663,
  name: "Robinhood Chain",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, // gas token [1]
  rpcUrls: {
    default: { http: ["https://rpc.mainnet.chain.robinhood.com"] }, // public, rate-limited [1]
  },
  blockExplorers: {
    default: { name: "Blockscout", url: "https://robinhoodchain.blockscout.com" }, // [1]
  },
  verification: {
    verifier: "blockscout",
    verifierUrl: "https://robinhoodchain.blockscout.com/api/", // [4]
  },
  stack: "Arbitrum Orbit L2 settling to Ethereum", // [1]
} as const;

export const robinhoodTestnet = {
  id: 46630,
  rpc: "https://rpc.testnet.chain.robinhood.com",
  explorer: "https://explorer.testnet.chain.robinhood.com",
} as const; // [1]

export const contracts = {
  // Stablecoins [1]
  USDG: { address: "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168", decimals: 6 }, // Global Dollar, 6 decimals (cast-verified)
  WETH: { address: "0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73", decimals: 18 },
  Permit2: "0x000000000022D473030F116dDEE9F6B43aC78BA3",
  Multicall: "0x2cAC2D899eCC914d704FeaAE33ac1bF36277DaD1",
  // Oracles [3]
  feeds: {
    "USDG/USD": { primary: "0x61B7e5650328764B076A108EFF5fa7282a1B9aD2", secondary: "0x901f56689360B89D7767a8acE28B7801e6348fa2" },
    "USDC/USD": { primary: "0x9e6f4605992a899eE2999999F3Ec80C41F452546", secondary: "0x8929d7B1989459b3b1ec69066A06eab5c93B6d85" },
    "syrupUSDG/USDG": { primary: "0xDd194C66aDcb422F188a04434e4824D70c151cF0", secondary: "0x3bEdEA9CE3ead0Db4EA60dC497568DEdDe85dBa3" },
  },
  chainlinkSequencerUptimeFeed: null, // NOT PUBLISHED for Robinhood Chain as of 2026-10 [3] -> adapter supports it once available
  chainlinkDataStreamsVerifierProxy: "0xcE73c8ad08CBDEaCa6078BF0627C8fe0a9a536E7", // [1]
  // Yield-source candidates (see DECISIONS.md)
  morpho: {
    blue: "0x9D53d5E3bd5E8d4Cbfa6DB1ca238AEA02E651010", // [5]
    vaultV2Factory: "0x0FBad98595b0186dA120E41f77C102beb49f803c", // [5]
  },
  maple: {
    syrupUSDG: "0x40858070814a57FdF33a613ae84fE0a8b4a874f7", // [7] bridged share, no on-chain deposit/redeem
  },
  SGOV: { // iShares 0-3M Treasury ETF stock token [2], Chainlink feed [3]
    address: "0x92FD66527192E3e61d4DDd13322Aa222DE86F9B5",
    feed: "0xa0DF4ee0fFf975306345875E3548Fcc519577A11",
  },
  // DEX (not used by the protocol; documented for the SGOV/syrup adapter roadmap) [6]
  uniswap: {
    v3Factory: "0x1f7d7550b1b028f7571e69a784071f0205fd2efa",
    swapRouter02: "0xcaf681a66d020601342297493863e78c959e5cb2",
    quoterV2: "0x33e885ed0ec9bf04ecfb19341582aadcb4c8a9e7",
  },
} as const;

// Stock tokens with a Chainlink feed: the launch universe for note underlyings. [2][3]
// Stock tokens: ERC-20, 18 decimals, ERC-8056 uiMultiplier; Chainlink prices already include the multiplier. [1]
export const stockTokens: StockToken[] = [
  { symbol: "AAPL", name: "Apple • Robinhood Token", address: "0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9", decimals: 18, feed: "0x6B22A786bAa607d76728168703a39Ea9C99f2cD0", feedSecondary: "0x4bDbb3150014c6Ab2C6D9347B0779c49015a2f3f", heartbeatSec: 86400, deviationPct: 0.5 },
  { symbol: "NVDA", name: "NVIDIA • Robinhood Token", address: "0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC", decimals: 18, feed: "0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15", feedSecondary: "0xCF169363636D73dbBf77733629CB38919d14232d", heartbeatSec: 86400, deviationPct: 0.5 },
  { symbol: "TSLA", name: "Tesla • Robinhood Token", address: "0x322F0929c4625eD5bAd873c95208D54E1c003b2d", decimals: 18, feed: "0x4A1166a659A55625345e9515b32adECea5547C38", feedSecondary: "0xE4479F01738B4e8C428CD8eB72D47AB9BC3c7de6", heartbeatSec: 86400, deviationPct: 0.5 },
  { symbol: "MSFT", name: "Microsoft • Robinhood Token", address: "0xe93237C50D904957Cf27E7B1133b510C669c2e74", decimals: 18, feed: "0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E", feedSecondary: "0xaD6D88eab22aa4867Efe807a5311Ed64962f740D", heartbeatSec: 86400, deviationPct: 0.5 },
  { symbol: "GOOGL", name: "Alphabet Class A • Robinhood Token", address: "0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3", decimals: 18, feed: "0xF6f373a037c30F0e5010d854385cA89185AE638b", feedSecondary: "0xA04EE5c4c8827F17e82f93bE9e19DeA221A749a8", heartbeatSec: 86400, deviationPct: 0.5 },
  { symbol: "AMZN", name: "Amazon • Robinhood Token", address: "0x12f190a9F9d7D37a250758b26824B97CE941bF54", decimals: 18, feed: "0xD5a1508ceD74c084eBf3cBe853e2C968fB2a651C", feedSecondary: "0x9244830430bC7D9C9A48dd47603F24AD61f7c56e", heartbeatSec: 86400, deviationPct: 0.5 },
  { symbol: "META", name: "Meta Platforms • Robinhood Token", address: "0xc0D6457C16Cc70d6790Dd43521C899C87ce02f35", decimals: 18, feed: "0x7C38C00C30BEe9378381E7B6135d7283356D71b1", feedSecondary: "0x5cBC53D382E56cBb223f118CF8Eefb6c9c2759f5", heartbeatSec: 86400, deviationPct: 0.5 },
  { symbol: "SPY", name: "SPDR S&P 500 ETF Trust • Robinhood Token", address: "0x117cc2133c37B721F49dE2A7a74833232B3B4C0C", decimals: 18, feed: "0x319724394D3A0e3669269846abE664Cd621f9f6A", feedSecondary: "0xa68CA83408bE3f78d1c58a82081c619e9d21486d", heartbeatSec: 86400, deviationPct: 0.5 },
  { symbol: "QQQ", name: "Invesco QQQ • Robinhood Token", address: "0xD5f3879160bc7c32ebb4dC785F8a4F505888de68", decimals: 18, feed: "0x80901d846d5D7B030F26B480776EE3b29374C2ae", feedSecondary: "0x41ed2c58611790af0760e31e80Bb427e4e83D603", heartbeatSec: 86400, deviationPct: 0.5 },
  { symbol: "AMD", name: "AMD • Robinhood Token", address: "0x86923f96303D656E4aa86D9d42D1e57ad2023fdC", decimals: 18, feed: "0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72", feedSecondary: "0xF6d57763DFa625F4A413485261Ab2E71Ff4304CF", heartbeatSec: 86400, deviationPct: 0.5 },
  { symbol: "PLTR", name: "Palantir Technologies • Robinhood Token", address: "0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A", decimals: 18, feed: "0x820ABedFF239034956B7A9d2F0a331f9F075eB4c", feedSecondary: "0x8cd1DFC0fc61fcA55FA77b37e008A90f13364Fce", heartbeatSec: 86400, deviationPct: 0.5 },
  { symbol: "COIN", name: "Coinbase • Robinhood Token", address: "0x6330D8C3178a418788dF01a47479c0ce7CCF450b", decimals: 18, feed: "0xA3a468A452940B7D6b69991207B508c609a98Ef2", feedSecondary: "0xA7F7D79D578fb007384BaDF42c8E1D76a6a63bBD", heartbeatSec: 86400, deviationPct: 0.5 },
];
