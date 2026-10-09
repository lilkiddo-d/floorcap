// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Swappable price source. All prices are USD with 18 decimals per 1 whole token.
interface IOracleAdapter {
    /// @notice Latest validated price (staleness, deviation and sequencer checks applied).
    function latestPrice(address token) external view returns (uint256 price, uint256 updatedAt);

    /// @notice Validated price that was current at `timestamp`.
    /// @param primaryHint Round id of the primary feed that was current at `timestamp`.
    /// @param secondaryHint Round id of the secondary feed (ignored when no secondary feed is configured).
    function priceAt(address token, uint256 timestamp, uint80 primaryHint, uint80 secondaryHint)
        external
        view
        returns (uint256 price);

    function hasFeed(address token) external view returns (bool);
}
