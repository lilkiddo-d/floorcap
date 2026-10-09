// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {YieldAdapter} from "./YieldAdapter.sol";

/// @title HoldYieldAdapter
/// @notice Zero-yield, zero-counterparty bond leg: simply custodies the stablecoin. Series using it must assume 0%
///         yield, so only the 95%-protected variant has an upside budget. It is the fallback when no vetted yield
///         source is available, and the safe harbour if a yield source is ever deprecated.
contract HoldYieldAdapter is YieldAdapter {
    using SafeERC20 for IERC20;

    constructor(address asset_, address admin) YieldAdapter(asset_, admin) {}

    function _invest(uint256 assets) internal pure override returns (uint256) {
        return assets;
    }

    function _divest(uint256 shares, address to) internal override returns (uint256) {
        _asset.safeTransfer(to, shares);
        return shares;
    }

    function _sharesToAssets(uint256 shares) internal pure override returns (uint256) {
        return shares;
    }
}
