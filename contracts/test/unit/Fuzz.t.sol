// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {ISeriesFactory} from "../../src/interfaces/ISeriesFactory.sol";
import {Settlement} from "../../src/Settlement.sol";

contract FuzzTest is BaseTest {
    /// @notice Payoff = floor + participation x max(gain, 0), floor always paid with a solvent yield source.
    function testFuzz_payoff(uint256 deposit, uint256 strikePx, uint256 finalPx, bool fullProtection) public {
        deposit = bound(deposit, 1_000e6, 500_000e6);
        strikePx = bound(strikePx, 1e8, 5_000e8);
        finalPx = bound(finalPx, 1e6, 20_000e8);
        uint256 sid = fullProtection
            ? d.factory.createSeries(_params(10_000, 12, address(d.vaultAdapter), 500))
            : d.factory.createSeries(_params(9_500, 12, address(d.holdAdapter), 0));
        _commit(uw1, sid, 1_000_000e18 / 2);
        _subscribe(alice, sid, deposit);
        _lock(sid, _prices1(int256(strikePx)));
        ISeriesFactory.Series memory s = d.factory.getSeries(sid);
        if (fullProtection) {
            // solvent yield source: vault earns exactly the assumed 5% (plus 1 bp buffer)
            uint256 bond = d.vaultAdapter.totalAssets(sid);
            usdg.mint(address(vault), bond * 501 / 10_000 + 10);
        }
        _settle(sid, _prices1(int256(finalPx)));
        _claimAlloc(sid, alice);
        vm.prank(alice);
        (uint256 cash, uint256[] memory out) = d.settlement.claim(sid, deposit);

        assertGe(cash, deposit * s.protectionBps / 10_000 - 1, "floor");
        _checkUpside(deposit, s.participationWad, strikePx * 1e10, finalPx * 1e10, out[0]);
    }

    function _checkUpside(uint256 deposit, uint256 partWad, uint256 strike, uint256 level, uint256 outUnits)
        internal
        pure
    {
        if (level <= strike) {
            assertEq(outUnits, 0);
            return;
        }
        uint256 upsideUsd = outUnits * level / 1e18;
        uint256 expected = deposit * 1e12 * partWad / 1e18 * (level - strike) / strike;
        assertApproxEqRel(upsideUsd, expected, 1e12, "upside");
    }

    /// @notice Early exits never reduce what the remaining holders receive at maturity.
    function testFuzz_exitsDoNotHurtRemainingHolders(
        uint256 a,
        uint256 b,
        uint256 exitFrac,
        uint256 exitPx,
        uint256 finalPx
    ) public {
        a = bound(a, 1_000e6, 300_000e6);
        b = bound(b, 1_000e6, 300_000e6);
        exitFrac = bound(exitFrac, 1, 10_000);
        exitPx = bound(exitPx, 50e8, 800e8);
        finalPx = bound(finalPx, 10e8, 800e8);
        uint256 sid = _createDefault();
        _commit(uw1, sid, 400_000e18);
        _subscribe(alice, sid, a);
        _subscribe(bob, sid, b);
        _lock(sid, _prices1(200e8));
        _claimAlloc(sid, alice);
        _claimAlloc(sid, bob);

        uint256 exitAmt = a * exitFrac / 10_000;
        if (exitAmt > 0) {
            _toSessionWithPrices(sid, day0 + 9, _prices1(int256(exitPx)));
            vm.prank(alice);
            d.settlement.earlyExit(sid, exitAmt, 0, block.timestamp);
        }
        _settle(sid, _prices1(int256(finalPx)));
        vm.prank(bob);
        (uint256 cash, uint256[] memory out) = d.settlement.claim(sid, b);
        assertGe(cash + 1, b * 9_500 / 10_000);
        ISeriesFactory.Series memory s = d.factory.getSeries(sid);
        if (finalPx > 200e8) {
            uint256 expectedUnits = b * 1e12 * s.participationWad / 200e18 * (finalPx - 200e8) / finalPx;
            assertApproxEqAbs(out[0], expectedUnits, 1e9);
        }
    }

    /// @notice Bond leg grows to at least the floor at the assumed yield.
    function testFuzz_quoteTerms_bondCoversFloor(uint16 yieldBps, uint256 duration, bool full) public view {
        yieldBps = uint16(bound(yieldBps, 0, 1_000));
        duration = bound(duration, 80 days, 400 days);
        uint256 prot = full ? 10_000 : 9_500;
        (uint256 bond, uint256 part) = d.factory.quoteTerms(prot, yieldBps, 1_200, 50, duration);
        uint256 grown = bond * (1e18 + uint256(yieldBps) * 1e14 * duration / 365 days) / 1e18;
        assertGe(grown, prot * 1e14);
        if (part > 0) assertLe(bond + 50e14 + part * 1_200e14 / 1e18, 1e18);
    }

    /// @notice Underwriter claims plus note payouts never exceed posted collateral, for any price.
    function testFuzz_underwriterSolvency(uint256 c1, uint256 c2, uint256 dep, uint256 finalPx) public {
        c1 = bound(c1, 1e18, 10_000e18);
        c2 = bound(c2, 1e18, 10_000e18);
        dep = bound(dep, 1_000e6, 2_000_000e6);
        finalPx = bound(finalPx, 1e8, 100_000e8);
        uint256 sid = _createDefault();
        uint256 before = aapl.balanceOf(address(d.pool));
        _commit(uw1, sid, c1);
        _commit(uw2, sid, c2);
        _subscribe(alice, sid, dep);
        _lock(sid, _prices1(200e8));
        if (d.factory.seriesState(sid) != ISeriesFactory.State.Locked) return;
        _settle(sid, _prices1(int256(finalPx)));
        vm.prank(uw1);
        d.pool.claimFinal(sid);
        vm.prank(uw2);
        d.pool.claimFinal(sid);
        (, uint256[] memory pay) = d.settlement.resultOf(sid);
        assertGe(aapl.balanceOf(address(d.pool)), before); // never dips into other series
        assertLe(pay[0], c1 + c2);
    }
}
