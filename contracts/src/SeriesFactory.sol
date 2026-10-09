// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ISeriesFactory} from "./interfaces/ISeriesFactory.sol";
import {IOracleAdapter} from "./interfaces/IOracleAdapter.sol";
import {IYieldAdapter} from "./interfaces/IYieldAdapter.sol";
import {IOptionsAdapter} from "./interfaces/IOptionsAdapter.sol";
import {IMarketClock} from "./interfaces/IMarketClock.sol";
import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";
import {IProjectTokenHooks} from "./interfaces/IProjectTokenHooks.sol";
import {IFeeCollector} from "./interfaces/IFeeCollector.sol";
import {Note} from "./Note.sol";

/// @title SeriesFactory
/// @notice Creates note series and runs their primary market: subscription window, oversubscription allocation
///         (project-token stakers first), and the lock that splits principal into bond leg + call premium.
/// @dev Classic "bond + call": per 1 unit of principal, `bondWad` goes to the yield adapter so that it grows to the
///      protected floor at the assumed yield; the remainder (minus structuring fee) buys ATM calls on the basket.
///      participation = (1 - bondWad - fee) / premium.
contract SeriesFactory is AccessControl, Pausable, ReentrancyGuard, ISeriesFactory {
    using SafeERC20 for IERC20;

    bytes32 public constant CURATOR_ROLE = keccak256("CURATOR_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    bytes32 public constant ACTION_SUBSCRIBE = keccak256("SUBSCRIBE");

    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 public constant MAX_BASKET = 10;
    uint256 public constant YEAR = 365 days;

    // ---------------------------------------------------------------- protocol wiring (Timelock-controlled)
    address public oracle;
    address public clock;
    address public note;
    address public feeCollector;
    address public compliance;
    address public hooks;

    // ---------------------------------------------------------------- risk limits (Timelock-controlled)
    uint256 public maxAssumedYieldBps = 1_000;
    uint256 public maxStructuringFeeBps = 200;
    uint256 public maxExitFeeBps = 500;
    uint256 public maxParticipationWad = 3e18;
    uint256 public lockWindow = 3 days;

    mapping(address => bool) public allowedStable;
    mapping(address => bool) public allowedYieldAdapter;
    mapping(address => bool) public allowedOptionsAdapter;

    // ---------------------------------------------------------------- series
    uint256 public seriesCount;
    mapping(uint256 => Series) internal _series;
    mapping(uint256 => address[]) internal _tokens;
    mapping(uint256 => uint256[]) internal _quantities;
    mapping(uint256 => string) public seriesName;

    struct Deposit {
        uint256 priority;
        uint256 regular;
    }

    mapping(uint256 => mapping(address => Deposit)) public deposits;

    // ---------------------------------------------------------------- events
    event SeriesCreated(uint256 indexed id, string name, address indexed stable, uint64 maturity, uint256 participationWad);
    event Subscribed(uint256 indexed id, address indexed account, uint256 amount, bool priority);
    event SubscriptionWithdrawn(uint256 indexed id, address indexed account, uint256 amount);
    event SeriesLocked(
        uint256 indexed id, uint256 accepted, uint256 strike, uint256 units, uint256 bond, uint256 premium, uint256 fee
    );
    event SeriesCancelled(uint256 indexed id);
    event SeriesSettled(uint256 indexed id);
    event AllocationClaimed(uint256 indexed id, address indexed account, uint256 notes, uint256 refund);
    event LiveReduced(uint256 indexed id, uint256 amount, uint256 liveNotes);
    event WiringSet(address oracle, address clock, address note, address feeCollector, address compliance, address hooks);
    event LimitsSet(uint256 maxYieldBps, uint256 maxFeeBps, uint256 maxExitFeeBps, uint256 maxPartWad, uint256 lockWindow);
    event AllowlistSet(uint8 indexed kind, address indexed target, bool allowed);

    // ---------------------------------------------------------------- errors
    error InvalidParams(string reason);
    error WrongState(State expected, State actual);
    error OutsideWindow();
    error NotAllowed();
    error ZeroAmount();
    error InsufficientDeposit();
    error ZeroAddress();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ================================================================= admin

    function setWiring(
        address oracle_,
        address clock_,
        address note_,
        address feeCollector_,
        address compliance_,
        address hooks_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (oracle_ == address(0) || clock_ == address(0) || note_ == address(0) || feeCollector_ == address(0)) {
            revert ZeroAddress();
        }
        oracle = oracle_;
        clock = clock_;
        note = note_;
        feeCollector = feeCollector_;
        compliance = compliance_;
        hooks = hooks_;
        emit WiringSet(oracle_, clock_, note_, feeCollector_, compliance_, hooks_);
    }

    function setLimits(
        uint256 maxYieldBps_,
        uint256 maxFeeBps_,
        uint256 maxExitFeeBps_,
        uint256 maxPartWad_,
        uint256 lockWindow_
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (maxYieldBps_ > 2_000 || maxFeeBps_ > 500 || maxExitFeeBps_ > 1_000 || maxPartWad_ > 10e18) {
            revert InvalidParams("limits");
        }
        if (lockWindow_ < 1 days || lockWindow_ > 14 days) revert InvalidParams("lockWindow");
        maxAssumedYieldBps = maxYieldBps_;
        maxStructuringFeeBps = maxFeeBps_;
        maxExitFeeBps = maxExitFeeBps_;
        maxParticipationWad = maxPartWad_;
        lockWindow = lockWindow_;
        emit LimitsSet(maxYieldBps_, maxFeeBps_, maxExitFeeBps_, maxPartWad_, lockWindow_);
    }

    /// @param kind 0 = stablecoin, 1 = yield adapter, 2 = options adapter
    function setAllowed(uint8 kind, address target, bool on) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (kind == 0) allowedStable[target] = on;
        else if (kind == 1) allowedYieldAdapter[target] = on;
        else if (kind == 2) allowedOptionsAdapter[target] = on;
        else revert InvalidParams("kind");
        emit AllowlistSet(kind, target, on);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    // ================================================================= curator

    function createSeries(SeriesParams calldata p) external onlyRole(CURATOR_ROLE) whenNotPaused returns (uint256 id) {
        _validateParams(p);
        uint64 maturity = uint64(IMarketClock(clock).closeOnOrAfter(uint256(p.subscriptionEnd) + _tenorDays(p.tenorMonths) * 1 days));
        (uint256 bondWad, uint256 participationWad) = quoteTerms(
            p.protectionBps, p.assumedYieldBps, p.premiumBps, p.structuringFeeBps, maturity - p.subscriptionEnd
        );
        if (participationWad == 0 || participationWad > maxParticipationWad) revert InvalidParams("participation");

        id = ++seriesCount;
        Series storage s = _series[id];
        s.stable = p.stable;
        s.yieldAdapter = p.yieldAdapter;
        s.optionsAdapter = p.optionsAdapter;
        s.createdAt = uint64(block.timestamp);
        s.subscriptionStart = p.subscriptionStart;
        s.subscriptionEnd = p.subscriptionEnd;
        s.maturity = maturity;
        s.tenorMonths = p.tenorMonths;
        s.state = State.Subscription;
        s.protectionBps = p.protectionBps;
        s.assumedYieldBps = p.assumedYieldBps;
        s.premiumBps = p.premiumBps;
        s.structuringFeeBps = p.structuringFeeBps;
        s.exitFeeBps = p.exitFeeBps;
        s.bondWad = bondWad;
        s.participationWad = participationWad;
        s.cap = p.cap;
        s.minSize = p.minSize;
        _tokens[id] = p.tokens;
        _quantities[id] = p.quantities;
        seriesName[id] = p.name;
        emit SeriesCreated(id, p.name, p.stable, maturity, participationWad);
    }

    /// @notice Curator or guardian may cancel a series that has not locked yet (full refunds).
    function cancelSeries(uint256 id) external nonReentrant {
        if (!hasRole(CURATOR_ROLE, msg.sender) && !hasRole(GUARDIAN_ROLE, msg.sender)) revert NotAllowed();
        _requireState(id, State.Subscription);
        _cancel(id);
    }

    // ================================================================= subscribers

    function subscribe(uint256 id, uint256 amount) external nonReentrant whenNotPaused {
        Series storage s = _series[id];
        _requireState(id, State.Subscription);
        if (block.timestamp < s.subscriptionStart || block.timestamp >= s.subscriptionEnd) revert OutsideWindow();
        if (amount == 0) revert ZeroAmount();
        if (compliance != address(0) && !IComplianceRegistry(compliance).isAllowed(msg.sender, ACTION_SUBSCRIBE)) {
            revert NotAllowed();
        }
        bool priority = hooks != address(0) && IProjectTokenHooks(hooks).isPriority(msg.sender, s.createdAt);
        Deposit storage d = deposits[id][msg.sender];
        if (priority) {
            d.priority += amount;
            s.priorityDeposits += amount;
        } else {
            d.regular += amount;
            s.regularDeposits += amount;
        }
        emit Subscribed(id, msg.sender, amount, priority);
        IERC20(s.stable).safeTransferFrom(msg.sender, address(this), amount);
    }

    function withdrawSubscription(uint256 id, uint256 amount) external nonReentrant {
        Series storage s = _series[id];
        _requireState(id, State.Subscription);
        if (block.timestamp >= s.subscriptionEnd) revert OutsideWindow();
        Deposit storage d = deposits[id][msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (amount > d.priority + d.regular) revert InsufficientDeposit();
        uint256 fromRegular = amount < d.regular ? amount : d.regular;
        uint256 fromPriority = amount - fromRegular;
        d.regular -= fromRegular;
        d.priority -= fromPriority;
        s.regularDeposits -= fromRegular;
        s.priorityDeposits -= fromPriority;
        emit SubscriptionWithdrawn(id, msg.sender, amount);
        IERC20(s.stable).safeTransfer(msg.sender, amount);
    }

    /// @notice Permissionless. Fixes the strike at the subscription-end close price (proven via round hints),
    ///         allocates, and deploys capital into the bond and option legs.
    function lock(uint256 id, uint80[] calldata primaryHints, uint80[] calldata secondaryHints)
        external
        nonReentrant
        whenNotPaused
    {
        Series storage s = _series[id];
        _requireState(id, State.Subscription);
        if (block.timestamp < s.subscriptionEnd || block.timestamp > s.subscriptionEnd + lockWindow) {
            revert OutsideWindow();
        }
        uint256 strike = basketLevelAt(id, s.subscriptionEnd, primaryHints, secondaryHints);
        uint256 scale = _scale(s.stable);

        uint256 accepted = _acceptable(id, s, strike, scale);
        uint256 units = accepted == 0 ? 0 : Math.mulDiv(accepted * scale, s.participationWad, strike);
        if (accepted < s.minSize || units == 0) {
            _cancel(id);
            return;
        }

        _setFills(s, accepted);
        s.state = State.Locked;
        s.accepted = accepted;
        s.liveNotes = accepted;
        s.strike = strike;
        s.units = units;
        _deployCapital(id, s, accepted, strike, units);
    }

    /// @dev Priority (staker) deposits fill first; the remainder fills regular deposits pro-rata.
    function _setFills(Series storage s, uint256 accepted) internal {
        uint256 p = s.priorityDeposits;
        if (accepted >= p) {
            s.priorityFillWad = WAD;
            s.regularFillWad = s.regularDeposits == 0 ? 0 : Math.mulDiv(accepted - p, WAD, s.regularDeposits);
        } else {
            s.priorityFillWad = Math.mulDiv(accepted, WAD, p);
            s.regularFillWad = 0;
        }
    }

    function _deployCapital(uint256 id, Series storage s, uint256 accepted, uint256 strike, uint256 units) internal {
        uint256 bond = Math.mulDiv(accepted, s.bondWad, WAD, Math.Rounding.Ceil);
        uint256 fee = accepted * s.structuringFeeBps / BPS;
        uint256 premium = accepted - bond - fee;
        emit SeriesLocked(id, accepted, strike, units, bond, premium, fee);

        IERC20 stable = IERC20(s.stable);
        stable.forceApprove(s.yieldAdapter, bond);
        IYieldAdapter(s.yieldAdapter).deposit(id, bond);
        if (fee > 0) {
            stable.safeTransfer(feeCollector, fee);
            IFeeCollector(feeCollector).recordFee(s.stable, fee, true);
        }
        stable.forceApprove(s.optionsAdapter, premium);
        IOptionsAdapter(s.optionsAdapter).openCall(id, units, strike, s.stable, premium);
    }

    /// @notice Anyone can cancel a series whose lock window lapsed (e.g. oracle outage) so funds are refundable.
    function cancelStale(uint256 id) external nonReentrant {
        _requireState(id, State.Subscription);
        if (block.timestamp <= _series[id].subscriptionEnd + lockWindow) revert OutsideWindow();
        _cancel(id);
    }

    /// @notice Mint allocated notes and refund the unallocated remainder (or everything if cancelled). Permissionless
    ///         push to `account`; never pausable so funds can always be released.
    function claimAllocation(uint256 id, address account) external nonReentrant {
        Series storage s = _series[id];
        State st = s.state;
        if (st != State.Locked && st != State.Settled && st != State.Cancelled) revert WrongState(State.Locked, st);
        Deposit memory d = deposits[id][account];
        uint256 total = d.priority + d.regular;
        if (total == 0) revert ZeroAmount();
        delete deposits[id][account];

        uint256 notes = 0;
        if (st != State.Cancelled) {
            notes = Math.mulDiv(d.priority, s.priorityFillWad, WAD) + Math.mulDiv(d.regular, s.regularFillWad, WAD);
        }
        uint256 refund = total - notes;
        emit AllocationClaimed(id, account, notes, refund);
        if (notes > 0) Note(note).mint(account, id, notes);
        if (refund > 0) IERC20(s.stable).safeTransfer(account, refund);
    }

    // ================================================================= settlement hooks

    function reduceLive(uint256 id, uint256 amount) external onlyRole(SETTLEMENT_ROLE) {
        _requireState(id, State.Locked);
        Series storage s = _series[id];
        s.liveNotes -= amount;
        emit LiveReduced(id, amount, s.liveNotes);
    }

    function markSettled(uint256 id) external onlyRole(SETTLEMENT_ROLE) {
        _requireState(id, State.Locked);
        _series[id].state = State.Settled;
        emit SeriesSettled(id);
    }

    // ================================================================= views

    function getSeries(uint256 id) external view returns (Series memory) {
        return _series[id];
    }

    function getBasket(uint256 id) external view returns (address[] memory, uint256[] memory) {
        return (_tokens[id], _quantities[id]);
    }

    function basketTokens(uint256 id) external view returns (address[] memory) {
        return _tokens[id];
    }

    function seriesState(uint256 id) external view returns (State) {
        return _series[id].state;
    }

    /// @notice Basket level (USD 1e18 per 1e18 basket units) as of `ts`, proven by Chainlink round hints.
    function basketLevelAt(uint256 id, uint256 ts, uint80[] calldata primaryHints, uint80[] calldata secondaryHints)
        public
        view
        returns (uint256 level)
    {
        address[] storage t = _tokens[id];
        uint256[] storage q = _quantities[id];
        uint256 n = t.length;
        if (primaryHints.length != n || secondaryHints.length != n) revert InvalidParams("hints");
        for (uint256 i; i < n; ++i) {
            uint256 px = IOracleAdapter(oracle).priceAt(t[i], ts, primaryHints[i], secondaryHints[i]);
            level += Math.mulDiv(q[i], px, WAD);
        }
    }

    function basketLevelLatest(uint256 id) external view returns (uint256 level) {
        address[] storage t = _tokens[id];
        uint256[] storage q = _quantities[id];
        for (uint256 i; i < t.length; ++i) {
            // updatedAt already validated by the adapter
            // slither-disable-next-line unused-return
            (uint256 px,) = IOracleAdapter(oracle).latestPrice(t[i]);
            level += Math.mulDiv(q[i], px, WAD);
        }
    }

    /// @notice Terms implied by the inputs: bond fraction and participation (both 1e18 = 100%).
    function quoteTerms(
        uint256 protectionBps,
        uint256 assumedYieldBps,
        uint256 premiumBps,
        uint256 structuringFeeBps,
        uint256 duration
    ) public pure returns (uint256 bondWad, uint256 participationWad) {
        uint256 growthWad = WAD + Math.mulDiv(assumedYieldBps * 1e14, duration, YEAR);
        bondWad = Math.mulDiv(protectionBps * 1e14, WAD, growthWad, Math.Rounding.Ceil);
        uint256 feeWad = structuringFeeBps * 1e14;
        if (bondWad + feeWad >= WAD || premiumBps == 0) return (bondWad, 0);
        participationWad = Math.mulDiv(WAD - bondWad - feeWad, WAD, premiumBps * 1e14);
    }

    // ================================================================= internals

    /// @dev Accepted principal = min(deposits, cap, what underwriter capacity can cover at this participation).
    function _acceptable(uint256 id, Series storage s, uint256 strike, uint256 scale)
        internal
        view
        returns (uint256 accepted)
    {
        accepted = s.priorityDeposits + s.regularDeposits;
        if (accepted > s.cap) accepted = s.cap;
        uint256 capacityUnits = IOptionsAdapter(s.optionsAdapter).capacity(id);
        uint256 maxByCapacity = Math.mulDiv(Math.mulDiv(capacityUnits, strike, WAD), WAD, s.participationWad) / scale;
        if (accepted > maxByCapacity) accepted = maxByCapacity;
    }

    function _validateParams(SeriesParams calldata p) internal view {
        if (!allowedStable[p.stable]) revert InvalidParams("stable");
        if (!allowedYieldAdapter[p.yieldAdapter]) revert InvalidParams("yieldAdapter");
        if (!allowedOptionsAdapter[p.optionsAdapter]) revert InvalidParams("optionsAdapter");
        if (IYieldAdapter(p.yieldAdapter).asset() != p.stable) revert InvalidParams("asset");
        uint256 n = p.tokens.length;
        if (n == 0 || n > MAX_BASKET || p.quantities.length != n) revert InvalidParams("basket");
        for (uint256 i; i < n; ++i) {
            if (p.quantities[i] == 0 || !IOracleAdapter(oracle).hasFeed(p.tokens[i])) revert InvalidParams("token");
            for (uint256 j; j < i; ++j) {
                if (p.tokens[j] == p.tokens[i]) revert InvalidParams("duplicate");
            }
        }
        if (p.protectionBps != 10_000 && p.protectionBps != 9_500) revert InvalidParams("protection");
        if (p.tenorMonths != 3 && p.tenorMonths != 6 && p.tenorMonths != 12) revert InvalidParams("tenor");
        if (p.subscriptionEnd <= p.subscriptionStart || p.subscriptionEnd <= block.timestamp) {
            revert InvalidParams("window");
        }
        if (!IMarketClock(clock).isCloseTimestamp(p.subscriptionEnd)) revert InvalidParams("notClose");
        if (p.assumedYieldBps > maxAssumedYieldBps) revert InvalidParams("yield");
        if (p.structuringFeeBps > maxStructuringFeeBps) revert InvalidParams("fee");
        if (p.exitFeeBps > maxExitFeeBps) revert InvalidParams("exitFee");
        if (p.premiumBps == 0 || p.premiumBps >= BPS) revert InvalidParams("premium");
        if (p.minSize == 0 || p.cap < p.minSize) revert InvalidParams("size");
    }

    function _tenorDays(uint8 months) internal pure returns (uint256) {
        if (months == 3) return 91;
        if (months == 6) return 182;
        return 365;
    }

    function _scale(address stable) internal view returns (uint256) {
        return 10 ** (18 - IERC20Metadata(stable).decimals());
    }

    function _cancel(uint256 id) internal {
        Series storage s = _series[id];
        s.state = State.Cancelled;
        emit SeriesCancelled(id);
        IOptionsAdapter(s.optionsAdapter).cancelSeries(id);
    }

    function _requireState(uint256 id, State expected) internal view {
        State actual = _series[id].state;
        if (actual != expected) revert WrongState(expected, actual);
    }
}
