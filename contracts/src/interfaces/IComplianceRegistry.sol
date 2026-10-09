// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Pluggable compliance gate. Off by default: every account is allowed until enabled.
interface IComplianceRegistry {
    function isAllowed(address account, bytes32 action) external view returns (bool);
}
