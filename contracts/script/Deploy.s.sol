// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {FloorcapDeployer} from "./FloorcapDeployer.sol";
import {RobinhoodAddresses} from "./RobinhoodAddresses.sol";

/// @title Deploy
/// @notice One-shot deployment of the whole protocol: deploy, wire, seed the NYSE calendar and Chainlink feeds,
///         create the 48h Timelock, hand every admin role to it, then write deployments/<chainId>.json and the
///         frontend config (app/public/deployments/<chainId>.json).
/// @dev Signing: this script never reads a private key. Production signs with the Foundry keystore account
///      `floorcap-deployer` (`--account floorcap-deployer`); the local fork run uses anvil's `--unlocked` sender.
///      Optional env overrides (all addresses): FLOORCAP_GUARDIAN, FLOORCAP_CURATOR, FLOORCAP_TIMELOCK_PROPOSER,
///      FLOORCAP_TIMELOCK_EXECUTOR, FLOORCAP_YIELD_VAULT, FLOORCAP_STABLE; uint: FLOORCAP_TIMELOCK_DELAY.
contract Deploy is Script, FloorcapDeployer {
    uint32 internal constant MAX_STALENESS = 26 hours; // Chainlink heartbeat is 24h on equity feeds
    uint16 internal constant MAX_DEVIATION_BPS = 100; // primary vs Shared-SVR proxy

    function run() external returns (Deployment memory d) {
        // Start broadcasting first: only then does readCallers() return the real signer (`--account`); before it,
        // forge reports its placeholder DefaultSender.
        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        require(deployer != 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38, "no signer: pass --account or --sender");
        address stable = vm.envOr("FLOORCAP_STABLE", RobinhoodAddresses.USDG);
        address guardian = vm.envOr("FLOORCAP_GUARDIAN", deployer);
        address curator = vm.envOr("FLOORCAP_CURATOR", deployer);
        address proposer = vm.envOr("FLOORCAP_TIMELOCK_PROPOSER", deployer);
        address executor = vm.envOr("FLOORCAP_TIMELOCK_EXECUTOR", address(0)); // 0 = anyone may execute
        address yieldVault = vm.envOr("FLOORCAP_YIELD_VAULT", address(0));
        uint256 delay = vm.envOr("FLOORCAP_TIMELOCK_DELAY", uint256(48 hours));

        _preflight(stable, yieldVault, deployer);
        console2.log("Deployer:", deployer);
        console2.log("Chain id:", block.chainid);

        d = _deployCore(
            CoreConfig({
                deployer: deployer,
                stable: stable,
                yieldVault: yieldVault,
                reserveShareBps: 2_000,
                stakerShareBps: 3_000,
                listingFeeBps: 50,
                minPriorityStake: 1_000e18,
                unstakeCooldown: 7 days,
                noteUri: "https://floorcap.app/api/note/{id}.json"
            })
        );
        (uint256[] memory days_, uint8[] memory statuses) = _nyseCalendar();
        d.clock.setDayStatus(days_, statuses);

        RobinhoodAddresses.Stock[] memory s = RobinhoodAddresses.stocks();
        for (uint256 i; i < s.length; ++i) {
            d.oracle.setFeed(s[i].token, s[i].feed, s[i].feedSecondary, MAX_STALENESS, MAX_DEVIATION_BPS);
        }

        _deployTimelock(d, delay, proposer, executor);
        _handover(d, Roles({guardian: guardian, curator: curator, complianceOperator: guardian}), deployer);
        vm.stopBroadcast();

        _postflight(d, deployer);
        _write(d, deployer, guardian, curator, proposer);
    }

    function _preflight(address stable, address yieldVault, address deployer) internal view {
        // A local fork must use --chain-id 31337 so it can never overwrite deployments/4663.json.
        require(
            !(block.chainid == RobinhoodAddresses.CHAIN_ID && deployer == 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266),
            "anvil dev account on chain 4663: run local forks with --chain-id 31337"
        );
        require(stable.code.length > 0, "stable has no code");
        if (yieldVault != address(0)) require(yieldVault.code.length > 0, "vault has no code");
        RobinhoodAddresses.Stock[] memory s = RobinhoodAddresses.stocks();
        for (uint256 i; i < s.length; ++i) {
            require(s[i].token.code.length > 0, string.concat("token missing: ", s[i].symbol));
            require(s[i].feed.code.length > 0, string.concat("feed missing: ", s[i].symbol));
        }
    }

    function _postflight(Deployment memory d, address deployer) internal view {
        bytes32 admin = 0x00;
        require(d.factory.hasRole(admin, address(d.timelock)), "timelock not admin");
        require(!d.factory.hasRole(admin, deployer), "deployer still admin");
        require(!d.hooks.hasRole(admin, deployer), "deployer still hooks admin");
        require(!d.oracle.hasRole(admin, deployer), "deployer still oracle admin");
        require(d.timelock.getMinDelay() >= 48 hours, "delay");
        require(!d.hooks.isActive(), "token must start unset");
    }

    /// @dev On Arbitrum Orbit chains `block.number` is the L1 block; ArbSys (0x64) returns the L2 block that log
    ///      queries need. Falls back to `block.number` where the precompile is absent (local anvil).
    function _l2BlockNumber() internal view returns (uint256) {
        (bool ok, bytes memory ret) = address(100).staticcall(abi.encodeWithSignature("arbBlockNumber()"));
        if (ok && ret.length == 32) return abi.decode(ret, (uint256));
        return block.number;
    }

    function _write(Deployment memory d, address deployer, address guardian, address curator, address proposer)
        internal
    {
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeUint(k, "deployedAtBlock", _l2BlockNumber());
        vm.serializeAddress(k, "deployer", deployer);
        vm.serializeAddress(k, "guardian", guardian);
        vm.serializeAddress(k, "curator", curator);
        vm.serializeAddress(k, "timelockProposer", proposer);
        vm.serializeAddress(k, "stable", d.feeCollector.hooks().rewardToken());
        vm.serializeAddress(k, "Timelock", address(d.timelock));
        vm.serializeAddress(k, "MarketClock", address(d.clock));
        vm.serializeAddress(k, "OracleAdapter", address(d.oracle));
        vm.serializeAddress(k, "Note", address(d.note));
        vm.serializeAddress(k, "ComplianceRegistry", address(d.compliance));
        vm.serializeAddress(k, "FeeCollector", address(d.feeCollector));
        vm.serializeAddress(k, "ProjectTokenHooks", address(d.hooks));
        vm.serializeAddress(k, "SeriesFactory", address(d.factory));
        vm.serializeAddress(k, "UnderwriterPool", address(d.pool));
        vm.serializeAddress(k, "Settlement", address(d.settlement));
        vm.serializeAddress(k, "SecondaryListings", address(d.listings));
        vm.serializeAddress(k, "HoldYieldAdapter", address(d.holdAdapter));
        string memory json = vm.serializeAddress(k, "ERC4626YieldAdapter", address(d.vaultAdapter));

        string memory id = vm.toString(block.chainid);
        if (vm.isContext(VmSafe.ForgeContext.ScriptDryRun)) {
            console2.log("Dry run: not writing deployment files");
            console2.log(json);
            return;
        }
        vm.writeJson(json, string.concat("../deployments/", id, ".json"));
        vm.writeJson(json, string.concat("../app/public/deployments/", id, ".json"));
        console2.log("Wrote deployments/<chainId>.json and app/public/deployments/<chainId>.json");
    }
}
