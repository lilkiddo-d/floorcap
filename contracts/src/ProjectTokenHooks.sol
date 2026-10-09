// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IProjectTokenHooks} from "./interfaces/IProjectTokenHooks.sol";

/// @title ProjectTokenHooks
/// @notice Staking + perks for the separately launched project token ($FCAP). The protocol never deploys a token.
///         Until `setProjectToken` is executed (once, by the Timelock) every feature here is inert:
///         `isActive()` is false, nobody is priority, and FeeCollector routes nothing to stakers.
/// @dev Perks: (1) stakers whose stake predates a series' creation get priority allocation when it is
///      oversubscribed; (2) stakers earn a share of structuring fees in the reward token (the stablecoin).
contract ProjectTokenHooks is AccessControl, Pausable, ReentrancyGuard, IProjectTokenHooks {
    using SafeERC20 for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant NOTIFIER_ROLE = keccak256("NOTIFIER_ROLE");
    uint256 internal constant ACC = 1e36;
    uint256 public constant MAX_COOLDOWN = 30 days;

    IERC20 public projectToken;
    IERC20 internal immutable _rewardToken;

    uint256 public minPriorityStake;
    uint256 public unstakeCooldown;

    uint256 public totalStaked;
    mapping(address => uint256) public stakedOf;
    mapping(address => uint256) public stakedSince;

    struct PendingUnstake {
        uint256 amount;
        uint256 availableAt;
    }

    mapping(address => PendingUnstake) public pendingUnstake;

    uint256 public rewardPerTokenStored;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event ProjectTokenSet(address token);
    event Staked(address indexed account, uint256 amount);
    event UnstakeRequested(address indexed account, uint256 amount, uint256 availableAt);
    event Withdrawn(address indexed account, uint256 amount);
    event RewardNotified(uint256 amount, uint256 rewardPerToken);
    event RewardClaimed(address indexed account, uint256 amount);
    event ParamsSet(uint256 minPriorityStake, uint256 unstakeCooldown);

    error AlreadySet();
    error ZeroAddress();
    error Inactive();
    error ZeroAmount();
    error InsufficientStake();
    error CooldownActive();
    error NoStakers();
    error InvalidParams();

    constructor(address admin, address rewardToken_, uint256 minPriorityStake_, uint256 unstakeCooldown_) {
        if (rewardToken_ == address(0)) revert ZeroAddress();
        if (unstakeCooldown_ > MAX_COOLDOWN) revert InvalidParams();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _rewardToken = IERC20(rewardToken_);
        minPriorityStake = minPriorityStake_;
        unstakeCooldown = unstakeCooldown_;
    }

    // ---------------------------------------------------------------- admin

    /// @notice One-shot: wires the launched project token. Callable only by DEFAULT_ADMIN_ROLE (the Timelock).
    function setProjectToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(projectToken) != address(0)) revert AlreadySet();
        if (token == address(0) || token == address(_rewardToken)) revert ZeroAddress();
        projectToken = IERC20(token);
        emit ProjectTokenSet(token);
    }

    function setParams(uint256 minPriorityStake_, uint256 unstakeCooldown_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (unstakeCooldown_ > MAX_COOLDOWN) revert InvalidParams();
        minPriorityStake = minPriorityStake_;
        unstakeCooldown = unstakeCooldown_;
        emit ParamsSet(minPriorityStake_, unstakeCooldown_);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    // ---------------------------------------------------------------- views

    function isActive() public view returns (bool) {
        return address(projectToken) != address(0);
    }

    function rewardToken() external view returns (address) {
        return address(_rewardToken);
    }

    /// @notice Priority if active, stake >= minPriorityStake (and > 0), and the stake was last increased no later
    ///         than `stakedBefore` (series creation time), which defeats just-in-time flash staking.
    function isPriority(address account, uint256 stakedBefore) external view returns (bool) {
        if (!isActive()) return false;
        uint256 s = stakedOf[account];
        return s > 0 && s >= minPriorityStake && stakedSince[account] <= stakedBefore;
    }

    function earned(address account) public view returns (uint256) {
        return rewards[account] + stakedOf[account] * (rewardPerTokenStored - userRewardPerTokenPaid[account]) / ACC;
    }

    // ---------------------------------------------------------------- staking

    function stake(uint256 amount) external nonReentrant whenNotPaused {
        if (!isActive()) revert Inactive();
        if (amount == 0) revert ZeroAmount();
        _updateReward(msg.sender);
        uint256 before = projectToken.balanceOf(address(this));
        projectToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = projectToken.balanceOf(address(this)) - before;
        stakedOf[msg.sender] += received;
        stakedSince[msg.sender] = block.timestamp;
        totalStaked += received;
        emit Staked(msg.sender, received);
    }

    function requestUnstake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (amount > stakedOf[msg.sender]) revert InsufficientStake();
        _updateReward(msg.sender);
        stakedOf[msg.sender] -= amount;
        totalStaked -= amount;
        PendingUnstake storage p = pendingUnstake[msg.sender];
        p.amount += amount;
        p.availableAt = block.timestamp + unstakeCooldown;
        emit UnstakeRequested(msg.sender, amount, p.availableAt);
    }

    function withdraw() external nonReentrant {
        PendingUnstake memory p = pendingUnstake[msg.sender];
        if (p.amount == 0) revert ZeroAmount();
        if (block.timestamp < p.availableAt) revert CooldownActive();
        delete pendingUnstake[msg.sender];
        emit Withdrawn(msg.sender, p.amount);
        projectToken.safeTransfer(msg.sender, p.amount);
    }

    function claimRewards() external nonReentrant returns (uint256 amount) {
        _updateReward(msg.sender);
        amount = rewards[msg.sender];
        // accounting value, not a token balance
        // slither-disable-next-line incorrect-equality
        if (amount == 0) return 0;
        rewards[msg.sender] = 0;
        emit RewardClaimed(msg.sender, amount);
        _rewardToken.safeTransfer(msg.sender, amount);
    }

    /// @notice Called by FeeCollector after transferring `amount` reward tokens here.
    function notifyReward(uint256 amount) external onlyRole(NOTIFIER_ROLE) {
        if (totalStaked == 0) revert NoStakers();
        rewardPerTokenStored += amount * ACC / totalStaked;
        emit RewardNotified(amount, rewardPerTokenStored);
    }

    function _updateReward(address account) internal {
        rewards[account] = earned(account);
        userRewardPerTokenPaid[account] = rewardPerTokenStored;
    }
}
