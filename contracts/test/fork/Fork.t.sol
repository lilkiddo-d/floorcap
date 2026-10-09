// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FloorcapDeployer} from "../../script/FloorcapDeployer.sol";
import {RobinhoodAddresses} from "../../script/RobinhoodAddresses.sol";
import {ISeriesFactory} from "../../src/interfaces/ISeriesFactory.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {Settlement} from "../../src/Settlement.sol";

/// @notice Fork tests against Robinhood Chain mainnet with the real USDG, stock tokens and Chainlink feeds.
///         RPC: $ROBINHOOD_RPC_URL (default: public RPC). Block: $FORK_BLOCK (default latest).
contract ForkTest is Test, FloorcapDeployer {
    address constant USDG = RobinhoodAddresses.USDG;
    address constant AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant AAPL_FEED = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address constant AAPL_FEED_SVR = 0x4bDbb3150014c6Ab2C6D9347B0779c49015a2f3f;
    address constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;

    Deployment internal d;
    address internal alice = makeAddr("alice");
    address internal uw = makeAddr("underwriter");

    function setUp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        // The public RPC is not an archive node: fork the latest block unless FORK_BLOCK is set.
        uint256 blockNo = vm.envOr("FORK_BLOCK", uint256(0));
        if (blockNo == 0) vm.createSelectFork(rpc);
        else vm.createSelectFork(rpc, blockNo);
        assertEq(block.chainid, 4663);

        d = _deployCore(
            CoreConfig({
                deployer: address(this),
                stable: USDG,
                yieldVault: address(0),
                reserveShareBps: 2_000,
                stakerShareBps: 3_000,
                listingFeeBps: 50,
                minPriorityStake: 1_000e18,
                unstakeCooldown: 7 days,
                noteUri: ""
            })
        );
        (uint256[] memory days_, uint8[] memory st) = _nyseCalendar();
        d.clock.setDayStatus(days_, st);
        RobinhoodAddresses.Stock[] memory s = RobinhoodAddresses.stocks();
        for (uint256 i; i < s.length; ++i) {
            d.oracle.setFeed(s[i].token, s[i].feed, s[i].feedSecondary, 26 hours, 100);
        }
        d.factory.grantRole(d.factory.CURATOR_ROLE(), address(this));
    }

    /// @notice Every configured stock token is a live ERC-20 and both Chainlink proxies agree within 1%.
    function test_fork_realTokensAndFeeds() public view {
        assertEq(IERC20(USDG).totalSupply() > 0, true);
        RobinhoodAddresses.Stock[] memory s = RobinhoodAddresses.stocks();
        uint256 fresh;
        for (uint256 i; i < s.length; ++i) {
            assertGt(IERC20(s[i].token).totalSupply(), 0, s[i].symbol);
            assertEq(IAggregatorV3(s[i].feed).decimals(), 8);
            (, int256 a,, uint256 upd,) = IAggregatorV3(s[i].feed).latestRoundData();
            (, int256 b,,,) = IAggregatorV3(s[i].feedSecondary).latestRoundData();
            assertGt(a, 0);
            uint256 diff = a > b ? uint256(a - b) : uint256(b - a);
            assertLe(diff * 10_000, uint256(a) * 100, s[i].symbol);
            if (block.timestamp - upd <= 26 hours) {
                (uint256 px,) = d.oracle.latestPrice(s[i].token);
                assertEq(px, uint256(a) * 1e10);
                fresh++;
            }
        }
        assertGt(fresh, 0, "no fresh feed at fork block");
    }

    /// @notice Full lifecycle on real assets: USDG subscription, AAPL underwriting, lock, early exit, settlement.
    function test_fork_fullLifecycle_realAssets() public {
        deal(USDG, alice, 50_000e6);
        _fundAapl(uw, 100e18);

        uint64 subEnd = uint64(d.clock.closeOnOrAfter(block.timestamp + 1 hours));
        address[] memory tokens = new address[](1);
        tokens[0] = AAPL;
        uint256[] memory qty = new uint256[](1);
        qty[0] = 1e18;
        uint256 id = d.factory.createSeries(
            ISeriesFactory.SeriesParams({
                name: "AAPL 6M 95%",
                stable: USDG,
                yieldAdapter: address(d.holdAdapter),
                optionsAdapter: address(d.pool),
                tokens: tokens,
                quantities: qty,
                subscriptionStart: uint64(block.timestamp),
                subscriptionEnd: subEnd,
                tenorMonths: 6,
                protectionBps: 9_500,
                assumedYieldBps: 0,
                premiumBps: 900,
                structuringFeeBps: 50,
                exitFeeBps: 100,
                cap: 1_000_000e6,
                minSize: 1_000e6
            })
        );

        vm.startPrank(uw);
        IERC20(AAPL).approve(address(d.pool), type(uint256).max);
        d.pool.commit(id, 100e18);
        vm.stopPrank();
        vm.startPrank(alice);
        IERC20(USDG).approve(address(d.factory), type(uint256).max);
        d.factory.subscribe(id, 20_000e6);
        vm.stopPrank();

        // Lock: strike = real AAPL Chainlink price, carried forward as the round in effect at the close.
        (int256 spot,) = _latest(AAPL_FEED);
        vm.warp(subEnd - 30);
        (uint80[] memory ph, uint80[] memory sh) = _nextRound(spot);
        vm.warp(subEnd + 60);
        d.factory.lock(id, ph, sh);
        ISeriesFactory.Series memory s = d.factory.getSeries(id);
        assertEq(s.strike, uint256(spot) * 1e10);
        assertEq(uint256(s.state), uint256(ISeriesFactory.State.Locked));
        d.factory.claimAllocation(id, alice);
        console2.log("strike (USD 1e18):", s.strike);
        console2.log("participation (1e18 = 100%):", s.participationWad);

        // Early exit of 25% during a regular session at +10%.
        uint256 day = block.timestamp / 1 days + 7;
        while (!d.clock.isTradingDay(day)) day++;
        vm.warp(d.clock.openTime(day) + 1 hours);
        vm.clearMockedCalls();
        _nextRound(spot * 110 / 100);
        uint256 aaplBefore = IERC20(AAPL).balanceOf(alice);
        vm.prank(alice);
        (uint256 cashOut,) = d.settlement.earlyExit(id, 5_000e6, 4_600e6, block.timestamp);
        assertEq(cashOut, 4_702.5e6);
        assertGt(IERC20(AAPL).balanceOf(alice), aaplBefore);

        // Settlement at the maturity close at +30%: floor in USDG + upside in real AAPL tokens.
        vm.clearMockedCalls();
        vm.warp(s.maturity - 30);
        (ph, sh) = _nextRound(spot * 130 / 100);
        vm.warp(s.maturity + 60);
        d.settlement.settle(id, ph, sh);
        uint256 usdgBefore = IERC20(USDG).balanceOf(alice);
        aaplBefore = IERC20(AAPL).balanceOf(alice);
        vm.prank(alice);
        (uint256 cash, uint256[] memory out) = d.settlement.claim(id, 15_000e6);
        assertEq(cash, 14_250e6);
        assertEq(IERC20(USDG).balanceOf(alice) - usdgBefore, 14_250e6);
        assertEq(IERC20(AAPL).balanceOf(alice) - aaplBefore, out[0]);
        uint256 upsideUsd = out[0] * uint256(spot * 130 / 100) * 1e10 / 1e18;
        // value of the in-kind upside = principal x participation x gain
        uint256 expected = 15_000e18 * s.participationWad / 1e18 * 30 / 100;
        assertApproxEqRel(upsideUsd, expected, 1e15);

        vm.startPrank(uw);
        d.pool.claimPremium(id);
        d.pool.claimFinal(id);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- helpers

    function _fundAapl(address to, uint256 amount) internal {
        // Stock tokens are upgradeable proxies; try storage-based deal first, else move from a live holder.
        try this.dealExternal(AAPL, to, amount) {
            if (IERC20(AAPL).balanceOf(to) >= amount) return;
        } catch {}
        address holder = 0x8bb3514e2204E1cDF3Ac149EFEe7Ff04D91B719f; // AAPL holder seen in on-chain Transfer logs
        vm.prank(holder);
        IERC20(AAPL).transfer(to, amount);
    }

    function dealExternal(address token, address to, uint256 amount) external {
        deal(token, to, amount);
    }

    function _latest(address feed) internal view returns (int256 answer, uint80 id) {
        (id, answer,,,) = IAggregatorV3(feed).latestRoundData();
    }

    /// @dev Simulates the next Chainlink round (at block.timestamp) on both real AAPL proxies via mockCall,
    ///      since a fork cannot receive new oracle reports. Returns the hints for that round.
    function _nextRound(int256 answer) internal returns (uint80[] memory ph, uint80[] memory sh) {
        ph = new uint80[](1);
        sh = new uint80[](1);
        ph[0] = _mockNext(AAPL_FEED, answer);
        sh[0] = _mockNext(AAPL_FEED_SVR, answer);
    }

    function _mockNext(address feed, int256 answer) internal returns (uint80 next) {
        (, uint80 id) = _latest(feed);
        next = id + 1;
        bytes memory ret = abi.encode(next, answer, block.timestamp, block.timestamp, next);
        vm.mockCall(feed, abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector), ret);
        vm.mockCall(feed, abi.encodeWithSelector(IAggregatorV3.getRoundData.selector, next), ret);
        vm.mockCallRevert(feed, abi.encodeWithSelector(IAggregatorV3.getRoundData.selector, next + 1), "No data present");
    }
}
