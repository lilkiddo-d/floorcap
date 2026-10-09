import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  reactStrictMode: true,
  transpilePackages: ["@floorcap/config"],
  webpack: (config, { webpack }) => {
    // Optional peer deps pulled in by wallet SDKs; not needed in the browser bundle.
    config.externals.push("pino-pretty", "lokijs", "encoding");
    // @coinbase/cdp-sdk (via wagmi's Base Account connector) optionally imports x402 payment modules that are not
    // installed and never executed by this app.
    config.plugins.push(new webpack.IgnorePlugin({ resourceRegExp: /^@x402\// }));
    return config;
  },
};

export default nextConfig;
