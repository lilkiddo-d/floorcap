// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IFeeCollector {
    /// @notice Account a fee already transferred to the collector.
    function recordFee(address token, uint256 amount, bool structuring) external;
    /// @notice Pay up to `amount` of `token` from the shortfall reserve to the caller.
    function coverShortfall(address token, uint256 amount) external returns (uint256 paid);
}
