// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Source of the upside leg: a European, cash-settled-in-kind call on a series basket.
/// @dev Units are basket units with 18 decimals. One basket unit = `quantities[i]` wei of each token i.
interface IOptionsAdapter {
    /// @notice Maximum basket units that can be bought for `seriesId` right now.
    function capacity(uint256 seriesId) external view returns (uint256 units);

    /// @notice Buy `units` calls struck at `strike` (USD, 18 dec per basket unit). Premium is pulled from caller.
    function openCall(uint256 seriesId, uint256 units, uint256 strike, address premiumToken, uint256 premium)
        external;

    /// @notice Exercise `units` of open calls at basket `level`; in-kind payout is sent to `to`.
    /// @return payoutUnits Basket units paid out (units * (level - strike) / level, or 0 if OTM).
    function exercise(uint256 seriesId, uint256 units, uint256 level, address to)
        external
        returns (uint256 payoutUnits);

    /// @notice Final close after the last exercise; releases remaining collateral to underwriters.
    function closeSeries(uint256 seriesId) external;

    /// @notice Series cancelled before lock; collateral fully withdrawable.
    function cancelSeries(uint256 seriesId) external;

    /// @notice Calls still open (not yet exercised) for `seriesId`.
    function openUnits(uint256 seriesId) external view returns (uint256);
}
