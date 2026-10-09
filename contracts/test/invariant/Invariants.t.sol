// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {BaseTest} from "../BaseTest.sol";
import {ISeriesFactory} from "../../src/interfaces/ISeriesFactory.sol";
import {SeriesFactory} from "../../src/SeriesFactory.sol";
import {UnderwriterPool} from "../../src/UnderwriterPool.sol";
import {Settlement} from "../../src/Settlement.sol";
import {MarketClock} from "../../src/MarketClock.sol";
import {Note} from "../../src/Note.sol";
import {HoldYieldAdapter} from "../../src/adapters/HoldYieldAdapter.sol";
import {MockERC20, MockAggregator} from "../mocks/Mocks.sol";

/// @notice Drives one series through random subscriptions, commitments, lock, early exits, settlement and claims.
contract Handler is Test {
    SeriesFactory internal factory;
    UnderwriterPool internal pool;
    Settlement internal settlement;
    MarketClock internal clock;
    Note internal note;
    MockERC20 internal usdg;
    MockAggregator internal feed;
    MockAggregator internal feed2;
    uint256 internal id;

    address[] internal users;
    address[] internal uws;

    uint256 public floorViolations;
    uint256 public claims;
    uint256 public exits;

    constructor(
        SeriesFactory f,
        UnderwriterPool p,
        Settlement s,
        MarketClock c,
        Note n,
        MockERC20 u,
        MockAggregator fd,
        MockAggregator fd2,
        uint256 id_,
        address[] memory users_,
        address[] memory uws_
    ) {
        factory = f;
        pool = p;
        settlement = s;
        clock = c;
        note = n;
        usdg = u;
        feed = fd;
        feed2 = fd2;
        id = id_;
        users = users_;
        uws = uws_;
    }

    function _s() internal view returns (ISeriesFactory.Series memory) {
        return factory.getSeries(id);
    }

    function subscribe(uint256 who, uint256 amount) external {
        ISeriesFactory.Series memory s = _s();
        if (s.state != ISeriesFactory.State.Subscription || block.timestamp >= s.subscriptionEnd) return;
        amount = bound(amount, 1e6, 300_000e6);
        vm.prank(users[who % users.length]);
        factory.subscribe(id, amount);
    }

    function commit(uint256 who, uint256 units) external {
        ISeriesFactory.Series memory s = _s();
        if (s.state != ISeriesFactory.State.Subscription || block.timestamp >= s.subscriptionEnd) return;
        units = bound(units, 1e18, 2_000e18);
        vm.prank(uws[who % uws.length]);
        pool.commit(id, units);
    }

    function lock(uint256 px) external {
        ISeriesFactory.Series memory s = _s();
        if (s.state != ISeriesFactory.State.Subscription) return;
        px = bound(px, 20e8, 1_000e8);
        vm.warp(s.subscriptionEnd - 60);
        uint80[] memory ph = new uint80[](1);
        uint80[] memory sh = new uint80[](1);
        ph[0] = feed.pushAt(int256(px), block.timestamp);
        sh[0] = feed2.pushAt(int256(px), block.timestamp);
        vm.warp(s.subscriptionEnd + 60);
        factory.lock(id, ph, sh);
    }

    function claimAllocation(uint256 who) external {
        ISeriesFactory.State st = factory.seriesState(id);
        if (st == ISeriesFactory.State.Subscription || st == ISeriesFactory.State.None) return;
        address u = users[who % users.length];
        (uint256 p, uint256 r) = factory.deposits(id, u);
        if (p + r == 0) return;
        factory.claimAllocation(id, u);
    }

    function earlyExit(uint256 who, uint256 frac, uint256 px, uint256 daysAhead) external {
        ISeriesFactory.Series memory s = _s();
        if (s.state != ISeriesFactory.State.Locked) return;
        address u = users[who % users.length];
        uint256 bal = note.balanceOf(u, id);
        if (bal == 0) return;
        uint256 day = block.timestamp / 1 days + 1 + bound(daysAhead, 0, 20);
        while (!clock.isTradingDay(day)) day++;
        uint256 t = clock.openTime(day) + 1 hours;
        if (t >= s.maturity) return;
        vm.warp(t);
        px = bound(px, 20e8, 1_000e8);
        feed.push(int256(px));
        feed2.push(int256(px));
        uint256 amt = bound(frac, 1, bal);
        vm.prank(u);
        settlement.earlyExit(id, amt, 0, block.timestamp);
        exits++;
    }

    function settle(uint256 px) external {
        ISeriesFactory.Series memory s = _s();
        if (s.state != ISeriesFactory.State.Locked) return;
        px = bound(px, 1e8, 2_000e8);
        if (block.timestamp > s.maturity - 60) return;
        vm.warp(s.maturity - 60);
        uint80[] memory ph = new uint80[](1);
        uint80[] memory sh = new uint80[](1);
        ph[0] = feed.pushAt(int256(px), block.timestamp);
        sh[0] = feed2.pushAt(int256(px), block.timestamp);
        vm.warp(s.maturity + 60);
        settlement.settle(id, ph, sh);
    }

    function claim(uint256 who) external {
        if (factory.seriesState(id) != ISeriesFactory.State.Settled) return;
        address u = users[who % users.length];
        uint256 bal = note.balanceOf(u, id);
        if (bal == 0) return;
        ISeriesFactory.Series memory s = _s();
        vm.prank(u);
        (uint256 cash,) = settlement.claim(id, bal);
        if (cash + 1 < bal * s.protectionBps / 10_000) floorViolations++;
        claims++;
    }
}

contract InvariantsTest is BaseTest {
    Handler internal handler;
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = _createDefault();
        address[] memory us = new address[](3);
        us[0] = alice;
        us[1] = bob;
        us[2] = carol;
        address[] memory uw = new address[](2);
        uw[0] = uw1;
        uw[1] = uw2;
        handler = new Handler(
            d.factory, d.pool, d.settlement, d.clock, d.note, usdg, aaplFeed, aaplFeed2, id, us, uw
        );
        targetContract(address(handler));
    }

    /// @notice Underwriter collateral always covers the maximum possible call payout of open calls.
    function invariant_collateralCoversMaxPayout() public view {
        uint256 open = d.pool.openUnits(id);
        assertGe(aapl.balanceOf(address(d.pool)), open); // quantity = 1e18 per unit
    }

    /// @notice While locked, the (solvent) bond leg holds at least the floor of every live note.
    function invariant_bondLegCoversFloorOfLiveNotes() public view {
        ISeriesFactory.Series memory s = d.factory.getSeries(id);
        if (s.state != ISeriesFactory.State.Locked) return;
        assertGe(d.holdAdapter.totalAssets(id) + 1, s.liveNotes * s.protectionBps / 10_000);
    }

    /// @notice After settlement, every note can still claim at least its floor.
    function invariant_everyNoteCanClaimFloor() public view {
        assertEq(handler.floorViolations(), 0);
        if (d.factory.seriesState(id) != ISeriesFactory.State.Settled) return;
        (Settlement.Result memory r,) = d.settlement.resultOf(id);
        ISeriesFactory.Series memory s = d.factory.getSeries(id);
        assertGe(r.cash + 1, r.notes * s.protectionBps / 10_000);
        uint256 outstanding = d.note.totalSupply(id) + _unclaimedAllocations();
        assertGe(usdg.balanceOf(address(d.settlement)) + 2, r.cash * outstanding / (r.notes == 0 ? 1 : r.notes));
    }

    /// @notice Notes in existence never exceed accepted principal net of exits.
    function invariant_noteSupplyBounded() public view {
        ISeriesFactory.Series memory s = d.factory.getSeries(id);
        if (s.state == ISeriesFactory.State.Locked) assertLe(d.note.totalSupply(id), s.liveNotes);
    }

    function _unclaimedAllocations() internal view returns (uint256 sum) {
        ISeriesFactory.Series memory s = d.factory.getSeries(id);
        address[3] memory us = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            (uint256 p, uint256 r) = d.factory.deposits(id, us[i]);
            sum += p * s.priorityFillWad / 1e18 + r * s.regularFillWad / 1e18;
        }
    }
}
