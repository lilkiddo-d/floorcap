// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MarketClock} from "../src/MarketClock.sol";
import {OracleAdapter} from "../src/OracleAdapter.sol";
import {Note} from "../src/Note.sol";
import {ComplianceRegistry} from "../src/compliance/ComplianceRegistry.sol";
import {FeeCollector} from "../src/FeeCollector.sol";
import {ProjectTokenHooks} from "../src/ProjectTokenHooks.sol";
import {SeriesFactory} from "../src/SeriesFactory.sol";
import {UnderwriterPool} from "../src/UnderwriterPool.sol";
import {Settlement} from "../src/Settlement.sol";
import {SecondaryListings} from "../src/SecondaryListings.sol";
import {HoldYieldAdapter} from "../src/adapters/HoldYieldAdapter.sol";
import {ERC4626YieldAdapter} from "../src/adapters/ERC4626YieldAdapter.sol";
import {Timelock} from "../src/governance/Timelock.sol";

/// @notice Deploys and wires the full protocol. Shared by script/Deploy.s.sol and the test suite so tests exercise
///         exactly the production wiring. Contains no cheatcodes and never touches keys.
abstract contract FloorcapDeployer {
    struct CoreConfig {
        address deployer; // temporary admin during wiring (renounced in _handover)
        address stable;
        address yieldVault; // ERC-4626 vault for the bond leg; address(0) = only the zero-risk HoldYieldAdapter
        uint256 reserveShareBps;
        uint256 stakerShareBps;
        uint256 listingFeeBps;
        uint256 minPriorityStake;
        uint256 unstakeCooldown;
        string noteUri;
    }

    struct Deployment {
        MarketClock clock;
        OracleAdapter oracle;
        Note note;
        ComplianceRegistry compliance;
        FeeCollector feeCollector;
        ProjectTokenHooks hooks;
        SeriesFactory factory;
        UnderwriterPool pool;
        Settlement settlement;
        SecondaryListings listings;
        HoldYieldAdapter holdAdapter;
        ERC4626YieldAdapter vaultAdapter; // address(0) when no vault configured
        Timelock timelock; // set by _deployTimelock
    }

    struct Roles {
        address guardian;
        address curator;
        address complianceOperator;
    }

    function _deployCore(CoreConfig memory c) internal returns (Deployment memory d) {
        address a = c.deployer;
        d.clock = new MarketClock(a);
        d.oracle = new OracleAdapter(a);
        d.note = new Note(a, c.noteUri);
        d.compliance = new ComplianceRegistry(a);
        d.feeCollector = new FeeCollector(a, c.reserveShareBps, c.stakerShareBps);
        d.hooks = new ProjectTokenHooks(a, c.stable, c.minPriorityStake, c.unstakeCooldown);
        d.factory = new SeriesFactory(a);
        d.pool = new UnderwriterPool(a, address(d.factory));
        d.settlement = new Settlement(a, address(d.factory));
        d.listings = new SecondaryListings(a, address(d.factory), c.listingFeeBps);
        d.holdAdapter = new HoldYieldAdapter(c.stable, a);
        if (c.yieldVault != address(0)) d.vaultAdapter = new ERC4626YieldAdapter(c.yieldVault, a, 10);
        _wire(d, c.stable);
    }

    function _wire(Deployment memory d, address stable) internal {
        d.factory.setWiring(
            address(d.oracle),
            address(d.clock),
            address(d.note),
            address(d.feeCollector),
            address(d.compliance),
            address(d.hooks)
        );
        d.factory.grantRole(d.factory.SETTLEMENT_ROLE(), address(d.settlement));
        d.factory.setAllowed(0, stable, true);
        d.factory.setAllowed(1, address(d.holdAdapter), true);
        d.factory.setAllowed(2, address(d.pool), true);

        d.note.grantRole(d.note.MINTER_ROLE(), address(d.factory));
        d.note.grantRole(d.note.BURNER_ROLE(), address(d.settlement));
        d.note.setCompliance(address(d.compliance));

        d.pool.grantRole(d.pool.SETTLEMENT_ROLE(), address(d.settlement));

        d.holdAdapter.grantRole(d.holdAdapter.VAULT_ROLE(), address(d.factory));
        d.holdAdapter.grantRole(d.holdAdapter.VAULT_ROLE(), address(d.settlement));
        if (address(d.vaultAdapter) != address(0)) {
            d.vaultAdapter.grantRole(d.vaultAdapter.VAULT_ROLE(), address(d.factory));
            d.vaultAdapter.grantRole(d.vaultAdapter.VAULT_ROLE(), address(d.settlement));
            d.factory.setAllowed(1, address(d.vaultAdapter), true);
        }

        d.feeCollector.grantRole(d.feeCollector.FEE_SOURCE_ROLE(), address(d.factory));
        d.feeCollector.grantRole(d.feeCollector.FEE_SOURCE_ROLE(), address(d.settlement));
        d.feeCollector.grantRole(d.feeCollector.FEE_SOURCE_ROLE(), address(d.listings));
        d.feeCollector.grantRole(d.feeCollector.SHORTFALL_ROLE(), address(d.settlement));
        d.feeCollector.setHooks(address(d.hooks));
        d.hooks.grantRole(d.hooks.NOTIFIER_ROLE(), address(d.feeCollector));

        // Protocol escrow must stay able to hold notes if compliance is ever switched on.
        address[] memory protocol = new address[](2);
        protocol[0] = address(d.listings);
        protocol[1] = address(d.settlement);
        d.compliance.setAllowed(protocol, true);
    }

    function _deployTimelock(Deployment memory d, uint256 minDelay, address proposer, address executor)
        internal
        returns (Timelock t)
    {
        address[] memory proposers = new address[](1);
        proposers[0] = proposer;
        address[] memory executors = new address[](1);
        executors[0] = executor;
        t = new Timelock(minDelay, proposers, executors);
        d.timelock = t;
    }

    /// @notice Hands every admin role to the Timelock, operational roles to their holders, and renounces the
    ///         deployer's admin roles. After this the deployer has no admin power.
    function _handover(Deployment memory d, Roles memory r, address deployer) internal {
        address t = address(d.timelock);
        bytes32 admin = 0x00;

        d.clock.grantRole(admin, t);
        d.clock.grantRole(d.clock.CALENDAR_ROLE(), t);
        d.oracle.grantRole(admin, t);
        d.oracle.grantRole(d.oracle.FEED_ADMIN_ROLE(), t);
        d.note.grantRole(admin, t);
        d.compliance.grantRole(admin, t);
        d.compliance.grantRole(d.compliance.COMPLIANCE_ROLE(), r.complianceOperator);
        d.feeCollector.grantRole(admin, t);
        d.hooks.grantRole(admin, t);
        d.hooks.grantRole(d.hooks.GUARDIAN_ROLE(), r.guardian);
        d.factory.grantRole(admin, t);
        d.factory.grantRole(d.factory.GUARDIAN_ROLE(), r.guardian);
        d.factory.grantRole(d.factory.CURATOR_ROLE(), r.curator);
        d.pool.grantRole(admin, t);
        d.pool.grantRole(d.pool.GUARDIAN_ROLE(), r.guardian);
        d.settlement.grantRole(admin, t);
        d.settlement.grantRole(d.settlement.GUARDIAN_ROLE(), r.guardian);
        d.listings.grantRole(admin, t);
        d.listings.grantRole(d.listings.GUARDIAN_ROLE(), r.guardian);
        d.holdAdapter.grantRole(admin, t);
        if (address(d.vaultAdapter) != address(0)) d.vaultAdapter.grantRole(admin, t);

        if (deployer != t) {
            d.clock.renounceRole(d.clock.CALENDAR_ROLE(), deployer);
            d.clock.renounceRole(admin, deployer);
            d.oracle.renounceRole(d.oracle.FEED_ADMIN_ROLE(), deployer);
            d.oracle.renounceRole(admin, deployer);
            d.note.renounceRole(admin, deployer);
            if (r.complianceOperator != deployer) {
                d.compliance.renounceRole(d.compliance.COMPLIANCE_ROLE(), deployer);
            }
            d.compliance.renounceRole(admin, deployer);
            d.feeCollector.renounceRole(admin, deployer);
            d.hooks.renounceRole(admin, deployer);
            d.factory.renounceRole(admin, deployer);
            d.pool.renounceRole(admin, deployer);
            d.settlement.renounceRole(admin, deployer);
            d.listings.renounceRole(admin, deployer);
            d.holdAdapter.renounceRole(admin, deployer);
            if (address(d.vaultAdapter) != address(0)) d.vaultAdapter.renounceRole(admin, deployer);
        }
    }

    /// @notice NYSE full-day holidays and early closes, 2026-2027 (UTC day numbers). Source: NYSE holiday calendar
    ///         https://www.nyse.com/markets/hours-calendars . Extend yearly via the Timelock (MarketClock.setDayStatus).
    function _nyseCalendar() internal pure returns (uint256[] memory days_, uint8[] memory statuses) {
        // y, m, d, status (1 = closed, 2 = early close 13:00 ET)
        uint24[4][24] memory cal = [
            [uint24(2026), 1, 1, 1],
            [uint24(2026), 1, 19, 1],
            [uint24(2026), 2, 16, 1],
            [uint24(2026), 4, 3, 1],
            [uint24(2026), 5, 25, 1],
            [uint24(2026), 6, 19, 1],
            [uint24(2026), 7, 3, 1],
            [uint24(2026), 9, 7, 1],
            [uint24(2026), 11, 26, 1],
            [uint24(2026), 11, 27, 2],
            [uint24(2026), 12, 24, 2],
            [uint24(2026), 12, 25, 1],
            [uint24(2027), 1, 1, 1],
            [uint24(2027), 1, 18, 1],
            [uint24(2027), 2, 15, 1],
            [uint24(2027), 3, 26, 1],
            [uint24(2027), 5, 31, 1],
            [uint24(2027), 6, 18, 1],
            [uint24(2027), 7, 5, 1],
            [uint24(2027), 9, 6, 1],
            [uint24(2027), 11, 25, 1],
            [uint24(2027), 11, 26, 2],
            [uint24(2027), 12, 24, 1],
            [uint24(2027), 12, 31, 0]
        ];
        days_ = new uint256[](24);
        statuses = new uint8[](24);
        for (uint256 i; i < 24; ++i) {
            days_[i] = _daysFromCivil(cal[i][0], cal[i][1], cal[i][2]);
            statuses[i] = uint8(cal[i][3]);
        }
    }

    function _daysFromCivil(uint256 y, uint256 m, uint256 d) internal pure returns (uint256) {
        if (m <= 2) y -= 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 mp = m > 2 ? m - 3 : m + 9;
        uint256 doy = (153 * mp + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146097 + doe - 719468;
    }
}
