// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Segregated, per-series yield position for the bond leg of a note.
interface IYieldAdapter {
    /// @notice Underlying asset (the series stablecoin).
    function asset() external view returns (address);

    /// @notice Pull `assets` from the caller and invest them on behalf of `seriesId`.
    function deposit(uint256 seriesId, uint256 assets) external;

    /// @notice Redeem `numerator / denominator` of the series position and send the assets to `to`.
    function withdrawShare(uint256 seriesId, uint256 numerator, uint256 denominator, address to)
        external
        returns (uint256 assetsOut);

    /// @notice Current redeemable value of the series position, in `asset()` units.
    function totalAssets(uint256 seriesId) external view returns (uint256);

    /// @notice Informational reference APY in bps (used by curators/UI; never trusted for payouts).
    function referenceApyBps() external view returns (uint256);
}
