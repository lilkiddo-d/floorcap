// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ISeriesFactory {
    enum State {
        None,
        Subscription,
        Locked,
        Settled,
        Cancelled
    }

    /// @notice Curator input for a new series.
    struct SeriesParams {
        string name;
        address stable;
        address yieldAdapter;
        address optionsAdapter;
        address[] tokens;
        uint256[] quantities; // token wei per 1e18 basket units
        uint64 subscriptionStart;
        uint64 subscriptionEnd; // must be a US regular-session close
        uint8 tenorMonths; // 3, 6 or 12
        uint16 protectionBps; // 10_000 or 9_500
        uint16 assumedYieldBps; // annualised, conservative (haircut) yield of the bond leg
        uint16 premiumBps; // ATM call price as % of notional, from the underwriters' quote
        uint16 structuringFeeBps;
        uint16 exitFeeBps;
        uint256 cap; // max accepted principal
        uint256 minSize; // min accepted principal, else cancelled
    }

    struct Series {
        address stable;
        address yieldAdapter;
        address optionsAdapter;
        uint64 createdAt;
        uint64 subscriptionStart;
        uint64 subscriptionEnd;
        uint64 maturity;
        uint8 tenorMonths;
        State state;
        uint16 protectionBps;
        uint16 assumedYieldBps;
        uint16 premiumBps;
        uint16 structuringFeeBps;
        uint16 exitFeeBps;
        uint256 bondWad; // fraction of principal invested in the bond leg
        uint256 participationWad; // upside participation, 1e18 = 100%
        uint256 cap;
        uint256 minSize;
        uint256 priorityDeposits;
        uint256 regularDeposits;
        uint256 accepted; // principal accepted at lock (= notes issued)
        uint256 liveNotes; // accepted minus early exits
        uint256 priorityFillWad;
        uint256 regularFillWad;
        uint256 strike; // basket level at subscription end, USD 1e18 per basket unit
        uint256 units; // basket units of calls bought
    }

    function getSeries(uint256 id) external view returns (Series memory);
    function getBasket(uint256 id) external view returns (address[] memory tokens, uint256[] memory quantities);
    function basketTokens(uint256 id) external view returns (address[] memory tokens);
    function seriesState(uint256 id) external view returns (State);
    function basketLevelAt(uint256 id, uint256 ts, uint80[] calldata primaryHints, uint80[] calldata secondaryHints)
        external
        view
        returns (uint256);
    function basketLevelLatest(uint256 id) external view returns (uint256);
    function reduceLive(uint256 id, uint256 amount) external;
    function markSettled(uint256 id) external;
    function oracle() external view returns (address);
    function clock() external view returns (address);
    function note() external view returns (address);
    function feeCollector() external view returns (address);
    function compliance() external view returns (address);
}
