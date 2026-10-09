// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IOptionsAdapter} from "./interfaces/IOptionsAdapter.sol";
import {ISeriesFactory} from "./interfaces/ISeriesFactory.sol";
import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";

/// @title UnderwriterPool
/// @notice Built-in options venue (Robinhood Chain has no on-chain options market). Underwriters post the basket's
///         stock tokens as collateral for a specific series and sell it fully collateralized (covered) calls,
///         earning the premium paid at lock.
/// @dev Solvency by construction: a call on U basket units pays U * (level - strike) / level basket units in kind,
///      which is always < U. Collateral is posted in kind (U * quantity_i of each token), so collateral covers the
///      maximum payout for any price path. All underwriter claims are pro-rata to committed units (no loops).
contract UnderwriterPool is AccessControl, Pausable, ReentrancyGuard, IOptionsAdapter {
    using SafeERC20 for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant FACTORY_ROLE = keccak256("FACTORY_ROLE");
    bytes32 public constant SETTLEMENT_ROLE = keccak256("SETTLEMENT_ROLE");
    bytes32 public constant ACTION_UNDERWRITE = keccak256("UNDERWRITE");
    uint256 internal constant WAD = 1e18;

    enum Status {
        Collecting,
        Active,
        Closed,
        Cancelled
    }

    struct PoolSeries {
        Status status;
        uint256 totalCommitted; // basket units
        uint256 used; // units sold to the note at lock
        uint256 open; // units not yet exercised
        uint256 paid; // basket units paid out to note holders
        uint256 strike;
        address premiumToken;
        uint256 premium;
    }

    struct Position {
        uint256 committed;
        bool unusedWithdrawn;
        bool premiumClaimed;
        bool finalClaimed;
    }

    ISeriesFactory public immutable factory;

    mapping(uint256 => PoolSeries) internal _pool;
    mapping(uint256 => mapping(address => Position)) public positions;

    event Committed(uint256 indexed seriesId, address indexed underwriter, uint256 units);
    event Uncommitted(uint256 indexed seriesId, address indexed underwriter, uint256 units);
    event CallOpened(uint256 indexed seriesId, uint256 units, uint256 strike, uint256 premium);
    event Exercised(uint256 indexed seriesId, address indexed to, uint256 units, uint256 level, uint256 payoutUnits);
    event SeriesClosed(uint256 indexed seriesId, uint256 paidUnits);
    event SeriesCancelled(uint256 indexed seriesId);
    event UnusedWithdrawn(uint256 indexed seriesId, address indexed underwriter, uint256 units);
    event PremiumClaimed(uint256 indexed seriesId, address indexed underwriter, uint256 amount);
    event FinalClaimed(uint256 indexed seriesId, address indexed underwriter, uint256 units);
    event CancelledWithdrawn(uint256 indexed seriesId, address indexed underwriter, uint256 units);

    error WrongStatus(Status expected, Status actual);
    error SeriesNotOpen();
    error ZeroAmount();
    error InsufficientCommitment();
    error ExceedsCapacity();
    error AlreadyClaimed();
    error OpenUnitsRemain();
    error NotAllowed();

    constructor(address admin, address factory_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(FACTORY_ROLE, factory_);
        factory = ISeriesFactory(factory_);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    // ================================================================= underwriters

    /// @notice Post collateral for `units` basket units (rounded up per token) and offer them to series `id`.
    function commit(uint256 id, uint256 units) external nonReentrant whenNotPaused {
        if (units == 0) revert ZeroAmount();
        _requireCollecting(id);
        address c = factory.compliance();
        if (c != address(0) && !IComplianceRegistry(c).isAllowed(msg.sender, ACTION_UNDERWRITE)) revert NotAllowed();
        PoolSeries storage ps = _pool[id];
        _requireStatus(ps, Status.Collecting);
        positions[id][msg.sender].committed += units;
        ps.totalCommitted += units;
        emit Committed(id, msg.sender, units);
        (address[] memory tokens, uint256[] memory qty) = factory.getBasket(id);
        for (uint256 i; i < tokens.length; ++i) {
            IERC20(tokens[i]).safeTransferFrom(
                msg.sender, address(this), Math.mulDiv(units, qty[i], WAD, Math.Rounding.Ceil)
            );
        }
    }

    /// @notice Withdraw commitment before the subscription ends.
    function uncommit(uint256 id, uint256 units) external nonReentrant {
        if (units == 0) revert ZeroAmount();
        _requireCollecting(id);
        PoolSeries storage ps = _pool[id];
        _requireStatus(ps, Status.Collecting);
        Position storage pos = positions[id][msg.sender];
        if (units > pos.committed) revert InsufficientCommitment();
        pos.committed -= units;
        ps.totalCommitted -= units;
        emit Uncommitted(id, msg.sender, units);
        _sendUnits(id, units, msg.sender);
    }

    /// @notice After lock: withdraw the pro-rata share of commitments that were not sold.
    function withdrawUnused(uint256 id) public nonReentrant returns (uint256 units) {
        units = _withdrawUnused(id, msg.sender);
    }

    /// @notice After lock: claim the pro-rata share of the premium.
    function claimPremium(uint256 id) external nonReentrant returns (uint256 amount) {
        PoolSeries storage ps = _pool[id];
        if (ps.status != Status.Active && ps.status != Status.Closed) revert WrongStatus(Status.Active, ps.status);
        Position storage pos = positions[id][msg.sender];
        if (pos.premiumClaimed) revert AlreadyClaimed();
        pos.premiumClaimed = true;
        amount = Math.mulDiv(ps.premium, pos.committed, ps.totalCommitted);
        emit PremiumClaimed(id, msg.sender, amount);
        if (amount > 0) IERC20(ps.premiumToken).safeTransfer(msg.sender, amount);
    }

    /// @notice After settlement: claim the pro-rata share of collateral left after note payouts (+ unused, if any).
    function claimFinal(uint256 id) external nonReentrant returns (uint256 units) {
        PoolSeries storage ps = _pool[id];
        _requireStatus(ps, Status.Closed);
        Position storage pos = positions[id][msg.sender];
        if (pos.finalClaimed) revert AlreadyClaimed();
        if (!pos.unusedWithdrawn) _withdrawUnused(id, msg.sender);
        pos.finalClaimed = true;
        units = Math.mulDiv(pos.committed, ps.used - ps.paid, ps.totalCommitted);
        emit FinalClaimed(id, msg.sender, units);
        _sendUnits(id, units, msg.sender);
    }

    /// @notice Series cancelled before lock: full collateral back.
    function withdrawCancelled(uint256 id) external nonReentrant returns (uint256 units) {
        PoolSeries storage ps = _pool[id];
        _requireStatus(ps, Status.Cancelled);
        Position storage pos = positions[id][msg.sender];
        units = pos.committed;
        if (units == 0) revert ZeroAmount();
        pos.committed = 0;
        ps.totalCommitted -= units;
        emit CancelledWithdrawn(id, msg.sender, units);
        _sendUnits(id, units, msg.sender);
    }

    // ================================================================= IOptionsAdapter (protocol only)

    function capacity(uint256 id) external view returns (uint256) {
        PoolSeries storage ps = _pool[id];
        return ps.status == Status.Collecting ? ps.totalCommitted : 0;
    }

    function openUnits(uint256 id) external view returns (uint256) {
        return _pool[id].open;
    }

    function openCall(uint256 id, uint256 units, uint256 strike, address premiumToken, uint256 premium)
        external
        onlyRole(FACTORY_ROLE)
        nonReentrant
    {
        PoolSeries storage ps = _pool[id];
        _requireStatus(ps, Status.Collecting);
        if (units == 0 || units > ps.totalCommitted) revert ExceedsCapacity();
        ps.status = Status.Active;
        ps.used = units;
        ps.open = units;
        ps.strike = strike;
        ps.premiumToken = premiumToken;
        ps.premium = premium;
        emit CallOpened(id, units, strike, premium);
        IERC20(premiumToken).safeTransferFrom(msg.sender, address(this), premium);
    }

    function exercise(uint256 id, uint256 units, uint256 level, address to)
        external
        onlyRole(SETTLEMENT_ROLE)
        nonReentrant
        returns (uint256 payoutUnits)
    {
        PoolSeries storage ps = _pool[id];
        _requireStatus(ps, Status.Active);
        if (units > ps.open) revert ExceedsCapacity();
        ps.open -= units;
        if (level > ps.strike) payoutUnits = Math.mulDiv(units, level - ps.strike, level);
        ps.paid += payoutUnits;
        emit Exercised(id, to, units, level, payoutUnits);
        if (payoutUnits > 0) _sendUnits(id, payoutUnits, to);
    }

    function closeSeries(uint256 id) external onlyRole(SETTLEMENT_ROLE) {
        PoolSeries storage ps = _pool[id];
        _requireStatus(ps, Status.Active);
        if (ps.open != 0) revert OpenUnitsRemain();
        ps.status = Status.Closed;
        emit SeriesClosed(id, ps.paid);
    }

    function cancelSeries(uint256 id) external onlyRole(FACTORY_ROLE) {
        PoolSeries storage ps = _pool[id];
        _requireStatus(ps, Status.Collecting);
        ps.status = Status.Cancelled;
        emit SeriesCancelled(id);
    }

    // ================================================================= views

    function poolOf(uint256 id) external view returns (PoolSeries memory) {
        return _pool[id];
    }

    /// @notice Max basket units the pool could ever owe for `id` (open calls pay strictly less than this).
    function maxObligationUnits(uint256 id) external view returns (uint256) {
        return _pool[id].open;
    }

    /// @notice Token amounts that back `units` basket units of series `id`.
    function unitsToTokens(uint256 id, uint256 units)
        external
        view
        returns (address[] memory tokens, uint256[] memory amounts)
    {
        uint256[] memory qty;
        (tokens, qty) = factory.getBasket(id);
        amounts = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            amounts[i] = Math.mulDiv(units, qty[i], WAD);
        }
    }

    // ================================================================= internals

    function _withdrawUnused(uint256 id, address account) internal returns (uint256 units) {
        PoolSeries storage ps = _pool[id];
        if (ps.status != Status.Active && ps.status != Status.Closed) revert WrongStatus(Status.Active, ps.status);
        Position storage pos = positions[id][account];
        if (pos.unusedWithdrawn) revert AlreadyClaimed();
        pos.unusedWithdrawn = true;
        units = Math.mulDiv(pos.committed, ps.totalCommitted - ps.used, ps.totalCommitted);
        emit UnusedWithdrawn(id, account, units);
        _sendUnits(id, units, account);
    }

    function _sendUnits(uint256 id, uint256 units, address to) internal {
        if (units == 0) return;
        (address[] memory tokens, uint256[] memory qty) = factory.getBasket(id);
        for (uint256 i; i < tokens.length; ++i) {
            uint256 amt = Math.mulDiv(units, qty[i], WAD);
            if (amt > 0) IERC20(tokens[i]).safeTransfer(to, amt);
        }
    }

    function _requireCollecting(uint256 id) internal view {
        ISeriesFactory.Series memory s = factory.getSeries(id);
        if (s.state != ISeriesFactory.State.Subscription || block.timestamp >= s.subscriptionEnd) {
            revert SeriesNotOpen();
        }
    }

    function _requireStatus(PoolSeries storage ps, Status expected) internal view {
        if (ps.status != expected) revert WrongStatus(expected, ps.status);
    }
}
