// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IMarketClock {
    function isTradingDay(uint256 day) external view returns (bool);
    function closeTime(uint256 day) external view returns (uint256);
    function isCloseTimestamp(uint256 ts) external view returns (bool);
    function closeOnOrAfter(uint256 ts) external view returns (uint256);
    function isTradingSession(uint256 ts) external view returns (bool);
}
