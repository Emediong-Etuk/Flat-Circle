// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {FlatCircle} from "../src/FlatCircle.sol";
import {CircleSummary, IFlatCircleEvents, OrderMode, State, Stats} from "../src/IFlatCircle.sol";

/// @notice Test 1: full happy path in JoinOrder with exact balances at every step.
abstract contract LifecycleTest is Base {
    function _assertBalances(FlatCircle c, int256 da, int256 db, int256 dc, uint256 circleUsdg)
        internal
        view
    {
        uint256 s = _usdgStart();
        assertEq(int256(usdg.balanceOf(alice)), int256(s) + da, "alice usdg");
        assertEq(int256(usdg.balanceOf(bob)), int256(s) + db, "bob usdg");
        assertEq(int256(usdg.balanceOf(carol)), int256(s) + dc, "carol usdg");
        assertEq(usdg.balanceOf(address(c)), circleUsdg, "circle usdg");
    }

    function test_happyPath_joinOrder_exactBalances() public {
        FlatCircle c = _create(_params(3, OrderMode.JoinOrder, true));
        int256 ci = int256(C);

        _join(c, alice);
        _join(c, bob);
        assertEq(uint8(c.state()), uint8(State.Open));
        _join(c, carol);
        assertEq(uint8(c.state()), uint8(State.Active));
        assertEq(c.roundEndsAt(), block.timestamp + ROUND);
        _assertBalances(c, -ci, -ci, -ci, 3 * C);
        assertEq(wif.balanceOf(address(c)), 3 * BOND);
        assertEq(wif.balanceOf(alice), START_WIF - BOND);

        address[] memory order = c.orderList();
        assertEq(order[0], alice);
        assertEq(order[1], bob);
        assertEq(order[2], carol);

        // Round 0: alice receives.
        _pay(c, alice);
        _pay(c, bob);
        assertEq(c.summary().potSoFar, 2 * C);
        vm.expectEmit(address(c));
        emit IFlatCircleEvents.RoundClosed(0, alice, 3 * C, 0);
        _pay(c, carol);
        assertEq(c.currentRound(), 1);
        _assertBalances(c, ci, -2 * ci, -2 * ci, 3 * C);
        assertTrue(_info(c, alice).received);

        // Round 1: bob receives. Paying late (after the deadline) still counts.
        vm.warp(c.roundEndsAt() + 10);
        _roundAllPay(c);
        _assertBalances(c, 0, 0, -3 * ci, 3 * C);

        // Round 2: carol receives and the circle completes.
        _roundAllPay(c);
        assertEq(uint8(c.state()), uint8(State.Completed));
        _assertBalances(c, -ci, -ci, -ci, 3 * C);
        assertEq(_info(c, alice).claimableUsdg, C);
        assertEq(_info(c, alice).claimableWif, BOND);

        // Everyone claims deposit + bond and ends exactly where they started.
        vm.prank(alice);
        c.claim();
        vm.prank(bob);
        c.claim();
        vm.prank(carol);
        c.claim();
        _assertBalances(c, 0, 0, 0, 0);
        assertEq(wif.balanceOf(address(c)), 0);
        assertEq(wif.balanceOf(alice), START_WIF);
        assertEq(wif.balanceOf(BURN), 0);

        vm.prank(alice);
        vm.expectRevert(IFlatCircleEvents.NothingToClaim.selector);
        c.claim();

        // Flat Score and stats.
        (uint32 completed, uint32 defaults) = factory.score(alice);
        assertEq(completed, 1);
        assertEq(defaults, 0);
        assertEq(factory.tierOf(alice), 1);
        Stats memory st = factory.getStats();
        assertEq(st.totalCircles, 1);
        assertEq(st.completedCircles, 1);
        assertEq(st.totalMembersJoined, 3);
        assertEq(st.totalUsdgPaidOut, 9 * C);
        assertEq(st.totalWifBonded, 3 * BOND);
        assertEq(st.totalWifBurned, 0);
        assertEq(st.totalWifRefunded, 3 * BOND);
    }

    function test_happyPath_noDeposit() public {
        FlatCircle c = _activeCircle(3, false);
        assertEq(usdg.balanceOf(address(c)), 0);
        _roundAllPay(c);
        _roundAllPay(c);
        _roundAllPay(c);
        assertEq(uint8(c.state()), uint8(State.Completed));
        assertEq(usdg.balanceOf(address(c)), 0);
        assertEq(usdg.balanceOf(alice), _usdgStart());
        assertEq(_info(c, alice).claimableUsdg, 0);
        assertEq(_info(c, alice).claimableWif, BOND);
    }

    function test_summaryAndViews() public {
        FlatCircle c = _create(_params(3, OrderMode.JoinOrder, true));
        _join(c, alice);
        CircleSummary memory s = c.summary();
        assertEq(uint8(s.state), uint8(State.Open));
        assertEq(s.name, "Market Circle");
        assertEq(s.contribution, C);
        assertEq(s.maxMembers, 3);
        assertEq(s.memberCount, 1);
        assertEq(s.creator, alice);
        assertEq(s.factory, address(factory));
        assertEq(s.createdAtBlock, 1_000);
        assertEq(s.joinDeadline, block.timestamp + WINDOW);
        assertEq(s.l2BlockNumber, 1_000);
        assertFalse(s.hasAllowlist);
        assertTrue(c.isMember(alice));
        assertFalse(c.isMember(bob));
        assertEq(c.membersInfo().length, 1);
        assertEq(c.membersInfo()[0].account, alice);
        assertEq(c.membersInfo()[0].bond, BOND);
        assertEq(c.allowlist().length, 0);
    }

    function test_contribute_revertsWhenNotAllowed() public {
        FlatCircle c = _create(_params(3, OrderMode.JoinOrder, true));
        _join(c, alice);
        vm.prank(alice);
        vm.expectRevert(IFlatCircleEvents.NotActive.selector);
        c.contribute();

        _join(c, bob);
        _join(c, carol);
        vm.prank(dave);
        vm.expectRevert(IFlatCircleEvents.NotMember.selector);
        c.contribute();

        _pay(c, alice);
        vm.prank(alice);
        vm.expectRevert(IFlatCircleEvents.AlreadyPaid.selector);
        c.contribute();

        vm.expectRevert(IFlatCircleEvents.RoundNotOver.selector);
        c.closeRound();

        // Joining a running circle reads as "full".
        _approve(c, dave);
        vm.prank(dave);
        vm.expectRevert(IFlatCircleEvents.Full.selector);
        c.join();
    }

    function test_twentyMembers_fullLifecycle() public {
        FlatCircle c = _create(_params(20, OrderMode.JoinOrder, true));
        _joinFirst(c, 20);
        for (uint256 r; r < 20; ++r) {
            _roundAllPay(c);
        }
        assertEq(uint8(c.state()), uint8(State.Completed));
        assertEq(usdg.balanceOf(address(c)), 20 * C);
        for (uint256 i; i < 20; ++i) {
            vm.prank(users[i]);
            c.claim();
            assertEq(usdg.balanceOf(users[i]), _usdgStart());
        }
        assertEq(usdg.balanceOf(address(c)), 0);
    }
}

contract Lifecycle6Test is LifecycleTest {}

contract Lifecycle18Test is LifecycleTest {
    function usdgDecimals() internal pure override returns (uint8) {
        return 18;
    }
}
