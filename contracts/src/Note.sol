// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {ERC1155Supply} from "@openzeppelin/contracts/token/ERC1155/extensions/ERC1155Supply.sol";
import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";

/// @title Note
/// @notice ERC-1155 structured note. Token id = series id; 1 unit = 1 base unit of the series stablecoin of principal.
///         Freely transferable unless the (optional) compliance registry gates transfers.
contract Note is ERC1155Supply, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 public constant ACTION_TRANSFER = keccak256("TRANSFER");

    string public constant name = "Floorcap Principal-Protected Note";
    string public constant symbol = "FCN";

    IComplianceRegistry public compliance;

    event ComplianceSet(address registry);
    event URISet(string uri);

    error NotAllowed(address account);

    constructor(address admin, string memory uri_) ERC1155(uri_) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function setCompliance(address registry) external onlyRole(DEFAULT_ADMIN_ROLE) {
        compliance = IComplianceRegistry(registry);
        emit ComplianceSet(registry);
    }

    function setURI(string calldata uri_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setURI(uri_);
        emit URISet(uri_);
    }

    function mint(address to, uint256 id, uint256 amount) external onlyRole(MINTER_ROLE) {
        _mint(to, id, amount, "");
    }

    function burn(address from, uint256 id, uint256 amount) external onlyRole(BURNER_ROLE) {
        _burn(from, id, amount);
    }

    function _update(address from, address to, uint256[] memory ids, uint256[] memory values)
        internal
        override(ERC1155Supply)
    {
        if (from != address(0) && to != address(0)) {
            IComplianceRegistry c = compliance;
            if (address(c) != address(0) && !c.isAllowed(to, ACTION_TRANSFER)) revert NotAllowed(to);
        }
        super._update(from, to, ids, values);
    }

    function supportsInterface(bytes4 interfaceId) public view override(ERC1155, AccessControl) returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
