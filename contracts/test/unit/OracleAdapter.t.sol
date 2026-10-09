// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {OracleAdapter} from "../../src/OracleAdapter.sol";
import {MockAggregator, MockSequencer} from "../mocks/Mocks.sol";

contract OracleAdapterTest is Test {
    OracleAdapter oracle;
    MockAggregator p;
    MockAggregator s;
    address token = address(0xA11);

    function setUp() public {
        vm.warp(1_800_000_000);
        oracle = new OracleAdapter(address(this));
        p = new MockAggregator(8);
        s = new MockAggregator(8);
        oracle.setFeed(token, address(p), address(s), 1 days, 100);
    }

    function test_latestPrice() public {
        p.push(250e8);
        s.push(251e8);
        (uint256 px, uint256 upd) = oracle.latestPrice(token);
        assertEq(px, 250e18);
        assertEq(upd, block.timestamp);
        assertTrue(oracle.hasFeed(token));
        assertFalse(oracle.hasFeed(address(1)));
        assertEq(address(oracle.feedOf(token).primary), address(p));
    }

    function test_latestPrice_deviation() public {
        p.push(250e8);
        s.push(260e8);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.PriceDeviation.selector, token, 250e18, 260e18));
        oracle.latestPrice(token);
    }

    function test_latestPrice_stale() public {
        p.push(250e8);
        s.push(250e8);
        vm.warp(block.timestamp + 1 days + 1);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.StalePrice.selector, address(p), block.timestamp - 1 days - 1));
        oracle.latestPrice(token);
    }

    function test_latestPrice_invalid() public {
        p.push(0);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidPrice.selector, address(p)));
        oracle.latestPrice(token);
        p.push(-1);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.InvalidPrice.selector, address(p)));
        oracle.latestPrice(token);
    }

    function test_noFeed() public {
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.NoFeed.selector, address(1)));
        oracle.latestPrice(address(1));
    }

    function test_decimalsScaling() public {
        MockAggregator f18 = new MockAggregator(18);
        MockAggregator f20 = new MockAggregator(20);
        oracle.setFeed(address(18), address(f18), address(0), 1 days, 0);
        oracle.setFeed(address(20), address(f20), address(0), 1 days, 0);
        f18.push(5e18);
        f20.push(5e20);
        (uint256 a,) = oracle.latestPrice(address(18));
        (uint256 b,) = oracle.latestPrice(address(20));
        assertEq(a, 5e18);
        assertEq(b, 5e18);
    }

    function test_priceAt_proofOfRound() public {
        uint256 t0 = block.timestamp;
        uint80 r1 = p.pushAt(100e8, t0);
        uint80 q1 = s.pushAt(100e8, t0);
        p.pushAt(110e8, t0 + 100);
        s.pushAt(110e8, t0 + 100);
        vm.warp(t0 + 200);
        assertEq(oracle.priceAt(token, t0 + 50, r1, q1), 100e18);
        assertEq(oracle.priceAt(token, t0 + 99, r1, q1), 100e18);
        // a later round cannot be used for an earlier timestamp
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.BadHint.selector, address(p), r1 + 1));
        oracle.priceAt(token, t0 + 50, r1 + 1, q1 + 1);
        // an outdated round cannot be used once a newer one existed
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.BadHint.selector, address(p), r1));
        oracle.priceAt(token, t0 + 150, r1, q1);
        // latest round valid for later timestamps
        assertEq(oracle.priceAt(token, t0 + 150, r1 + 1, q1 + 1), 110e18);
        // missing round
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.BadHint.selector, address(p), r1 + 5));
        oracle.priceAt(token, t0 + 150, r1 + 5, q1);
        vm.expectRevert(OracleAdapter.FutureTimestamp.selector);
        oracle.priceAt(token, block.timestamp + 1, r1, q1);
    }

    function test_priceAt_missingRoundReturnsZeros() public {
        p.setRevertOnMissing(false);
        s.setRevertOnMissing(false);
        uint256 t0 = block.timestamp;
        uint80 r1 = p.pushAt(100e8, t0);
        uint80 q1 = s.pushAt(100e8, t0);
        vm.warp(t0 + 10);
        assertEq(oracle.priceAt(token, t0 + 5, r1, q1), 100e18);
    }

    function test_priceAt_phaseChange() public {
        uint256 t0 = block.timestamp;
        uint80 r1 = p.pushAt(100e8, t0);
        uint80 q1 = s.pushAt(100e8, t0);
        p.newPhase();
        s.newPhase();
        p.pushAt(120e8, t0 + 100);
        s.pushAt(120e8, t0 + 100);
        vm.warp(t0 + 200);
        assertEq(oracle.priceAt(token, t0 + 50, r1, q1), 100e18);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.BadHint.selector, address(p), r1));
        oracle.priceAt(token, t0 + 150, r1, q1);
    }

    function test_priceAt_phaseChangeWithoutNewRound() public {
        uint256 t0 = block.timestamp;
        uint80 r1 = p.pushAt(100e8, t0);
        uint80 q1 = s.pushAt(100e8, t0);
        p.pushAt(101e8, t0 + 10);
        p.newPhase(); // new phase with no rounds yet: latest still points at the old phase
        vm.warp(t0 + 200);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.BadHint.selector, address(p), r1));
        oracle.priceAt(token, t0 + 50, r1, q1);
    }

    function test_priceAt_staleRound() public {
        uint256 t0 = block.timestamp;
        uint80 r1 = p.pushAt(100e8, t0);
        uint80 q1 = s.pushAt(100e8, t0);
        vm.warp(t0 + 3 days);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.StalePrice.selector, address(p), t0));
        oracle.priceAt(token, t0 + 2 days, r1, q1);
    }

    function test_sequencer() public {
        MockSequencer seq = new MockSequencer();
        oracle.setSequencerFeed(address(seq), 1 hours);
        p.push(100e8);
        s.push(100e8);
        seq.set(1, block.timestamp - 2 hours);
        vm.expectRevert(OracleAdapter.SequencerDown.selector);
        oracle.latestPrice(token);
        seq.set(0, block.timestamp - 10 minutes);
        vm.expectRevert(OracleAdapter.SequencerGracePeriod.selector);
        oracle.latestPrice(token);
        seq.set(0, block.timestamp - 2 hours);
        (uint256 px,) = oracle.latestPrice(token);
        assertEq(px, 100e18);
        assertEq(oracle.sequencerGracePeriod(), 1 hours);
    }

    function test_setFeed_invalid() public {
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        oracle.setFeed(address(0), address(p), address(0), 1, 0);
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        oracle.setFeed(token, address(0), address(0), 1, 0);
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        oracle.setFeed(token, address(p), address(0), 0, 0);
        vm.expectRevert(OracleAdapter.InvalidConfig.selector);
        oracle.setFeed(token, address(p), address(0), 1, 10_001);
        vm.prank(address(0xBAD));
        vm.expectRevert();
        oracle.setFeed(token, address(p), address(0), 1, 0);
    }
}
