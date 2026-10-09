// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {ISeriesFactory} from "../../src/interfaces/ISeriesFactory.sol";
import {SeriesFactory} from "../../src/SeriesFactory.sol";
import {Settlement} from "../../src/Settlement.sol";
import {UnderwriterPool} from "../../src/UnderwriterPool.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract LifecycleTest is BaseTest {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = _createDefault();
        _commit(uw1, id, 600e18);
        _commit(uw2, id, 400e18);
    }

    // ---------------------------------------------------------------- terms

    function test_quoteTerms_holdAdapter95() public view {
        ISeriesFactory.Series memory s = d.factory.getSeries(id);
        assertEq(s.bondWad, 0.95e18);
        assertEq(s.participationWad, 0.375e18);
        assertEq(uint256(s.state), uint256(ISeriesFactory.State.Subscription));
        assertTrue(d.clock.isCloseTimestamp(s.maturity));
        assertGe(s.maturity, s.subscriptionEnd + 365 days);
    }

    function test_quoteTerms_withYield() public view {
        (uint256 bond, uint256 part) = d.factory.quoteTerms(10_000, 450, 1_200, 50, 365 days);
        // 1 / 1.045 = 0.956937..., budget = 1 - 0.956938 - 0.005 = 0.038062 -> /0.12 = 0.3172
        assertApproxEqAbs(bond, 0.956937799043062201e18, 1);
        assertApproxEqRel(part, 0.31718e18, 1e14);
        (, uint256 zero) = d.factory.quoteTerms(10_000, 0, 1_200, 50, 365 days);
        assertEq(zero, 0);
        (, uint256 zeroPrem) = d.factory.quoteTerms(9_500, 0, 0, 50, 365 days);
        assertEq(zeroPrem, 0);
    }

    // ---------------------------------------------------------------- full lifecycle

    function test_lifecycle_upside() public {
        _subscribe(alice, id, 100_000e6);
        _lock(id, _prices1(200e8));

        ISeriesFactory.Series memory s = d.factory.getSeries(id);
        assertEq(uint256(s.state), uint256(ISeriesFactory.State.Locked));
        assertEq(s.accepted, 100_000e6);
        assertEq(s.strike, 200e18);
        assertEq(s.units, 187.5e18);
        assertEq(d.holdAdapter.totalAssets(id), 95_000e6);
        assertEq(usdg.balanceOf(address(d.feeCollector)), 500e6);
        assertEq(usdg.balanceOf(address(d.pool)), 4_500e6);

        _claimAlloc(id, alice);
        assertEq(d.note.balanceOf(alice, id), 100_000e6);

        _settle(id, _prices1(300e8));
        (Settlement.Result memory r, uint256[] memory pay) = d.settlement.resultOf(id);
        assertEq(r.level, 300e18);
        assertEq(r.cash, 95_000e6);
        assertEq(r.payoutUnits, 62.5e18);
        assertEq(pay[0], 62.5e18);

        uint256 usdgBefore = usdg.balanceOf(alice);
        uint256 aaplBefore = aapl.balanceOf(alice);
        vm.prank(alice);
        d.settlement.claim(id, 100_000e6);
        assertEq(usdg.balanceOf(alice) - usdgBefore, 95_000e6);
        assertEq(aapl.balanceOf(alice) - aaplBefore, 62.5e18);
        // value = floor + participation x gain = 95,000 + 100,000 * 0.375 * 50% = 113,750
        assertEq((usdg.balanceOf(alice) - usdgBefore) * 1e12 + (aapl.balanceOf(alice) - aaplBefore) * 300, 113_750e18);

        // underwriters: premium + remaining collateral
        vm.prank(uw1);
        uint256 prem = d.pool.claimPremium(id);
        assertEq(prem, 2_700e6);
        vm.prank(uw1);
        uint256 fin = d.pool.claimFinal(id);
        // used 187.5, paid 62.5 -> 125 units remain; uw1 has 60% of commitments
        assertEq(fin, 75e18);
        vm.prank(uw2);
        d.pool.claimPremium(id);
        vm.prank(uw2);
        d.pool.withdrawUnused(id);
        vm.prank(uw2);
        d.pool.claimFinal(id);
        assertLe(aapl.balanceOf(address(d.pool)), 1e6);
    }

    function test_lifecycle_downside_paysFloor() public {
        _subscribe(alice, id, 50_000e6);
        _subscribe(bob, id, 50_000e6);
        _lock(id, _prices1(200e8));
        _settle(id, _prices1(120e8));
        _claimAlloc(id, alice);
        _claimAlloc(id, bob);
        uint256 before = usdg.balanceOf(bob);
        vm.prank(bob);
        (uint256 cash, uint256[] memory out) = d.settlement.claim(id, 50_000e6);
        assertEq(cash, 47_500e6);
        assertEq(out[0], 0);
        assertEq(usdg.balanceOf(bob) - before, 47_500e6);
        uint256 a0 = aapl.balanceOf(uw1);
        vm.prank(uw1);
        assertEq(d.pool.claimFinal(id), 112.5e18); // used share, nothing paid out
        assertEq(aapl.balanceOf(uw1) - a0, 600e18); // all collateral back incl. unused
    }

    function test_lifecycle_vaultYield_fullProtection() public {
        uint256 vid = d.factory.createSeries(_params(10_000, 12, address(d.vaultAdapter), 400));
        _commit(uw1, vid, 1_000e18);
        _subscribe(alice, vid, 100_000e6);
        _lock(vid, _prices1(200e8));
        ISeriesFactory.Series memory s = d.factory.getSeries(vid);
        uint256 bond = d.vaultAdapter.totalAssets(vid);
        assertApproxEqAbs(bond, 100_000e6 * s.bondWad / 1e18, 2);
        // the vault earns 4.2% over the year (above the assumed 4%)
        usdg.mint(address(vault), bond * 42 / 1000);
        _settle(vid, _prices1(150e8));
        (Settlement.Result memory r,) = d.settlement.resultOf(vid);
        assertGe(r.cash, 100_000e6);
        assertEq(r.reserveUsed, 0);
    }

    function test_basket_settlement() public {
        uint256 bid = d.factory.createSeries(_basketParams());
        _commit(uw1, bid, 1_000e18);
        _subscribe(alice, bid, 10_000e6);
        _lock(bid, _prices2(200e8, 100e8)); // level = 0.5*200 + 100 = 200
        ISeriesFactory.Series memory s = d.factory.getSeries(bid);
        assertEq(s.strike, 200e18);
        _settle(bid, _prices2(300e8, 200e8)); // level = 350, gain 75%
        _claimAlloc(bid, alice);
        vm.prank(alice);
        (uint256 cash, uint256[] memory out) = d.settlement.claim(bid, 10_000e6);
        assertEq(cash, 9_500e6);
        // units = 10,000 * part / 200 ; payout = units * 150/350
        uint256 units = s.units;
        uint256 payoutUnits = units * 150e18 / 350e18;
        assertApproxEqAbs(out[0], payoutUnits / 2, 1);
        assertApproxEqAbs(out[1], payoutUnits, 1);
        uint256 value = cash * 1e12 + out[0] * 300 + out[1] * 200;
        uint256 expected = 9_500e18 + 10_000e18 * s.participationWad / 1e18 * 75 / 100;
        assertApproxEqRel(value, expected, 1e12);
    }

    // ---------------------------------------------------------------- allocation

    function test_oversubscription_priorityStakers() public {
        d.hooks.setProjectToken(address(fcap));
        fcap.mint(alice, 5_000e18);
        vm.startPrank(alice);
        fcap.approve(address(d.hooks), type(uint256).max);
        d.hooks.stake(2_000e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);

        ISeriesFactory.SeriesParams memory p = _params(9_500, 12, address(d.holdAdapter), 0);
        p.cap = 100_000e6;
        uint256 sid = d.factory.createSeries(p);
        _commit(uw1, sid, 1_000e18);
        _subscribe(alice, sid, 80_000e6);
        _subscribe(bob, sid, 80_000e6);
        (uint256 pa,) = d.factory.deposits(sid, alice);
        assertEq(pa, 80_000e6);
        _lock(sid, _prices1(200e8));

        _claimAlloc(sid, alice);
        uint256 before = usdg.balanceOf(bob);
        _claimAlloc(sid, bob);
        assertEq(d.note.balanceOf(alice, sid), 80_000e6);
        assertEq(d.note.balanceOf(bob, sid), 20_000e6);
        assertEq(usdg.balanceOf(bob) - before, 60_000e6);
    }

    function test_priority_requiresStakeBeforeSeries() public {
        d.hooks.setProjectToken(address(fcap));
        fcap.mint(alice, 5_000e18);
        vm.warp(block.timestamp + 1);
        vm.startPrank(alice);
        fcap.approve(address(d.hooks), type(uint256).max);
        d.hooks.stake(2_000e18); // after series `id` was created
        vm.stopPrank();
        _subscribe(alice, id, 1_000e6);
        (uint256 pa, uint256 ra) = d.factory.deposits(id, alice);
        assertEq(pa, 0);
        assertEq(ra, 1_000e6);
    }

    function test_oversubscription_priorityExceedsAccepted() public {
        d.hooks.setProjectToken(address(fcap));
        fcap.mint(alice, 5_000e18);
        vm.startPrank(alice);
        fcap.approve(address(d.hooks), type(uint256).max);
        d.hooks.stake(2_000e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
        ISeriesFactory.SeriesParams memory p = _params(9_500, 12, address(d.holdAdapter), 0);
        p.cap = 40_000e6;
        uint256 sid = d.factory.createSeries(p);
        _commit(uw1, sid, 1_000e18);
        _subscribe(alice, sid, 80_000e6);
        _subscribe(bob, sid, 10_000e6);
        _lock(sid, _prices1(200e8));
        _claimAlloc(sid, alice);
        _claimAlloc(sid, bob);
        assertEq(d.note.balanceOf(alice, sid), 40_000e6);
        assertEq(d.note.balanceOf(bob, sid), 0);
    }

    function test_capacityLimitsAcceptance() public {
        uint256 sid = d.factory.createSeries(_params(9_500, 12, address(d.holdAdapter), 0));
        _commit(uw1, sid, 18.75e18); // covers 10,000 USDG at 0.375 participation and $200 strike
        _subscribe(alice, sid, 50_000e6);
        _lock(sid, _prices1(200e8));
        ISeriesFactory.Series memory s = d.factory.getSeries(sid);
        assertEq(s.accepted, 10_000e6);
        assertLe(s.units, 18.75e18);
        assertEq(s.regularFillWad, 0.2e18);
    }

    function test_withdrawSubscription() public {
        _subscribe(alice, id, 10_000e6);
        uint256 before = usdg.balanceOf(alice);
        vm.prank(alice);
        d.factory.withdrawSubscription(id, 4_000e6);
        assertEq(usdg.balanceOf(alice) - before, 4_000e6);
        vm.expectRevert(SeriesFactory.InsufficientDeposit.selector);
        vm.prank(alice);
        d.factory.withdrawSubscription(id, 7_000e6);
        vm.expectRevert(SeriesFactory.ZeroAmount.selector);
        vm.prank(alice);
        d.factory.withdrawSubscription(id, 0);
        vm.warp(_subEnd());
        vm.expectRevert(SeriesFactory.OutsideWindow.selector);
        vm.prank(alice);
        d.factory.withdrawSubscription(id, 1);
    }

    function test_withdrawSubscription_priorityPortion() public {
        d.hooks.setProjectToken(address(fcap));
        fcap.mint(alice, 5_000e18);
        vm.startPrank(alice);
        fcap.approve(address(d.hooks), type(uint256).max);
        d.hooks.stake(2_000e18);
        vm.stopPrank();
        vm.warp(block.timestamp + 1);
        uint256 sid = d.factory.createSeries(_params(9_500, 12, address(d.holdAdapter), 0));
        _subscribe(alice, sid, 1_000e6);
        vm.prank(alice);
        d.factory.withdrawSubscription(sid, 600e6);
        (uint256 pa,) = d.factory.deposits(sid, alice);
        assertEq(pa, 400e6);
    }

    function test_subscribe_reverts() public {
        vm.expectRevert(SeriesFactory.ZeroAmount.selector);
        vm.prank(alice);
        d.factory.subscribe(id, 0);
        vm.warp(_subEnd());
        vm.expectRevert(SeriesFactory.OutsideWindow.selector);
        vm.prank(alice);
        d.factory.subscribe(id, 1);
        vm.expectRevert(abi.encodeWithSelector(SeriesFactory.WrongState.selector, 1, 0));
        vm.prank(alice);
        d.factory.subscribe(999, 1);
    }

    // ---------------------------------------------------------------- cancellation

    function test_cancel_belowMinSize_refunds() public {
        _subscribe(alice, id, 500e6);
        _lock(id, _prices1(200e8));
        assertEq(uint256(d.factory.seriesState(id)), uint256(ISeriesFactory.State.Cancelled));
        uint256 before = usdg.balanceOf(alice);
        _claimAlloc(id, alice);
        assertEq(usdg.balanceOf(alice) - before, 500e6);
        uint256 a0 = aapl.balanceOf(uw1);
        vm.prank(uw1);
        d.pool.withdrawCancelled(id);
        assertEq(aapl.balanceOf(uw1) - a0, 600e18);
        vm.expectRevert(UnderwriterPool.ZeroAmount.selector);
        vm.prank(uw1);
        d.pool.withdrawCancelled(id);
    }

    function test_cancelStale() public {
        _subscribe(alice, id, 5_000e6);
        vm.warp(_subEnd() + 1 days);
        vm.expectRevert(SeriesFactory.OutsideWindow.selector);
        d.factory.cancelStale(id);
        vm.warp(_subEnd() + 3 days + 1);
        d.factory.cancelStale(id);
        assertEq(uint256(d.factory.seriesState(id)), uint256(ISeriesFactory.State.Cancelled));
    }

    function test_cancelSeries_byCurator_onlyAuthorized() public {
        vm.expectRevert(SeriesFactory.NotAllowed.selector);
        vm.prank(alice);
        d.factory.cancelSeries(id);
        d.factory.cancelSeries(id);
        assertEq(uint256(d.factory.seriesState(id)), uint256(ISeriesFactory.State.Cancelled));
    }

    function test_lock_outsideWindow() public {
        _subscribe(alice, id, 5_000e6);
        uint80[] memory h = new uint80[](1);
        vm.expectRevert(SeriesFactory.OutsideWindow.selector);
        d.factory.lock(id, h, h);
        vm.warp(_subEnd() + 4 days);
        vm.expectRevert(SeriesFactory.OutsideWindow.selector);
        d.factory.lock(id, h, h);
    }

    function test_lock_badHintsLength() public {
        vm.warp(_subEnd() + 1);
        uint80[] memory h = new uint80[](2);
        vm.expectRevert(abi.encodeWithSelector(SeriesFactory.InvalidParams.selector, "hints"));
        d.factory.lock(id, h, h);
    }

    function test_claimAllocation_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(SeriesFactory.WrongState.selector, 2, 1));
        d.factory.claimAllocation(id, alice);
        _subscribe(alice, id, 5_000e6);
        _lock(id, _prices1(200e8));
        vm.expectRevert(SeriesFactory.ZeroAmount.selector);
        d.factory.claimAllocation(id, bob);
    }

    // ---------------------------------------------------------------- early exit

    function test_earlyExit_markToMarket() public {
        _subscribe(alice, id, 100_000e6);
        _lock(id, _prices1(200e8));
        _claimAlloc(id, alice);
        _toSessionWithPrices(id, day0 + 30, _prices1(240e8)); // Dec 2 2026

        (uint256 pCash, uint256[] memory pTok, uint256 value) = d.settlement.previewValue(id, 50_000e6);
        assertEq(pCash, 47_025e6); // 47,500 - 1%
        // units 93.75 * 40/240 = 15.625, less 1%
        assertEq(pTok[0], 15.46875e18);
        assertEq(value, 47_025e18 + 15.46875e18 * 240);

        uint256 u0 = usdg.balanceOf(alice);
        uint256 a0 = aapl.balanceOf(alice);
        vm.prank(alice);
        (uint256 cashOut, uint256[] memory out) = d.settlement.earlyExit(id, 50_000e6, 47_000e6, block.timestamp);
        assertEq(cashOut, 47_025e6);
        assertEq(out[0], 15.46875e18);
        assertEq(usdg.balanceOf(alice) - u0, 47_025e6);
        assertEq(aapl.balanceOf(alice) - a0, 15.46875e18);
        assertEq(d.factory.getSeries(id).liveNotes, 50_000e6);
        assertEq(d.pool.openUnits(id), 93.75e18);
        assertEq(d.feeCollector.treasury(address(aapl)) + d.feeCollector.reserve(address(aapl)), 0.15625e18);

        // the remaining holder still gets their full floor at maturity
        _settle(id, _prices1(100e8));
        vm.prank(alice);
        (uint256 cash,) = d.settlement.claim(id, 50_000e6);
        assertEq(cash, 47_500e6);
    }

    function test_earlyExit_reverts() public {
        _subscribe(alice, id, 100_000e6);
        _lock(id, _prices1(200e8));
        _claimAlloc(id, alice);

        // weekend
        vm.warp((day0 + 5) * 1 days + 16 hours);
        vm.expectRevert(Settlement.MarketClosed.selector);
        vm.prank(alice);
        d.settlement.earlyExit(id, 1_000e6, 0, block.timestamp);

        _toSessionWithPrices(id, day0 + 7, _prices1(200e8));
        vm.expectRevert(Settlement.Expired.selector);
        vm.prank(alice);
        d.settlement.earlyExit(id, 1_000e6, 0, block.timestamp - 1);

        vm.expectRevert(Settlement.ZeroAmount.selector);
        vm.prank(alice);
        d.settlement.earlyExit(id, 0, 0, block.timestamp);

        vm.expectRevert(abi.encodeWithSelector(Settlement.Slippage.selector, 1_000e6, 940.5e6));
        vm.prank(alice);
        d.settlement.earlyExit(id, 1_000e6, 1_000e6, block.timestamp);

        ISeriesFactory.Series memory s = d.factory.getSeries(id);
        vm.warp(s.maturity);
        vm.expectRevert(Settlement.Matured.selector);
        vm.prank(alice);
        d.settlement.earlyExit(id, 1_000e6, 0, block.timestamp);
    }

    function test_earlyExit_wrongState() public {
        vm.expectRevert(Settlement.WrongState.selector);
        d.settlement.earlyExit(id, 1, 0, block.timestamp);
    }

    // ---------------------------------------------------------------- settlement edge cases

    function test_settle_reverts() public {
        uint80[] memory h = new uint80[](1);
        vm.expectRevert(Settlement.WrongState.selector);
        d.settlement.settle(id, h, h);
        _subscribe(alice, id, 100_000e6);
        _lock(id, _prices1(200e8));
        vm.expectRevert(Settlement.NotMatured.selector);
        d.settlement.settle(id, h, h);
        vm.expectRevert(Settlement.WrongState.selector);
        d.settlement.claim(id, 1);
        vm.expectRevert(Settlement.ZeroAmount.selector);
        d.settlement.claim(id, 0);
    }

    function test_settle_shortfall_coveredByReserve() public {
        uint256 vid = d.factory.createSeries(_params(10_000, 12, address(d.vaultAdapter), 400));
        _commit(uw1, vid, 1_000e18);
        _subscribe(alice, vid, 100_000e6);
        _lock(vid, _prices1(200e8));
        // reserve: 20% of the 500 USDG fee from this lock = 100 USDG, plus a donation
        vm.startPrank(bob);
        usdg.approve(address(d.feeCollector), type(uint256).max);
        d.feeCollector.fundReserve(address(usdg), 1_000e6);
        vm.stopPrank();
        assertEq(d.feeCollector.reserve(address(usdg)), 1_100e6);
        // vault earns nothing -> the bond (~96.15k) is short of the 100k floor by ~3.85k
        _settle(vid, _prices1(150e8));
        (Settlement.Result memory r,) = d.settlement.resultOf(vid);
        assertEq(r.reserveUsed, 1_100e6);
        assertEq(d.feeCollector.reserve(address(usdg)), 0);
        assertLt(r.cash, 100_000e6); // documented: floor breaks only if reserve is exhausted
    }

    function test_settle_shortfall_fullyCovered() public {
        uint256 vid = d.factory.createSeries(_params(10_000, 3, address(d.vaultAdapter), 400));
        _commit(uw1, vid, 1_000e18);
        _subscribe(alice, vid, 10_000e6);
        _lock(vid, _prices1(200e8));
        vm.startPrank(bob);
        usdg.approve(address(d.feeCollector), type(uint256).max);
        d.feeCollector.fundReserve(address(usdg), 10_000e6);
        vm.stopPrank();
        vault.slash(1_000e6);
        _settle(vid, _prices1(150e8));
        (Settlement.Result memory r,) = d.settlement.resultOf(vid);
        assertEq(r.cash, 10_000e6);
        assertGt(r.reserveUsed, 1_000e6);
    }

    function test_settleManual() public {
        _subscribe(alice, id, 100_000e6);
        _lock(id, _prices1(200e8));
        ISeriesFactory.Series memory s = d.factory.getSeries(id);
        vm.warp(s.maturity + 1 days);
        vm.expectRevert(Settlement.TooEarlyForManual.selector);
        d.settlement.settleManual(id, 250e18);
        vm.warp(s.maturity + 7 days);
        vm.expectRevert(Settlement.InvalidLevel.selector);
        d.settlement.settleManual(id, 0);
        vm.prank(alice);
        vm.expectRevert();
        d.settlement.settleManual(id, 250e18);
        d.settlement.settleManual(id, 250e18);
        (Settlement.Result memory r,) = d.settlement.resultOf(id);
        assertTrue(r.manual);
        assertEq(r.payoutUnits, 37.5e18);
        vm.expectRevert(Settlement.WrongState.selector);
        d.settlement.settleManual(id, 250e18);
    }

    function test_setManualSettlementDelay() public {
        d.settlement.setManualSettlementDelay(10 days);
        assertEq(d.settlement.manualSettlementDelay(), 10 days);
        vm.expectRevert(Settlement.InvalidDelay.selector);
        d.settlement.setManualSettlementDelay(1 days);
        vm.expectRevert(Settlement.InvalidDelay.selector);
        d.settlement.setManualSettlementDelay(31 days);
    }

    function test_claimAllocation_afterSettlement() public {
        _subscribe(alice, id, 100_000e6);
        _lock(id, _prices1(200e8));
        _settle(id, _prices1(300e8));
        _claimAlloc(id, alice);
        vm.prank(alice);
        (uint256 cash,) = d.settlement.claim(id, 100_000e6);
        assertEq(cash, 95_000e6);
    }

    function test_previewValue_states() public {
        (uint256 c0,, uint256 v0) = d.settlement.previewValue(id, 1_000e6);
        assertEq(c0 + v0, 0);
        _subscribe(alice, id, 100_000e6);
        _lock(id, _prices1(200e8));
        _settle(id, _prices1(300e8));
        _pushAt(id, block.timestamp, _prices1(300e8));
        (uint256 c,, uint256 v) = d.settlement.previewValue(id, 100_000e6);
        assertEq(c, 95_000e6);
        assertEq(v, 113_750e18);
    }

    // ---------------------------------------------------------------- pause

    function test_pause_blocksEntryButNotClaims() public {
        _subscribe(alice, id, 100_000e6);
        d.factory.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        _subscribe(alice, id, 1e6);
        d.factory.unpause();
        _lock(id, _prices1(200e8));
        d.factory.pause();
        _claimAlloc(id, alice); // still works
        d.settlement.pause();
        ISeriesFactory.Series memory s = d.factory.getSeries(id);
        vm.warp(s.maturity + 60);
        uint80[] memory h = new uint80[](1);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        d.settlement.settle(id, h, h);
        d.settlement.unpause();
        _settle(id, _prices1(250e8));
        d.settlement.pause();
        vm.prank(alice);
        d.settlement.claim(id, 1_000e6); // claims never pausable
        vm.expectRevert();
        vm.prank(alice);
        d.factory.pause();
    }
}
