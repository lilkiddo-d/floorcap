// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MarketClock} from "../../src/MarketClock.sol";

contract MarketClockTest is Test {
    MarketClock clock;

    function setUp() public {
        clock = new MarketClock(address(this));
    }

    function _day(uint256 y, uint256 m, uint256 d) internal view returns (uint256) {
        return clock.daysFromCivil(y, m, d);
    }

    function test_weekdayAndCivil() public view {
        assertEq(clock.weekday(0), 4); // Thursday 1970-01-01
        uint256 day = _day(2026, 10, 8);
        assertEq(clock.weekday(day), 4); // Thursday
        (uint256 y, uint256 m, uint256 d) = clock.civilFromDays(day);
        assertEq(y, 2026);
        assertEq(m, 10);
        assertEq(d, 8);
        (y, m, d) = clock.civilFromDays(_day(2028, 2, 29));
        assertEq(m * 100 + d, 229);
        (y, m,) = clock.civilFromDays(_day(2027, 1, 15));
        assertEq(y, 2027);
        assertEq(m, 1);
    }

    function testFuzz_civilRoundTrip(uint256 day) public view {
        day = bound(day, 0, 200_000);
        (uint256 y, uint256 m, uint256 d) = clock.civilFromDays(day);
        assertEq(clock.daysFromCivil(y, m, d), day);
    }

    function test_dstBoundaries2026() public view {
        // DST 2026: starts Sun Mar 8, ends Sun Nov 1
        assertFalse(clock.isDst(_day(2026, 3, 6)));
        assertTrue(clock.isDst(_day(2026, 3, 9)));
        assertTrue(clock.isDst(_day(2026, 10, 30)));
        assertFalse(clock.isDst(_day(2026, 11, 2)));
        assertFalse(clock.isDst(_day(2026, 1, 15)));
        assertTrue(clock.isDst(_day(2026, 7, 1)));
        assertFalse(clock.isDst(_day(2026, 12, 1)));
        // 2027: Mar 14 - Nov 7
        assertFalse(clock.isDst(_day(2027, 3, 12)));
        assertTrue(clock.isDst(_day(2027, 3, 15)));
        assertTrue(clock.isDst(_day(2027, 11, 5)));
        assertFalse(clock.isDst(_day(2027, 11, 8)));
    }

    function test_closeTimes() public view {
        uint256 summer = _day(2026, 7, 1);
        assertEq(clock.closeTime(summer), summer * 1 days + 20 hours);
        uint256 winter = _day(2026, 12, 1);
        assertEq(clock.closeTime(winter), winter * 1 days + 21 hours);
        assertEq(clock.openTime(winter), winter * 1 days + 14 hours + 30 minutes);
        assertTrue(clock.isCloseTimestamp(winter * 1 days + 21 hours));
        assertFalse(clock.isCloseTimestamp(winter * 1 days + 20 hours));
    }

    function test_weekendsAndHolidays() public {
        uint256 sat = _day(2026, 10, 10);
        assertFalse(clock.isTradingDay(sat));
        assertFalse(clock.isTradingDay(sat + 1));
        vm.expectRevert(abi.encodeWithSelector(MarketClock.NotTradingDay.selector, sat));
        clock.closeTime(sat);
        vm.expectRevert(abi.encodeWithSelector(MarketClock.NotTradingDay.selector, sat));
        clock.openTime(sat);
        assertFalse(clock.isCloseTimestamp(sat * 1 days + 20 hours));
        assertFalse(clock.isTradingSession(sat * 1 days + 15 hours));

        uint256 thanksgiving = _day(2026, 11, 26);
        uint256[] memory days_ = new uint256[](2);
        days_[0] = thanksgiving;
        days_[1] = thanksgiving + 1;
        uint8[] memory st = new uint8[](2);
        st[0] = 1;
        st[1] = 2;
        clock.setDayStatus(days_, st);
        assertFalse(clock.isTradingDay(thanksgiving));
        assertEq(clock.closeTime(thanksgiving + 1), (thanksgiving + 1) * 1 days + 18 hours); // 13:00 EST
        // close on or after Thanksgiving morning -> Friday early close
        assertEq(clock.closeOnOrAfter(thanksgiving * 1 days), (thanksgiving + 1) * 1 days + 18 hours);
    }

    function test_closeOnOrAfter() public view {
        uint256 fri = _day(2026, 10, 9);
        uint256 close = clock.closeTime(fri);
        assertEq(clock.closeOnOrAfter(close), close);
        assertEq(clock.closeOnOrAfter(close + 1), clock.closeTime(fri + 3)); // Monday
    }

    function test_closeOnOrAfter_noneFound() public {
        uint256 start = _day(2030, 1, 7);
        uint256[] memory days_ = new uint256[](15);
        uint8[] memory st = new uint8[](15);
        for (uint256 i; i < 15; ++i) {
            days_[i] = start + i;
            st[i] = 1;
        }
        clock.setDayStatus(days_, st);
        vm.expectRevert(MarketClock.NoCloseFound.selector);
        clock.closeOnOrAfter(start * 1 days);
    }

    function test_tradingSession() public view {
        uint256 day = _day(2026, 10, 8);
        assertTrue(clock.isTradingSession(clock.openTime(day)));
        assertFalse(clock.isTradingSession(clock.openTime(day) - 1));
        assertFalse(clock.isTradingSession(clock.closeTime(day)));
    }

    function test_setDayStatus_reverts() public {
        uint256[] memory days_ = new uint256[](1);
        uint8[] memory st = new uint8[](2);
        vm.expectRevert(MarketClock.LengthMismatch.selector);
        clock.setDayStatus(days_, st);
        st = new uint8[](1);
        st[0] = 3;
        vm.expectRevert(MarketClock.InvalidStatus.selector);
        clock.setDayStatus(days_, st);
        uint256[] memory big = new uint256[](65);
        uint8[] memory bigSt = new uint8[](65);
        vm.expectRevert(MarketClock.BatchTooLarge.selector);
        clock.setDayStatus(big, bigSt);
        vm.prank(address(0xBEEF));
        vm.expectRevert();
        clock.setDayStatus(days_, new uint8[](1));
    }
}
