// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Integration points for the (separately launched) project token. All features are inert until
///         the token address is set once through the Timelock.
interface IProjectTokenHooks {
    function isActive() external view returns (bool);
    function isPriority(address account, uint256 stakedBefore) external view returns (bool);
    function totalStaked() external view returns (uint256);
    function rewardToken() external view returns (address);
    function notifyReward(uint256 amount) external;
}
