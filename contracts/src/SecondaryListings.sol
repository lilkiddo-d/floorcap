// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {ISeriesFactory} from "./interfaces/ISeriesFactory.sol";
import {IComplianceRegistry} from "./interfaces/IComplianceRegistry.sol";
import {IFeeCollector} from "./interfaces/IFeeCollector.sol";

/// @title SecondaryListings
/// @notice Simple fixed-price order book for notes. Sellers escrow notes; buyers fill any part at the listed price.
/// @dev priceWad = stablecoin base units paid per note unit, 1e18 = par (1 stable per 1 stable of principal).
contract SecondaryListings is AccessControl, Pausable, ReentrancyGuard, ERC1155Holder {
    using SafeERC20 for IERC20;

    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant ACTION_BUY = keccak256("BUY");
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS = 10_000;
    uint256 public constant MAX_FEE_BPS = 200;

    struct Listing {
        address seller;
        uint256 seriesId;
        uint256 remaining;
        uint256 priceWad;
        uint64 expiry;
    }

    ISeriesFactory public immutable factory;
    uint256 public feeBps;
    uint256 public listingCount;
    mapping(uint256 => Listing) public listings;

    event Listed(uint256 indexed listingId, address indexed seller, uint256 indexed seriesId, uint256 amount, uint256 priceWad, uint64 expiry);
    event Cancelled(uint256 indexed listingId, uint256 returned);
    event Bought(uint256 indexed listingId, address indexed buyer, uint256 amount, uint256 cost, uint256 fee);
    event FeeSet(uint256 feeBps);

    error InvalidListing();
    error NotSeller();
    error Expired();
    error PriceAboveMax();
    error NotAllowed();
    error InvalidFee();
    error WrongState();

    constructor(address admin, address factory_, uint256 feeBps_) {
        if (feeBps_ > MAX_FEE_BPS) revert InvalidFee();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        factory = ISeriesFactory(factory_);
        feeBps = feeBps_;
    }

    function setFeeBps(uint256 feeBps_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (feeBps_ > MAX_FEE_BPS) revert InvalidFee();
        feeBps = feeBps_;
        emit FeeSet(feeBps_);
    }

    function pause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(GUARDIAN_ROLE) {
        _unpause();
    }

    function list(uint256 seriesId, uint256 amount, uint256 priceWad, uint64 expiry)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 listingId)
    {
        if (amount == 0 || priceWad == 0 || expiry <= block.timestamp) revert InvalidListing();
        if (factory.seriesState(seriesId) != ISeriesFactory.State.Locked) revert WrongState();
        listingId = ++listingCount;
        listings[listingId] = Listing(msg.sender, seriesId, amount, priceWad, expiry);
        emit Listed(listingId, msg.sender, seriesId, amount, priceWad, expiry);
        IERC1155(factory.note()).safeTransferFrom(msg.sender, address(this), seriesId, amount, "");
    }

    /// @notice Seller reclaims the unsold remainder. Never pausable.
    function cancel(uint256 listingId) external nonReentrant {
        Listing storage l = listings[listingId];
        if (l.seller != msg.sender) revert NotSeller();
        uint256 amount = l.remaining;
        uint256 seriesId = l.seriesId;
        delete listings[listingId];
        emit Cancelled(listingId, amount);
        if (amount > 0) IERC1155(factory.note()).safeTransferFrom(address(this), msg.sender, seriesId, amount, "");
    }

    /// @param maxPriceWad Slippage guard (protects against a listing being swapped under the buyer).
    function buy(uint256 listingId, uint256 amount, uint256 maxPriceWad, uint256 deadline)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 cost)
    {
        if (block.timestamp > deadline) revert Expired();
        Listing storage l = listings[listingId];
        if (l.seller == address(0) || amount == 0 || amount > l.remaining) revert InvalidListing();
        if (block.timestamp >= l.expiry) revert Expired();
        if (l.priceWad > maxPriceWad) revert PriceAboveMax();
        if (factory.seriesState(l.seriesId) != ISeriesFactory.State.Locked) revert WrongState();
        address c = factory.compliance();
        if (c != address(0) && !IComplianceRegistry(c).isAllowed(msg.sender, ACTION_BUY)) revert NotAllowed();

        cost = Math.mulDiv(amount, l.priceWad, WAD, Math.Rounding.Ceil);
        uint256 fee = cost * feeBps / BPS;
        l.remaining -= amount;
        address seller = l.seller;
        uint256 seriesId = l.seriesId;
        emit Bought(listingId, msg.sender, amount, cost, fee);

        IERC20 stable = IERC20(factory.getSeries(seriesId).stable);
        stable.safeTransferFrom(msg.sender, seller, cost - fee);
        if (fee > 0) {
            address fc = factory.feeCollector();
            stable.safeTransferFrom(msg.sender, fc, fee);
            IFeeCollector(fc).recordFee(address(stable), fee, false);
        }
        IERC1155(factory.note()).safeTransferFrom(address(this), msg.sender, seriesId, amount, "");
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(AccessControl, ERC1155Holder)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
