// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IOracleAdapter} from "./interfaces/IOracleAdapter.sol";

/// @title OracleAdapter (Chainlink)
/// @notice Chainlink-backed IOracleAdapter with staleness, primary/secondary deviation and optional L2-sequencer
///         checks, plus manipulation-resistant historical lookups used for "price at the US close".
/// @dev Historical lookup: callers pass the round id that was current at the target timestamp. The adapter proves it
///      by checking round.updatedAt <= ts < nextRound.updatedAt, so a caller cannot cherry-pick a favourable round.
contract OracleAdapter is AccessControl, IOracleAdapter {
    struct FeedConfig {
        IAggregatorV3 primary;
        IAggregatorV3 secondary; // optional independent read (e.g. Chainlink SVR proxy); address(0) = none
        uint8 primaryDecimals;
        uint8 secondaryDecimals;
        uint32 maxStaleness; // seconds
        uint16 maxDeviationBps; // primary vs secondary
    }

    bytes32 public constant FEED_ADMIN_ROLE = keccak256("FEED_ADMIN_ROLE");
    uint256 public constant BPS = 10_000;

    mapping(address token => FeedConfig) internal _feeds;

    IAggregatorV3 public sequencerFeed; // Chainlink L2 sequencer uptime feed; address(0) = not published for chain
    uint256 public sequencerGracePeriod;

    event FeedSet(
        address indexed token, address primary, address secondary, uint32 maxStaleness, uint16 maxDeviationBps
    );
    event SequencerFeedSet(address feed, uint256 gracePeriod);

    error NoFeed(address token);
    error InvalidPrice(address feed);
    error StalePrice(address feed, uint256 updatedAt);
    error PriceDeviation(address token, uint256 primary, uint256 secondary);
    error SequencerDown();
    error SequencerGracePeriod();
    error BadHint(address feed, uint80 roundId);
    error FutureTimestamp();
    error InvalidConfig();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FEED_ADMIN_ROLE, admin);
    }

    // ---------------------------------------------------------------- admin

    function setFeed(address token, address primary, address secondary, uint32 maxStaleness, uint16 maxDeviationBps)
        external
        onlyRole(FEED_ADMIN_ROLE)
    {
        if (token == address(0) || primary == address(0) || maxStaleness == 0 || maxDeviationBps > BPS) {
            revert InvalidConfig();
        }
        FeedConfig storage f = _feeds[token];
        f.primary = IAggregatorV3(primary);
        f.primaryDecimals = IAggregatorV3(primary).decimals();
        f.secondary = IAggregatorV3(secondary);
        f.secondaryDecimals = secondary == address(0) ? 0 : IAggregatorV3(secondary).decimals();
        f.maxStaleness = maxStaleness;
        f.maxDeviationBps = maxDeviationBps;
        emit FeedSet(token, primary, secondary, maxStaleness, maxDeviationBps);
    }

    function setSequencerFeed(address feed, uint256 gracePeriod) external onlyRole(FEED_ADMIN_ROLE) {
        sequencerFeed = IAggregatorV3(feed);
        sequencerGracePeriod = gracePeriod;
        emit SequencerFeedSet(feed, gracePeriod);
    }

    // ---------------------------------------------------------------- views

    function feedOf(address token) external view returns (FeedConfig memory) {
        return _feeds[token];
    }

    function hasFeed(address token) external view returns (bool) {
        return address(_feeds[token].primary) != address(0);
    }

    function latestPrice(address token) external view returns (uint256 price, uint256 updatedAt) {
        FeedConfig memory f = _config(token);
        _checkSequencer();
        // roundId/startedAt/answeredInRound not needed; updatedAt validated
        // slither-disable-next-line unused-return
        (, int256 answer,, uint256 upd,) = f.primary.latestRoundData();
        price = _validate(address(f.primary), answer, upd, block.timestamp, f.maxStaleness, f.primaryDecimals);
        updatedAt = upd;
        if (address(f.secondary) != address(0)) {
            // see above
            // slither-disable-next-line unused-return
            (, int256 a2,, uint256 u2,) = f.secondary.latestRoundData();
            uint256 p2 = _validate(address(f.secondary), a2, u2, block.timestamp, f.maxStaleness, f.secondaryDecimals);
            _checkDeviation(token, price, p2, f.maxDeviationBps);
        }
    }

    function priceAt(address token, uint256 timestamp, uint80 primaryHint, uint80 secondaryHint)
        external
        view
        returns (uint256 price)
    {
        if (timestamp > block.timestamp) revert FutureTimestamp();
        FeedConfig memory f = _config(token);
        _checkSequencer();
        price = _roundAt(f.primary, primaryHint, timestamp, f.maxStaleness, f.primaryDecimals);
        if (address(f.secondary) != address(0)) {
            uint256 p2 = _roundAt(f.secondary, secondaryHint, timestamp, f.maxStaleness, f.secondaryDecimals);
            _checkDeviation(token, price, p2, f.maxDeviationBps);
        }
    }

    // ---------------------------------------------------------------- internals

    function _config(address token) internal view returns (FeedConfig memory f) {
        f = _feeds[token];
        if (address(f.primary) == address(0)) revert NoFeed(token);
    }

    function _checkSequencer() internal view {
        IAggregatorV3 s = sequencerFeed;
        if (address(s) == address(0)) return;
        // uptime feed: only status + startedAt are meaningful
        // slither-disable-next-line unused-return
        (, int256 answer, uint256 startedAt,,) = s.latestRoundData();
        if (answer != 0) revert SequencerDown();
        if (block.timestamp - startedAt <= sequencerGracePeriod) revert SequencerGracePeriod();
    }

    function _validate(address feed, int256 answer, uint256 updatedAt, uint256 refTime, uint256 maxStale, uint8 dec)
        internal
        pure
        returns (uint256)
    {
        if (answer <= 0 || updatedAt == 0 || updatedAt > refTime) revert InvalidPrice(feed);
        if (refTime - updatedAt > maxStale) revert StalePrice(feed, updatedAt);
        return _scale(uint256(answer), dec);
    }

    function _scale(uint256 v, uint8 dec) internal pure returns (uint256) {
        if (dec == 18) return v;
        if (dec < 18) return v * 10 ** (18 - dec);
        return v / 10 ** (dec - 18);
    }

    function _checkDeviation(address token, uint256 p1, uint256 p2, uint256 maxBps) internal pure {
        uint256 diff = p1 > p2 ? p1 - p2 : p2 - p1;
        if (diff * BPS > p1 * maxBps) revert PriceDeviation(token, p1, p2);
    }

    /// @dev Proves `hint` was the round in effect at `ts` and returns its validated, scaled answer.
    function _roundAt(IAggregatorV3 feed, uint80 hint, uint256 ts, uint256 maxStale, uint8 dec)
        internal
        view
        returns (uint256)
    {
        (bool ok, int256 answer, uint256 updatedAt) = _tryRound(feed, hint);
        if (!ok || updatedAt == 0 || updatedAt > ts) revert BadHint(address(feed), hint);
        uint256 price = _validate(address(feed), answer, updatedAt, ts, maxStale, dec);
        _checkNextRound(feed, hint, ts);
        return price;
    }

    /// @dev The round after `hint` (same phase, or the first round of the next phase) must postdate `ts`.
    function _checkNextRound(IAggregatorV3 feed, uint80 hint, uint256 ts) internal view {
        (bool okNext,, uint256 nextUpdated) = _tryRound(feed, hint + 1);
        if (okNext && nextUpdated != 0) {
            if (nextUpdated <= ts) revert BadHint(address(feed), hint);
            return;
        }
        // only the latest round id is needed here
        // slither-disable-next-line unused-return
        (uint80 latestId,,,,) = feed.latestRoundData();
        if (latestId == hint) return;
        uint80 nextPhaseFirst = uint80(((uint256(hint) >> 64) + 1) << 64) | 1;
        (bool okPhase,, uint256 phaseUpdated) = _tryRound(feed, nextPhaseFirst);
        if (!okPhase || phaseUpdated == 0 || phaseUpdated <= ts) revert BadHint(address(feed), hint);
    }

    function _tryRound(IAggregatorV3 feed, uint80 id) internal view returns (bool ok, int256 answer, uint256 upd) {
        // answer + updatedAt are the only fields used
        // slither-disable-next-line unused-return
        try feed.getRoundData(id) returns (uint80, int256 a, uint256, uint256 u, uint80) {
            return (true, a, u);
        } catch {
            return (false, 0, 0);
        }
    }
}
