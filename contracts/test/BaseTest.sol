// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {FloorcapDeployer} from "../script/FloorcapDeployer.sol";
import {ISeriesFactory} from "../src/interfaces/ISeriesFactory.sol";
import {MockERC20, MockAggregator, MockVault} from "./mocks/Mocks.sol";

abstract contract BaseTest is Test, FloorcapDeployer {
    uint256 internal constant WAD = 1e18;

    Deployment internal d;
    MockERC20 internal usdg;
    MockERC20 internal aapl;
    MockERC20 internal nvda;
    MockERC20 internal fcap; // mock project token: tests only
    MockAggregator internal aaplFeed;
    MockAggregator internal aaplFeed2;
    MockAggregator internal nvdaFeed;
    MockVault internal vault;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal uw1 = makeAddr("uw1");
    address internal uw2 = makeAddr("uw2");
    address internal treasury = makeAddr("treasury");

    uint256 internal day0; // Monday 2026-11-02

    function setUp() public virtual {
        day0 = _daysFromCivil(2026, 11, 2);
        vm.warp(day0 * 1 days + 14 hours); // 09:00 ET (EST)

        usdg = new MockERC20("Global Dollar", "USDG", 6);
        aapl = new MockERC20("Apple", "AAPL", 18);
        nvda = new MockERC20("NVIDIA", "NVDA", 18);
        fcap = new MockERC20("Floorcap", "FCAP", 18);
        vault = new MockVault(usdg);

        d = _deployCore(
            CoreConfig({
                deployer: address(this),
                stable: address(usdg),
                yieldVault: address(vault),
                reserveShareBps: 2_000,
                stakerShareBps: 3_000,
                listingFeeBps: 50,
                minPriorityStake: 1_000e18,
                unstakeCooldown: 7 days,
                noteUri: "https://floorcap.example/api/note/{id}.json"
            })
        );
        (uint256[] memory days_, uint8[] memory st) = _nyseCalendar();
        d.clock.setDayStatus(days_, st);

        aaplFeed = new MockAggregator(8);
        aaplFeed2 = new MockAggregator(8);
        nvdaFeed = new MockAggregator(8);
        aaplFeed.push(200e8);
        aaplFeed2.push(200e8);
        nvdaFeed.push(100e8);
        d.oracle.setFeed(address(aapl), address(aaplFeed), address(aaplFeed2), 1 days, 100);
        d.oracle.setFeed(address(nvda), address(nvdaFeed), address(0), 1 days, 100);

        d.factory.grantRole(d.factory.CURATOR_ROLE(), address(this));
        d.factory.grantRole(d.factory.GUARDIAN_ROLE(), address(this));
        d.pool.grantRole(d.pool.GUARDIAN_ROLE(), address(this));
        d.settlement.grantRole(d.settlement.GUARDIAN_ROLE(), address(this));
        d.listings.grantRole(d.listings.GUARDIAN_ROLE(), address(this));
        d.hooks.grantRole(d.hooks.GUARDIAN_ROLE(), address(this));

        address[5] memory users = [alice, bob, carol, uw1, uw2];
        for (uint256 i; i < users.length; ++i) {
            usdg.mint(users[i], 10_000_000e6);
            aapl.mint(users[i], 1_000_000e18);
            nvda.mint(users[i], 1_000_000e18);
            vm.startPrank(users[i]);
            usdg.approve(address(d.factory), type(uint256).max);
            usdg.approve(address(d.listings), type(uint256).max);
            aapl.approve(address(d.pool), type(uint256).max);
            nvda.approve(address(d.pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ---------------------------------------------------------------- helpers

    function _subEnd() internal view returns (uint64) {
        return uint64(d.clock.closeTime(day0 + 2)); // Wednesday close
    }

    function _params(uint16 protectionBps, uint8 tenor, address yieldAdapter, uint16 yieldBps)
        internal
        view
        returns (ISeriesFactory.SeriesParams memory p)
    {
        address[] memory tokens = new address[](1);
        tokens[0] = address(aapl);
        uint256[] memory qty = new uint256[](1);
        qty[0] = 1e18;
        p = ISeriesFactory.SeriesParams({
            name: "AAPL 12M 95%",
            stable: address(usdg),
            yieldAdapter: yieldAdapter,
            optionsAdapter: address(d.pool),
            tokens: tokens,
            quantities: qty,
            subscriptionStart: uint64(block.timestamp),
            subscriptionEnd: _subEnd(),
            tenorMonths: tenor,
            protectionBps: protectionBps,
            assumedYieldBps: yieldBps,
            premiumBps: 1_200,
            structuringFeeBps: 50,
            exitFeeBps: 100,
            cap: 1_000_000e6,
            minSize: 1_000e6
        });
    }

    function _basketParams() internal view returns (ISeriesFactory.SeriesParams memory p) {
        p = _params(9_500, 6, address(d.holdAdapter), 0);
        address[] memory tokens = new address[](2);
        tokens[0] = address(aapl);
        tokens[1] = address(nvda);
        uint256[] memory qty = new uint256[](2);
        qty[0] = 0.5e18;
        qty[1] = 1e18;
        p.tokens = tokens;
        p.quantities = qty;
        p.name = "AAPL+NVDA 6M 95%";
    }

    function _createDefault() internal returns (uint256) {
        return d.factory.createSeries(_params(9_500, 12, address(d.holdAdapter), 0));
    }

    function _subscribe(address who, uint256 id, uint256 amount) internal {
        vm.prank(who);
        d.factory.subscribe(id, amount);
    }

    function _commit(address who, uint256 id, uint256 units) internal {
        vm.prank(who);
        d.pool.commit(id, units);
    }

    function _feedsOf(uint256 id) internal view returns (address[] memory tokens) {
        (tokens,) = d.factory.getBasket(id);
    }

    function _primary(address token) internal view returns (MockAggregator) {
        if (token == address(aapl)) return aaplFeed;
        return nvdaFeed;
    }

    /// @dev Pushes one fresh round per feed at `ts` and returns the round ids (primary, secondary).
    function _pushAt(uint256 id, uint256 ts, int256[] memory prices)
        internal
        returns (uint80[] memory ph, uint80[] memory sh)
    {
        address[] memory tokens = _feedsOf(id);
        ph = new uint80[](tokens.length);
        sh = new uint80[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            ph[i] = _primary(tokens[i]).pushAt(prices[i], ts);
            if (tokens[i] == address(aapl)) sh[i] = aaplFeed2.pushAt(prices[i], ts);
        }
    }

    function _prices1(int256 a) internal pure returns (int256[] memory p) {
        p = new int256[](1);
        p[0] = a;
    }

    function _prices2(int256 a, int256 b) internal pure returns (int256[] memory p) {
        p = new int256[](2);
        p[0] = a;
        p[1] = b;
    }

    function _lock(uint256 id, int256[] memory prices) internal {
        ISeriesFactory.Series memory s = d.factory.getSeries(id);
        vm.warp(s.subscriptionEnd - 60);
        (uint80[] memory ph, uint80[] memory sh) = _pushAt(id, block.timestamp, prices);
        vm.warp(s.subscriptionEnd + 60);
        d.factory.lock(id, ph, sh);
    }

    function _settle(uint256 id, int256[] memory prices) internal {
        ISeriesFactory.Series memory s = d.factory.getSeries(id);
        vm.warp(s.maturity - 60);
        (uint80[] memory ph, uint80[] memory sh) = _pushAt(id, block.timestamp, prices);
        vm.warp(s.maturity + 60);
        d.settlement.settle(id, ph, sh);
    }

    /// @dev Warp to a regular-session moment and refresh every feed so live prices are valid.
    function _toSessionWithPrices(uint256 id, uint256 day, int256[] memory prices) internal {
        vm.warp(d.clock.openTime(day) + 1 hours);
        _pushAt(id, block.timestamp, prices);
    }

    function _claimAlloc(uint256 id, address who) internal {
        d.factory.claimAllocation(id, who);
    }
}
