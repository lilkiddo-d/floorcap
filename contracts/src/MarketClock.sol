// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IMarketClock} from "./interfaces/IMarketClock.sol";

/// @title MarketClock
/// @notice US equity market calendar: regular-session open/close timestamps (America/New_York, US DST rules in force
///         since 2007), weekends, and a Timelock-maintained NYSE holiday / early-close table.
/// @dev A "day" is the UTC day number (`timestamp / 1 days`). Every regular-session moment of an ET trading date
///      falls on the same UTC date, so the UTC day number identifies the ET trading date unambiguously.
contract MarketClock is AccessControl, IMarketClock {
    bytes32 public constant CALENDAR_ROLE = keccak256("CALENDAR_ROLE");

    uint8 public constant STATUS_OPEN = 0;
    uint8 public constant STATUS_CLOSED = 1;
    uint8 public constant STATUS_EARLY_CLOSE = 2;

    uint256 public constant MAX_BATCH = 64;
    uint256 public constant MAX_SCAN_DAYS = 15;

    /// @notice Override status per UTC day number (holiday / early close).
    mapping(uint256 day => uint8 status) public dayStatus;

    event DayStatusSet(uint256 indexed day, uint8 status);

    error InvalidStatus();
    error BatchTooLarge();
    error LengthMismatch();
    error NotTradingDay(uint256 day);
    error NoCloseFound();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(CALENDAR_ROLE, admin);
    }

    function setDayStatus(uint256[] calldata days_, uint8[] calldata statuses) external onlyRole(CALENDAR_ROLE) {
        if (days_.length != statuses.length) revert LengthMismatch();
        if (days_.length > MAX_BATCH) revert BatchTooLarge();
        for (uint256 i; i < days_.length; ++i) {
            if (statuses[i] > STATUS_EARLY_CLOSE) revert InvalidStatus();
            dayStatus[days_[i]] = statuses[i];
            emit DayStatusSet(days_[i], statuses[i]);
        }
    }

    // ---------------------------------------------------------------- calendar math

    /// @notice 0 = Sunday ... 6 = Saturday.
    function weekday(uint256 day) public pure returns (uint256) {
        return (day + 4) % 7; // 1970-01-01 was a Thursday
    }

    /// @notice Civil (proleptic Gregorian) date from a day number. Howard Hinnant, "chrono-compatible algorithms".
    // integer floor division is the algorithm; fuzzed round-trip
    // slither-disable-start divide-before-multiply
    function civilFromDays(uint256 day) public pure returns (uint256 y, uint256 m, uint256 d) {
        uint256 z = day + 719468;
        uint256 era = z / 146097;
        uint256 doe = z - era * 146097;
        uint256 yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
        y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        d = doy - (153 * mp + 2) / 5 + 1;
        m = mp < 10 ? mp + 3 : mp - 9;
        if (m <= 2) y += 1;
    }

    /// @notice Day number from a civil date (inverse of civilFromDays).
    function daysFromCivil(uint256 y, uint256 m, uint256 d) public pure returns (uint256) {
        if (m <= 2) y -= 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 mp = m > 2 ? m - 3 : m + 9;
        uint256 doy = (153 * mp + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146097 + doe - 719468;
    }
    // slither-disable-end divide-before-multiply

    /// @notice True when US Eastern daylight time is in effect during the trading hours of `day`.
    function isDst(uint256 day) public pure returns (bool) {
        (, uint256 m, uint256 d) = civilFromDays(day);
        if (m < 3 || m > 11) return false;
        if (m > 3 && m < 11) return true;
        uint256 firstWeekday = weekday(day - (d - 1));
        uint256 firstSunday = 1 + (7 - firstWeekday) % 7;
        if (m == 3) return d >= firstSunday + 7; // from the second Sunday of March
        return d < firstSunday; // until the first Sunday of November
    }

    function isTradingDay(uint256 day) public view returns (bool) {
        uint256 w = weekday(day);
        return w != 0 && w != 6 && dayStatus[day] != STATUS_CLOSED;
    }

    /// @notice Regular-session close (16:00 ET, or 13:00 ET on early-close days) as a unix timestamp.
    function closeTime(uint256 day) public view returns (uint256) {
        if (!isTradingDay(day)) revert NotTradingDay(day);
        uint256 hourEt = dayStatus[day] == STATUS_EARLY_CLOSE ? 13 : 16;
        uint256 offset = isDst(day) ? 4 : 5;
        return day * 1 days + (hourEt + offset) * 1 hours;
    }

    /// @notice Regular-session open (09:30 ET).
    function openTime(uint256 day) public view returns (uint256) {
        if (!isTradingDay(day)) revert NotTradingDay(day);
        uint256 offset = isDst(day) ? 4 : 5;
        return day * 1 days + (9 + offset) * 1 hours + 30 minutes;
    }

    function isCloseTimestamp(uint256 ts) external view returns (bool) {
        uint256 day = ts / 1 days;
        return isTradingDay(day) && closeTime(day) == ts;
    }

    /// @notice First regular-session close at or after `ts` (bounded scan).
    function closeOnOrAfter(uint256 ts) external view returns (uint256) {
        uint256 day = ts / 1 days;
        for (uint256 i; i < MAX_SCAN_DAYS; ++i) {
            if (isTradingDay(day + i)) {
                uint256 c = closeTime(day + i);
                if (c >= ts) return c;
            }
        }
        revert NoCloseFound();
    }

    /// @notice True during the regular session (09:30-16:00 ET) of a trading day.
    function isTradingSession(uint256 ts) external view returns (bool) {
        uint256 day = ts / 1 days;
        if (!isTradingDay(day)) return false;
        return ts >= openTime(day) && ts < closeTime(day);
    }
}
