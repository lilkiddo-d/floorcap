// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ERC4626YieldAdapter} from "../../src/adapters/ERC4626YieldAdapter.sol";
import {ProjectTokenHooks} from "../../src/ProjectTokenHooks.sol";
import {SecondaryListings} from "../../src/SecondaryListings.sol";
import {MockERC20, MockVault} from "../mocks/Mocks.sol";

/// @dev Vault that silently charges a 50% entry fee.
contract LossyVault is MockVault {
    constructor(IERC20 a) MockVault(a) {}

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        return super.previewRedeem(shares) / 2;
    }
}

contract NoAssetVault {
    function asset() external pure returns (address) {
        return address(0);
    }
}

contract AdaptersTest is Test {
    MockERC20 usdg;

    function setUp() public {
        usdg = new MockERC20("USDG", "USDG", 6);
    }

    function test_erc4626_rejectsLossyVault() public {
        LossyVault v = new LossyVault(usdg);
        ERC4626YieldAdapter a = new ERC4626YieldAdapter(address(v), address(this), 10);
        a.grantRole(a.VAULT_ROLE(), address(this));
        usdg.mint(address(this), 1_000e6);
        usdg.approve(address(a), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(ERC4626YieldAdapter.DepositLoss.selector, 999e6, 500e6));
        a.deposit(1, 1_000e6);
    }

    function test_erc4626_assetMismatch() public {
        NoAssetVault v = new NoAssetVault();
        vm.expectRevert(ERC4626YieldAdapter.AssetMismatch.selector);
        new ERC4626YieldAdapter(address(v), address(this), 10);
    }

    function test_erc4626_withdraw() public {
        MockVault v = new MockVault(usdg);
        ERC4626YieldAdapter a = new ERC4626YieldAdapter(address(v), address(this), 10);
        a.grantRole(a.VAULT_ROLE(), address(this));
        usdg.mint(address(this), 1_000e6);
        usdg.approve(address(a), 1_000e6);
        a.deposit(1, 1_000e6);
        usdg.mint(address(v), 100e6); // yield
        uint256 out = a.withdrawShare(1, 1, 2, address(0xBEEF));
        assertApproxEqAbs(out, 550e6, 1);
        assertApproxEqAbs(a.totalAssets(1), 550e6, 1);
    }

    function test_hooks_guardianPause() public {
        ProjectTokenHooks h = new ProjectTokenHooks(address(this), address(usdg), 0, 1 days);
        h.grantRole(h.GUARDIAN_ROLE(), address(this));
        MockERC20 fcap = new MockERC20("F", "F", 18);
        h.setProjectToken(address(fcap));
        h.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        h.stake(1);
        h.unpause();
        fcap.mint(address(this), 10);
        fcap.approve(address(h), 10);
        h.stake(10);
        assertTrue(h.isPriority(address(this), block.timestamp));
        assertFalse(h.isPriority(address(this), block.timestamp - 1));
        vm.prank(address(0xBAD));
        vm.expectRevert();
        h.pause();
    }

    function test_listings_supportsInterface() public {
        SecondaryListings l = new SecondaryListings(address(this), address(1), 0);
        assertTrue(l.supportsInterface(0x4e2312e0));
        assertTrue(l.supportsInterface(0x7965db0b)); // IAccessControl
        assertFalse(l.supportsInterface(0xffffffff));
    }
}
