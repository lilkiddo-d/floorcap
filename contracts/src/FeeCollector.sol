// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IFeeCollector} from "./interfaces/IFeeCollector.sol";
import {IProjectTokenHooks} from "./interfaces/IProjectTokenHooks.sol";

/// @title FeeCollector
/// @notice Receives protocol fees and splits them into (1) a shortfall reserve that backstops note floors if a
///         yield source underperforms, (2) a staker share of structuring fees (only once the project token is
///         live and staked), and (3) the treasury.
contract FeeCollector is AccessControl, ReentrancyGuard, IFeeCollector {
    using SafeERC20 for IERC20;

    bytes32 public constant FEE_SOURCE_ROLE = keccak256("FEE_SOURCE_ROLE");
    bytes32 public constant SHORTFALL_ROLE = keccak256("SHORTFALL_ROLE");
    uint256 public constant BPS = 10_000;

    IProjectTokenHooks public hooks;
    uint256 public reserveShareBps;
    uint256 public stakerShareBps;

    mapping(address token => uint256) public reserve;
    mapping(address token => uint256) public treasury;

    event FeeRecorded(address indexed token, uint256 amount, bool structuring, uint256 toReserve, uint256 toStakers);
    event ShortfallCovered(address indexed token, address indexed to, uint256 requested, uint256 paid);
    event ReserveFunded(address indexed token, address indexed from, uint256 amount);
    event TreasuryWithdrawn(address indexed token, address indexed to, uint256 amount);
    event SharesSet(uint256 reserveShareBps, uint256 stakerShareBps);
    event HooksSet(address hooks);

    error InvalidShares();
    error InsufficientTreasury();
    error ZeroAddress();

    constructor(address admin, uint256 reserveShareBps_, uint256 stakerShareBps_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setShares(reserveShareBps_, stakerShareBps_);
    }

    // ---------------------------------------------------------------- admin

    function setShares(uint256 reserveShareBps_, uint256 stakerShareBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setShares(reserveShareBps_, stakerShareBps_);
    }

    function setHooks(address hooks_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        hooks = IProjectTokenHooks(hooks_);
        emit HooksSet(hooks_);
    }

    function withdrawTreasury(address token, address to, uint256 amount)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
        nonReentrant
    {
        if (to == address(0)) revert ZeroAddress();
        if (amount > treasury[token]) revert InsufficientTreasury();
        treasury[token] -= amount;
        IERC20(token).safeTransfer(to, amount);
        emit TreasuryWithdrawn(token, to, amount);
    }

    // ---------------------------------------------------------------- protocol

    /// @inheritdoc IFeeCollector
    function recordFee(address token, uint256 amount, bool structuring)
        external
        onlyRole(FEE_SOURCE_ROLE)
        nonReentrant
    {
        if (amount == 0) return;
        uint256 toReserve = amount * reserveShareBps / BPS;
        uint256 toStakers = 0;
        IProjectTokenHooks h = hooks;
        if (
            structuring && address(h) != address(0) && h.isActive() && h.totalStaked() > 0
                && h.rewardToken() == token
        ) {
            toStakers = amount * stakerShareBps / BPS;
        }
        reserve[token] += toReserve;
        treasury[token] += amount - toReserve - toStakers;
        emit FeeRecorded(token, amount, structuring, toReserve, toStakers);
        if (toStakers > 0) {
            IERC20(token).safeTransfer(address(h), toStakers);
            h.notifyReward(toStakers);
        }
    }

    /// @inheritdoc IFeeCollector
    function coverShortfall(address token, uint256 amount)
        external
        onlyRole(SHORTFALL_ROLE)
        nonReentrant
        returns (uint256 paid)
    {
        uint256 available = reserve[token];
        paid = amount < available ? amount : available;
        if (paid == 0) return 0;
        reserve[token] = available - paid;
        emit ShortfallCovered(token, msg.sender, amount, paid);
        IERC20(token).safeTransfer(msg.sender, paid);
    }

    /// @notice Anyone may top up the shortfall reserve.
    function fundReserve(address token, uint256 amount) external nonReentrant {
        uint256 before = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - before;
        reserve[token] += received;
        emit ReserveFunded(token, msg.sender, received);
    }

    function _setShares(uint256 r, uint256 s) internal {
        if (r + s > BPS) revert InvalidShares();
        reserveShareBps = r;
        stakerShareBps = s;
        emit SharesSet(r, s);
    }
}
