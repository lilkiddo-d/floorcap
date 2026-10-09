// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IComplianceRegistry} from "../interfaces/IComplianceRegistry.sol";

/// @title ComplianceRegistry
/// @notice Pluggable allowlist gate. Disabled by default (everyone allowed). When enabled, each action that is
///         marked as gated requires the account to be allowlisted. Actions are free-form bytes32 ids.
contract ComplianceRegistry is AccessControl, IComplianceRegistry {
    bytes32 public constant COMPLIANCE_ROLE = keccak256("COMPLIANCE_ROLE");

    bytes32 public constant ACTION_SUBSCRIBE = keccak256("SUBSCRIBE");
    bytes32 public constant ACTION_TRANSFER = keccak256("TRANSFER");
    bytes32 public constant ACTION_BUY = keccak256("BUY");
    bytes32 public constant ACTION_UNDERWRITE = keccak256("UNDERWRITE");

    uint256 public constant MAX_BATCH = 200;

    bool public enabled;
    mapping(bytes32 action => bool) public isGated;
    mapping(address account => bool) public allowed;

    event EnabledSet(bool enabled);
    event ActionGated(bytes32 indexed action, bool gated);
    event AllowedSet(address indexed account, bool allowed);

    error BatchTooLarge();

    constructor(address admin) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(COMPLIANCE_ROLE, admin);
        isGated[ACTION_SUBSCRIBE] = true;
        isGated[ACTION_TRANSFER] = true;
        isGated[ACTION_BUY] = true;
        isGated[ACTION_UNDERWRITE] = true;
    }

    function isAllowed(address account, bytes32 action) external view returns (bool) {
        if (!enabled || !isGated[action]) return true;
        return allowed[account];
    }

    function setEnabled(bool on) external onlyRole(DEFAULT_ADMIN_ROLE) {
        enabled = on;
        emit EnabledSet(on);
    }

    function setActionGated(bytes32 action, bool gated) external onlyRole(DEFAULT_ADMIN_ROLE) {
        isGated[action] = gated;
        emit ActionGated(action, gated);
    }

    function setAllowed(address[] calldata accounts, bool on) external onlyRole(COMPLIANCE_ROLE) {
        if (accounts.length > MAX_BATCH) revert BatchTooLarge();
        for (uint256 i; i < accounts.length; ++i) {
            allowed[accounts[i]] = on;
            emit AllowedSet(accounts[i], on);
        }
    }
}
