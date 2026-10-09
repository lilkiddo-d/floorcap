// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IYieldAdapter} from "../interfaces/IYieldAdapter.sol";

/// @title YieldAdapter
/// @notice Base for bond-leg yield adapters. Keeps a segregated share balance per series so one series can never
///         redeem another series' position. Concrete adapters implement `_invest`, `_divest`, `_sharesToAssets`.
abstract contract YieldAdapter is AccessControl, ReentrancyGuard, IYieldAdapter {
    using SafeERC20 for IERC20;

    /// @notice Protocol contracts allowed to move series funds (SeriesFactory deposits, Settlement withdraws).
    bytes32 public constant VAULT_ROLE = keccak256("VAULT_ROLE");

    IERC20 internal immutable _asset;

    mapping(uint256 seriesId => uint256 shares) public sharesOf;
    uint256 public totalShares;
    uint256 public referenceApyBps;

    event Deposited(uint256 indexed seriesId, uint256 assets, uint256 shares);
    event Withdrawn(uint256 indexed seriesId, address indexed to, uint256 shares, uint256 assets);
    event ReferenceApySet(uint256 apyBps);

    error InvalidFraction();
    error ZeroAmount();

    constructor(address asset_, address admin) {
        _asset = IERC20(asset_);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function asset() external view returns (address) {
        return address(_asset);
    }

    function setReferenceApyBps(uint256 apyBps) external onlyRole(DEFAULT_ADMIN_ROLE) {
        referenceApyBps = apyBps;
        emit ReferenceApySet(apyBps);
    }

    function deposit(uint256 seriesId, uint256 assets) external onlyRole(VAULT_ROLE) nonReentrant {
        if (assets == 0) revert ZeroAmount();
        _asset.safeTransferFrom(msg.sender, address(this), assets);
        uint256 shares = _invest(assets);
        sharesOf[seriesId] += shares;
        totalShares += shares;
        emit Deposited(seriesId, assets, shares);
    }

    function withdrawShare(uint256 seriesId, uint256 numerator, uint256 denominator, address to)
        external
        onlyRole(VAULT_ROLE)
        nonReentrant
        returns (uint256 assetsOut)
    {
        if (denominator == 0 || numerator > denominator) revert InvalidFraction();
        uint256 shares = sharesOf[seriesId] * numerator / denominator;
        if (shares == 0) return 0;
        sharesOf[seriesId] -= shares;
        totalShares -= shares;
        assetsOut = _divest(shares, to);
        emit Withdrawn(seriesId, to, shares, assetsOut);
    }

    function totalAssets(uint256 seriesId) external view returns (uint256) {
        return _sharesToAssets(sharesOf[seriesId]);
    }

    function _invest(uint256 assets) internal virtual returns (uint256 shares);
    function _divest(uint256 shares, address to) internal virtual returns (uint256 assets);
    function _sharesToAssets(uint256 shares) internal view virtual returns (uint256);
}
