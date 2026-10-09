// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {YieldAdapter} from "./YieldAdapter.sol";

/// @title ERC4626YieldAdapter
/// @notice Bond leg invested in an ERC-4626 vault (on Robinhood Chain: a Morpho Vault V2 with USDG as asset).
/// @dev Deposits enforce a max-loss bound against the vault's own share price to catch donation/inflation
///      manipulation or a vault that silently charges entry fees.
contract ERC4626YieldAdapter is YieldAdapter {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;

    IERC4626 public immutable vault;
    uint256 public maxDepositLossBps;

    event MaxDepositLossSet(uint256 bps);

    error AssetMismatch();
    error DepositLoss(uint256 expected, uint256 got);
    error InvalidBps();

    constructor(address vault_, address admin, uint256 maxDepositLossBps_)
        YieldAdapter(IERC4626(vault_).asset(), admin)
    {
        if (address(_asset) == address(0)) revert AssetMismatch();
        if (maxDepositLossBps_ > 100) revert InvalidBps();
        vault = IERC4626(vault_);
        maxDepositLossBps = maxDepositLossBps_;
    }

    function setMaxDepositLossBps(uint256 bps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (bps > 100) revert InvalidBps();
        maxDepositLossBps = bps;
        emit MaxDepositLossSet(bps);
    }

    function _invest(uint256 assets) internal override returns (uint256 shares) {
        _asset.forceApprove(address(vault), assets);
        shares = vault.deposit(assets, address(this));
        uint256 worth = vault.previewRedeem(shares);
        uint256 minWorth = assets * (BPS - maxDepositLossBps) / BPS;
        if (worth < minWorth) revert DepositLoss(minWorth, worth);
    }

    function _divest(uint256 shares, address to) internal override returns (uint256 assets) {
        assets = vault.redeem(shares, to, address(this));
    }

    function _sharesToAssets(uint256 shares) internal view override returns (uint256) {
        return shares == 0 ? 0 : vault.previewRedeem(shares);
    }
}
