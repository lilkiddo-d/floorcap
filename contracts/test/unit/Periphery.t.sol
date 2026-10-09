// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {BaseTest} from "../BaseTest.sol";
import {ISeriesFactory} from "../../src/interfaces/ISeriesFactory.sol";
import {SeriesFactory} from "../../src/SeriesFactory.sol";
import {UnderwriterPool} from "../../src/UnderwriterPool.sol";
import {SecondaryListings} from "../../src/SecondaryListings.sol";
import {FeeCollector} from "../../src/FeeCollector.sol";
import {ProjectTokenHooks} from "../../src/ProjectTokenHooks.sol";
import {ComplianceRegistry} from "../../src/compliance/ComplianceRegistry.sol";
import {Note} from "../../src/Note.sol";
import {YieldAdapter} from "../../src/adapters/YieldAdapter.sol";
import {ERC4626YieldAdapter} from "../../src/adapters/ERC4626YieldAdapter.sol";
import {Timelock} from "../../src/governance/Timelock.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {MockERC20} from "../mocks/Mocks.sol";

contract PeripheryTest is BaseTest {
    uint256 internal id;

    function setUp() public override {
        super.setUp();
        id = _createDefault();
        _commit(uw1, id, 600e18);
        _commit(uw2, id, 400e18);
    }

    function _lockedWithNotes() internal {
        _subscribe(alice, id, 100_000e6);
        _lock(id, _prices1(200e8));
        _claimAlloc(id, alice);
    }

    // ================================================================= UnderwriterPool

    function test_pool_uncommit() public {
        uint256 a0 = aapl.balanceOf(uw1);
        vm.prank(uw1);
        d.pool.uncommit(id, 100e18);
        assertEq(aapl.balanceOf(uw1) - a0, 100e18);
        assertEq(d.pool.capacity(id), 900e18);
        vm.expectRevert(UnderwriterPool.InsufficientCommitment.selector);
        vm.prank(uw1);
        d.pool.uncommit(id, 501e18);
        vm.expectRevert(UnderwriterPool.ZeroAmount.selector);
        vm.prank(uw1);
        d.pool.uncommit(id, 0);
    }

    function test_pool_commit_reverts() public {
        vm.expectRevert(UnderwriterPool.ZeroAmount.selector);
        vm.prank(uw1);
        d.pool.commit(id, 0);
        vm.expectRevert(UnderwriterPool.SeriesNotOpen.selector);
        vm.prank(uw1);
        d.pool.commit(999, 1);
        vm.warp(_subEnd());
        vm.expectRevert(UnderwriterPool.SeriesNotOpen.selector);
        vm.prank(uw1);
        d.pool.commit(id, 1);
        d.pool.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(uw1);
        d.pool.commit(id, 1);
        d.pool.unpause();
    }

    function test_pool_claims_doubleAndStatus() public {
        vm.expectRevert(abi.encodeWithSelector(UnderwriterPool.WrongStatus.selector, 1, 0));
        vm.prank(uw1);
        d.pool.claimPremium(id);
        vm.expectRevert(abi.encodeWithSelector(UnderwriterPool.WrongStatus.selector, 1, 0));
        vm.prank(uw1);
        d.pool.withdrawUnused(id);
        vm.expectRevert(abi.encodeWithSelector(UnderwriterPool.WrongStatus.selector, 2, 0));
        vm.prank(uw1);
        d.pool.claimFinal(id);
        vm.expectRevert(abi.encodeWithSelector(UnderwriterPool.WrongStatus.selector, 3, 0));
        vm.prank(uw1);
        d.pool.withdrawCancelled(id);

        _lockedWithNotes();
        vm.prank(uw1);
        uint256 unused = d.pool.withdrawUnused(id);
        assertEq(unused, 487.5e18);
        vm.expectRevert(UnderwriterPool.AlreadyClaimed.selector);
        vm.prank(uw1);
        d.pool.withdrawUnused(id);
        vm.prank(uw1);
        d.pool.claimPremium(id);
        vm.expectRevert(UnderwriterPool.AlreadyClaimed.selector);
        vm.prank(uw1);
        d.pool.claimPremium(id);
        _settle(id, _prices1(260e8));
        vm.prank(uw1);
        d.pool.claimFinal(id);
        vm.expectRevert(UnderwriterPool.AlreadyClaimed.selector);
        vm.prank(uw1);
        d.pool.claimFinal(id);
        assertEq(d.pool.poolOf(id).paid, uint256(187.5e18) * 60e18 / 260e18);
    }

    function test_pool_protocolOnly() public {
        vm.expectRevert();
        d.pool.openCall(id, 1, 1, address(usdg), 0);
        vm.expectRevert();
        d.pool.exercise(id, 1, 1, alice);
        vm.expectRevert();
        d.pool.closeSeries(id);
        vm.expectRevert();
        d.pool.cancelSeries(id);
    }

    function test_pool_exerciseBounds() public {
        _lockedWithNotes();
        vm.startPrank(address(d.settlement));
        vm.expectRevert(UnderwriterPool.ExceedsCapacity.selector);
        d.pool.exercise(id, 188e18, 300e18, alice);
        vm.expectRevert(UnderwriterPool.OpenUnitsRemain.selector);
        d.pool.closeSeries(id);
        vm.stopPrank();
        vm.startPrank(address(d.factory));
        vm.expectRevert(abi.encodeWithSelector(UnderwriterPool.WrongStatus.selector, 0, 1));
        d.pool.openCall(id, 1, 1, address(usdg), 0);
        vm.stopPrank();
    }

    function test_pool_openCall_exceedsCapacity() public {
        uint256 sid = _createDefault();
        vm.prank(address(d.factory));
        vm.expectRevert(UnderwriterPool.ExceedsCapacity.selector);
        d.pool.openCall(sid, 1, 1, address(usdg), 0);
    }

    function test_pool_views() public {
        _lockedWithNotes();
        assertEq(d.pool.maxObligationUnits(id), 187.5e18);
        (address[] memory t, uint256[] memory a) = d.pool.unitsToTokens(id, 2e18);
        assertEq(t[0], address(aapl));
        assertEq(a[0], 2e18);
        (,,, bool finalClaimed) = d.pool.positions(id, uw1);
        assertFalse(finalClaimed);
    }

    // ================================================================= SecondaryListings

    function test_listings_flow() public {
        _lockedWithNotes();
        vm.startPrank(alice);
        d.note.setApprovalForAll(address(d.listings), true);
        uint256 lid = d.listings.list(id, 10_000e6, 0.98e18, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        assertEq(d.note.balanceOf(address(d.listings), id), 10_000e6);

        uint256 a0 = usdg.balanceOf(alice);
        vm.prank(bob);
        uint256 cost = d.listings.buy(lid, 4_000e6, 1e18, block.timestamp);
        assertEq(cost, 3_920e6);
        assertEq(d.note.balanceOf(bob, id), 4_000e6);
        uint256 fee = cost * 50 / 10_000;
        assertEq(usdg.balanceOf(alice) - a0, cost - fee);

        vm.expectRevert(SecondaryListings.NotSeller.selector);
        vm.prank(bob);
        d.listings.cancel(lid);
        vm.prank(alice);
        d.listings.cancel(lid);
        assertEq(d.note.balanceOf(alice, id), 96_000e6);
    }

    function test_listings_reverts() public {
        _lockedWithNotes();
        vm.startPrank(alice);
        d.note.setApprovalForAll(address(d.listings), true);
        vm.expectRevert(SecondaryListings.InvalidListing.selector);
        d.listings.list(id, 0, 1e18, uint64(block.timestamp + 1));
        vm.expectRevert(SecondaryListings.InvalidListing.selector);
        d.listings.list(id, 1, 1e18, uint64(block.timestamp));
        vm.expectRevert(SecondaryListings.WrongState.selector);
        d.listings.list(999, 1, 1e18, uint64(block.timestamp + 1));
        uint256 lid = d.listings.list(id, 1_000e6, 1.05e18, uint64(block.timestamp + 1 hours));
        vm.stopPrank();

        vm.startPrank(bob);
        vm.expectRevert(SecondaryListings.PriceAboveMax.selector);
        d.listings.buy(lid, 1e6, 1e18, block.timestamp);
        vm.expectRevert(SecondaryListings.Expired.selector);
        d.listings.buy(lid, 1e6, 2e18, block.timestamp - 1);
        vm.expectRevert(SecondaryListings.InvalidListing.selector);
        d.listings.buy(lid, 2_000e6, 2e18, block.timestamp);
        vm.expectRevert(SecondaryListings.InvalidListing.selector);
        d.listings.buy(lid + 1, 1, 2e18, block.timestamp);
        vm.stopPrank();

        d.listings.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vm.prank(bob);
        d.listings.buy(lid, 1e6, 2e18, block.timestamp);
        d.listings.unpause();

        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(SecondaryListings.Expired.selector);
        vm.prank(bob);
        d.listings.buy(lid, 1e6, 2e18, block.timestamp);
    }

    function test_listings_blockedAfterSettlement() public {
        _lockedWithNotes();
        vm.startPrank(alice);
        d.note.setApprovalForAll(address(d.listings), true);
        uint256 lid = d.listings.list(id, 1_000e6, 1e18, uint64(block.timestamp + 400 days));
        vm.stopPrank();
        _settle(id, _prices1(200e8));
        vm.expectRevert(SecondaryListings.WrongState.selector);
        vm.prank(bob);
        d.listings.buy(lid, 1e6, 2e18, block.timestamp);
    }

    function test_listings_fee() public {
        d.listings.setFeeBps(100);
        assertEq(d.listings.feeBps(), 100);
        vm.expectRevert(SecondaryListings.InvalidFee.selector);
        d.listings.setFeeBps(201);
        vm.expectRevert(SecondaryListings.InvalidFee.selector);
        new SecondaryListings(address(this), address(d.factory), 500);
        assertTrue(d.listings.supportsInterface(0x4e2312e0)); // ERC1155Receiver
        d.listings.setFeeBps(0);
        _lockedWithNotes();
        vm.startPrank(alice);
        d.note.setApprovalForAll(address(d.listings), true);
        uint256 lid = d.listings.list(id, 1_000e6, 1e18, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        vm.prank(bob);
        d.listings.buy(lid, 1_000e6, 1e18, block.timestamp);
    }

    // ================================================================= Compliance

    function test_compliance_gatesActions() public {
        d.compliance.setEnabled(true);
        vm.expectRevert(SeriesFactory.NotAllowed.selector);
        _subscribe(alice, id, 1_000e6);
        vm.expectRevert(UnderwriterPool.NotAllowed.selector);
        _commit(uw1, id, 1e18);

        address[] memory who = new address[](3);
        who[0] = alice;
        who[1] = uw1;
        who[2] = uw2;
        d.compliance.setAllowed(who, true);
        _subscribe(alice, id, 100_000e6);
        _lock(id, _prices1(200e8));
        _claimAlloc(id, alice);

        vm.expectRevert(abi.encodeWithSelector(Note.NotAllowed.selector, bob));
        vm.prank(alice);
        d.note.safeTransferFrom(alice, bob, id, 1, "");

        vm.startPrank(alice);
        d.note.setApprovalForAll(address(d.listings), true);
        uint256 lid = d.listings.list(id, 1_000e6, 1e18, uint64(block.timestamp + 1 days));
        vm.stopPrank();
        vm.expectRevert(SecondaryListings.NotAllowed.selector);
        vm.prank(bob);
        d.listings.buy(lid, 1e6, 1e18, block.timestamp);

        d.compliance.setActionGated(d.compliance.ACTION_BUY(), false);
        d.compliance.setActionGated(d.compliance.ACTION_TRANSFER(), false);
        vm.prank(bob);
        d.listings.buy(lid, 1e6, 1e18, block.timestamp);
        assertTrue(d.compliance.isAllowed(bob, d.compliance.ACTION_BUY()));
        assertFalse(d.compliance.isAllowed(bob, d.compliance.ACTION_SUBSCRIBE()));

        vm.expectRevert(ComplianceRegistry.BatchTooLarge.selector);
        d.compliance.setAllowed(new address[](201), true);
    }

    // ================================================================= Note

    function test_note_admin() public {
        d.note.setURI("ipfs://x/{id}");
        assertEq(d.note.uri(1), "ipfs://x/{id}");
        assertTrue(d.note.supportsInterface(0xd9b67a26)); // ERC1155
        assertEq(d.note.name(), "Floorcap Principal-Protected Note");
        vm.expectRevert();
        vm.prank(alice);
        d.note.mint(alice, 1, 1);
        vm.expectRevert();
        vm.prank(alice);
        d.note.burn(alice, 1, 1);
        d.note.setCompliance(address(0));
        _lockedWithNotes();
        vm.prank(alice);
        d.note.safeTransferFrom(alice, bob, id, 5, "");
        assertEq(d.note.balanceOf(bob, id), 5);
    }

    // ================================================================= FeeCollector

    function test_feeCollector_splitsAndTreasury() public {
        _lockedWithNotes(); // 500 USDG structuring fee, hooks inactive
        assertEq(d.feeCollector.reserve(address(usdg)), 100e6);
        assertEq(d.feeCollector.treasury(address(usdg)), 400e6);
        d.feeCollector.withdrawTreasury(address(usdg), treasury, 400e6);
        assertEq(usdg.balanceOf(treasury), 400e6);
        vm.expectRevert(FeeCollector.InsufficientTreasury.selector);
        d.feeCollector.withdrawTreasury(address(usdg), treasury, 1);
        vm.expectRevert(FeeCollector.ZeroAddress.selector);
        d.feeCollector.withdrawTreasury(address(usdg), address(0), 0);
        vm.expectRevert(FeeCollector.InvalidShares.selector);
        d.feeCollector.setShares(6_000, 5_000);
        d.feeCollector.setShares(1_000, 1_000);
        assertEq(d.feeCollector.reserveShareBps(), 1_000);
        vm.expectRevert();
        d.feeCollector.recordFee(address(usdg), 1, true);
        vm.expectRevert();
        d.feeCollector.coverShortfall(address(usdg), 1);
    }

    function test_feeCollector_zeroAndEmptyReserve() public {
        vm.startPrank(address(d.settlement));
        d.feeCollector.recordFee(address(usdg), 0, true);
        assertEq(d.feeCollector.coverShortfall(address(nvda), 5), 0);
        vm.stopPrank();
    }

    // ================================================================= ProjectTokenHooks

    function test_hooks_inactiveByDefault() public {
        assertFalse(d.hooks.isActive());
        assertFalse(d.hooks.isPriority(alice, block.timestamp));
        vm.expectRevert(ProjectTokenHooks.Inactive.selector);
        vm.prank(alice);
        d.hooks.stake(1);
        assertEq(d.hooks.rewardToken(), address(usdg));
    }

    function test_hooks_setProjectTokenOnce() public {
        vm.expectRevert(ProjectTokenHooks.ZeroAddress.selector);
        d.hooks.setProjectToken(address(0));
        vm.expectRevert(ProjectTokenHooks.ZeroAddress.selector);
        d.hooks.setProjectToken(address(usdg));
        vm.prank(alice);
        vm.expectRevert();
        d.hooks.setProjectToken(address(fcap));
        d.hooks.setProjectToken(address(fcap));
        assertTrue(d.hooks.isActive());
        vm.expectRevert(ProjectTokenHooks.AlreadySet.selector);
        d.hooks.setProjectToken(address(nvda));
    }

    function test_hooks_stakingRewardsAndFeeShare() public {
        d.hooks.setProjectToken(address(fcap));
        fcap.mint(bob, 10_000e18);
        fcap.mint(carol, 10_000e18);
        vm.prank(bob);
        fcap.approve(address(d.hooks), type(uint256).max);
        vm.prank(carol);
        fcap.approve(address(d.hooks), type(uint256).max);
        vm.prank(bob);
        d.hooks.stake(3_000e18);
        vm.prank(carol);
        d.hooks.stake(1_000e18);
        assertEq(d.hooks.totalStaked(), 4_000e18);

        _lockedWithNotes(); // 500 USDG fee: 100 reserve, 150 stakers, 250 treasury
        assertEq(d.feeCollector.reserve(address(usdg)), 100e6);
        assertEq(d.feeCollector.treasury(address(usdg)), 250e6);
        assertEq(usdg.balanceOf(address(d.hooks)), 150e6);
        assertEq(d.hooks.earned(bob), 112.5e6);
        assertEq(d.hooks.earned(carol), 37.5e6);

        uint256 b0 = usdg.balanceOf(bob);
        vm.prank(bob);
        d.hooks.claimRewards();
        assertEq(usdg.balanceOf(bob) - b0, 112.5e6);
        vm.prank(bob);
        assertEq(d.hooks.claimRewards(), 0);

        vm.prank(carol);
        d.hooks.requestUnstake(1_000e18);
        assertFalse(d.hooks.isPriority(carol, block.timestamp));
        vm.expectRevert(ProjectTokenHooks.CooldownActive.selector);
        vm.prank(carol);
        d.hooks.withdraw();
        vm.warp(block.timestamp + 7 days);
        vm.prank(carol);
        d.hooks.withdraw();
        assertEq(fcap.balanceOf(carol), 10_000e18);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        vm.prank(carol);
        d.hooks.withdraw();
        vm.prank(carol);
        d.hooks.claimRewards();
        assertEq(usdg.balanceOf(carol), 10_000_000e6 + 37.5e6);
    }

    function test_hooks_reverts() public {
        d.hooks.setProjectToken(address(fcap));
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        d.hooks.stake(0);
        vm.expectRevert(ProjectTokenHooks.ZeroAmount.selector);
        d.hooks.requestUnstake(0);
        vm.expectRevert(ProjectTokenHooks.InsufficientStake.selector);
        d.hooks.requestUnstake(1);
        d.hooks.grantRole(d.hooks.NOTIFIER_ROLE(), address(this));
        vm.expectRevert(ProjectTokenHooks.NoStakers.selector);
        d.hooks.notifyReward(1);
        d.hooks.setParams(0, 1 days);
        assertEq(d.hooks.unstakeCooldown(), 1 days);
        vm.expectRevert(ProjectTokenHooks.InvalidParams.selector);
        d.hooks.setParams(0, 31 days);
        vm.expectRevert(ProjectTokenHooks.InvalidParams.selector);
        new ProjectTokenHooks(address(this), address(usdg), 0, 31 days);
        vm.expectRevert(ProjectTokenHooks.ZeroAddress.selector);
        new ProjectTokenHooks(address(this), address(0), 0, 1 days);
        d.hooks.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        d.hooks.stake(1);
        d.hooks.unpause();
    }

    // ================================================================= Yield adapters

    function test_yieldAdapter_accessAndFractions() public {
        vm.expectRevert();
        d.holdAdapter.deposit(1, 1);
        vm.startPrank(address(d.factory));
        vm.expectRevert(YieldAdapter.ZeroAmount.selector);
        d.holdAdapter.deposit(1, 0);
        vm.expectRevert(YieldAdapter.InvalidFraction.selector);
        d.holdAdapter.withdrawShare(1, 2, 1, alice);
        vm.expectRevert(YieldAdapter.InvalidFraction.selector);
        d.holdAdapter.withdrawShare(1, 0, 0, alice);
        assertEq(d.holdAdapter.withdrawShare(1, 1, 1, alice), 0);
        vm.stopPrank();
        d.holdAdapter.setReferenceApyBps(0);
        d.vaultAdapter.setReferenceApyBps(420);
        assertEq(d.vaultAdapter.referenceApyBps(), 420);
        assertEq(d.vaultAdapter.asset(), address(usdg));
        assertEq(d.vaultAdapter.totalAssets(42), 0);
    }

    function test_vaultAdapter_depositLossGuard() public {
        vm.expectRevert(ERC4626YieldAdapter.InvalidBps.selector);
        d.vaultAdapter.setMaxDepositLossBps(101);
        vm.expectRevert(ERC4626YieldAdapter.InvalidBps.selector);
        new ERC4626YieldAdapter(address(vault), address(this), 101);
        d.vaultAdapter.setMaxDepositLossBps(0);
        assertEq(d.vaultAdapter.maxDepositLossBps(), 0);
        usdg.mint(address(d.factory), 1_000e6);
        vm.startPrank(address(d.factory));
        usdg.approve(address(d.vaultAdapter), type(uint256).max);
        d.vaultAdapter.deposit(7, 1_000e6);
        vm.stopPrank();
        assertApproxEqAbs(d.vaultAdapter.totalAssets(7), 1_000e6, 1);
    }

    // ================================================================= Factory admin & validation

    function test_factory_validations() public {
        ISeriesFactory.SeriesParams memory p = _params(9_500, 12, address(d.holdAdapter), 0);
        _expectInvalid(_with(p, 0), "stable");
        _expectInvalid(_with(p, 1), "yieldAdapter");
        _expectInvalid(_with(p, 2), "optionsAdapter");
        _expectInvalid(_with(p, 3), "basket");
        _expectInvalid(_with(p, 4), "token");
        _expectInvalid(_with(p, 5), "duplicate");
        _expectInvalid(_with(p, 6), "protection");
        _expectInvalid(_with(p, 7), "tenor");
        _expectInvalid(_with(p, 8), "window");
        _expectInvalid(_with(p, 9), "notClose");
        _expectInvalid(_with(p, 10), "yield");
        _expectInvalid(_with(p, 11), "fee");
        _expectInvalid(_with(p, 12), "exitFee");
        _expectInvalid(_with(p, 13), "premium");
        _expectInvalid(_with(p, 14), "size");
        _expectInvalid(_with(p, 15), "participation");
        _expectInvalid(_with(p, 16), "asset");
        vm.prank(alice);
        vm.expectRevert();
        d.factory.createSeries(p);
        d.factory.createSeries(_with(p, 17)); // 6-month tenor OK
    }

    function _expectInvalid(ISeriesFactory.SeriesParams memory p, string memory reason) internal {
        vm.expectRevert(abi.encodeWithSelector(SeriesFactory.InvalidParams.selector, reason));
        d.factory.createSeries(p);
    }

    function _with(ISeriesFactory.SeriesParams memory base, uint256 k)
        internal
        returns (ISeriesFactory.SeriesParams memory p)
    {
        p = _params(9_500, 12, address(d.holdAdapter), 0);
        if (k == 0) p.stable = address(nvda);
        if (k == 1) p.yieldAdapter = address(0xdead);
        if (k == 2) p.optionsAdapter = address(0xdead);
        if (k == 3) p.tokens = new address[](0);
        if (k == 4) {
            p.tokens[0] = address(fcap);
        }
        if (k == 5) {
            address[] memory t = new address[](2);
            t[0] = address(aapl);
            t[1] = address(aapl);
            uint256[] memory q = new uint256[](2);
            q[0] = 1;
            q[1] = 1;
            p.tokens = t;
            p.quantities = q;
        }
        if (k == 6) p.protectionBps = 9_000;
        if (k == 7) p.tenorMonths = 9;
        if (k == 8) p.subscriptionEnd = p.subscriptionStart;
        if (k == 9) p.subscriptionEnd = p.subscriptionEnd + 1;
        if (k == 10) p.assumedYieldBps = 1_001;
        if (k == 11) p.structuringFeeBps = 201;
        if (k == 12) p.exitFeeBps = 501;
        if (k == 13) p.premiumBps = 0;
        if (k == 14) p.minSize = 0;
        if (k == 15) p.premiumBps = 100; // participation 4.5x > 3x max
        if (k == 16) {
            MockERC20 other = new MockERC20("X", "X", 6);
            d.factory.setAllowed(0, address(other), true);
            p.stable = address(other);
        }
        if (k == 17) p.tenorMonths = 6;
        base; // silence
    }

    function test_factory_admin() public {
        d.factory.setLimits(1_500, 300, 600, 5e18, 2 days);
        assertEq(d.factory.lockWindow(), 2 days);
        vm.expectRevert(abi.encodeWithSelector(SeriesFactory.InvalidParams.selector, "limits"));
        d.factory.setLimits(2_001, 300, 600, 5e18, 2 days);
        vm.expectRevert(abi.encodeWithSelector(SeriesFactory.InvalidParams.selector, "lockWindow"));
        d.factory.setLimits(1_000, 300, 600, 5e18, 1 hours);
        vm.expectRevert(abi.encodeWithSelector(SeriesFactory.InvalidParams.selector, "kind"));
        d.factory.setAllowed(3, address(1), true);
        vm.expectRevert(SeriesFactory.ZeroAddress.selector);
        d.factory.setWiring(address(0), address(1), address(1), address(1), address(0), address(0));
        vm.expectRevert();
        vm.prank(alice);
        d.factory.reduceLive(id, 1);
        vm.expectRevert();
        vm.prank(alice);
        d.factory.markSettled(id);
        assertEq(d.factory.seriesName(id), "AAPL 12M 95%");
        (address[] memory t,) = d.factory.getBasket(id);
        assertEq(t[0], address(aapl));
        _pushAt(id, block.timestamp, _prices1(210e8));
        assertEq(d.factory.basketLevelLatest(id), 210e18);
    }

    // ================================================================= Governance & handover

    function test_timelock_minDelay() public {
        address[] memory a = new address[](1);
        a[0] = address(this);
        vm.expectRevert(Timelock.DelayTooShort.selector);
        new Timelock(1 days, a, a);
        Timelock t = new Timelock(48 hours, a, a);
        assertEq(t.getMinDelay(), 48 hours);
    }

    function test_handover_removesDeployerAdmin() public {
        address guardian = makeAddr("guardian");
        address curator = makeAddr("curator");
        Timelock t = _deployTimelock(d, 48 hours, address(this), address(0));
        d.timelock = t; // storage copy (helper sets it on a memory copy)
        _handover(d, Roles({guardian: guardian, curator: curator, complianceOperator: guardian}), address(this));
        bytes32 admin = 0x00;
        assertTrue(d.factory.hasRole(admin, address(t)));
        assertFalse(d.factory.hasRole(admin, address(this)));
        assertFalse(d.oracle.hasRole(admin, address(this)));
        assertFalse(d.oracle.hasRole(d.oracle.FEED_ADMIN_ROLE(), address(this)));
        assertFalse(d.clock.hasRole(d.clock.CALENDAR_ROLE(), address(this)));
        assertFalse(d.hooks.hasRole(admin, address(this)));
        assertTrue(d.factory.hasRole(d.factory.CURATOR_ROLE(), curator));
        assertTrue(d.settlement.hasRole(d.settlement.GUARDIAN_ROLE(), guardian));
        assertTrue(d.compliance.hasRole(d.compliance.COMPLIANCE_ROLE(), guardian));

        // setProjectToken now only through the Timelock with a 48h delay
        vm.expectRevert();
        d.hooks.setProjectToken(address(fcap));
        bytes memory data = abi.encodeCall(d.hooks.setProjectToken, (address(fcap)));
        t.schedule(address(d.hooks), 0, data, bytes32(0), bytes32(0), 48 hours);
        vm.expectRevert();
        t.execute(address(d.hooks), 0, data, bytes32(0), bytes32(0));
        vm.warp(block.timestamp + 48 hours);
        t.execute(address(d.hooks), 0, data, bytes32(0), bytes32(0));
        assertTrue(d.hooks.isActive());
    }
}
