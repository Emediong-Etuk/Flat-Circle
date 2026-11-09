// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {FlatCircle} from "../src/FlatCircle.sol";
import {FlatCircleFactory} from "../src/FlatCircleFactory.sol";
import {CircleParams, IFlatCircleEvents, IFlatCircleFactory, OrderMode, State} from "../src/IFlatCircle.sol";

/// @notice Tests 7-9: leave/cancel/claim, allowlist, Flat Score tiers, param bounds, factory hooks.
contract OpenPhaseTest is Base {
    // ------------------------------------------------------------------ Test 7: leave / cancel / claim

    function test_leave_refundsDirectly_andKeepsJoinOrder() public {
        FlatCircle c = _create(_params(4, OrderMode.JoinOrder, true));
        _join(c, alice);
        _join(c, bob);
        _join(c, carol);
        uint256 u = usdg.balanceOf(bob);
        uint256 w = wif.balanceOf(bob);
        vm.expectEmit(address(c));
        emit IFlatCircleEvents.Left(bob, BOND, C);
        vm.prank(bob);
        c.leave();
        assertEq(usdg.balanceOf(bob), u + C);
        assertEq(wif.balanceOf(bob), w + BOND);
        assertFalse(c.isMember(bob));
        address[] memory m = c.membersList();
        assertEq(m.length, 2);
        assertEq(m[0], alice);
        assertEq(m[1], carol);
        assertEq(factory.getStats().totalWifRefunded, BOND);

        vm.prank(bob);
        vm.expectRevert(IFlatCircleEvents.NotMember.selector);
        c.leave();

        // bob can rejoin; the circle fills in join order alice, carol, dave, bob
        _join(c, dave);
        vm.prank(bob);
        c.join();
        address[] memory o = c.orderList();
        assertEq(o[0], alice);
        assertEq(o[1], carol);
        assertEq(o[2], dave);
        assertEq(o[3], bob);
        assertEq(factory.circlesOfMember(bob).length, 1, "no duplicate listing");
    }

    function test_creatorCancel_anyTime_thenClaim() public {
        FlatCircle c = _create(_params(3, OrderMode.JoinOrder, true));
        _join(c, bob);
        _join(c, carol);
        vm.prank(bob);
        vm.expectRevert(IFlatCircleEvents.JoinWindowOpen.selector);
        c.cancel();

        vm.expectEmit(address(c));
        emit IFlatCircleEvents.Cancelled(alice);
        vm.prank(alice);
        c.cancel();
        assertEq(uint8(c.state()), uint8(State.Cancelled));
        assertEq(_info(c, bob).claimableUsdg, C);
        assertEq(_info(c, bob).claimableWif, BOND);

        uint256 u = usdg.balanceOf(bob);
        vm.expectEmit(address(c));
        emit IFlatCircleEvents.Claimed(bob, C, BOND);
        vm.prank(bob);
        c.claim();
        assertEq(usdg.balanceOf(bob), u + C);
        assertEq(wif.balanceOf(bob), START_WIF);

        vm.prank(alice);
        vm.expectRevert(IFlatCircleEvents.NotOpen.selector);
        c.cancel();
        _approve(c, dave);
        vm.prank(dave);
        vm.expectRevert(IFlatCircleEvents.NotOpen.selector);
        c.join();
        vm.prank(carol);
        vm.expectRevert(IFlatCircleEvents.NotOpen.selector);
        c.leave();
    }

    function test_anyoneCancel_afterJoinWindow_thenClaim() public {
        FlatCircle c = _create(_params(3, OrderMode.JoinOrder, false));
        _join(c, bob);
        vm.warp(c.joinDeadline());
        _approve(c, carol);
        vm.prank(carol);
        vm.expectRevert(IFlatCircleEvents.JoinWindowClosed.selector);
        c.join();
        vm.prank(erin);
        c.cancel();
        vm.prank(bob);
        c.claim();
        assertEq(wif.balanceOf(bob), START_WIF);
        assertEq(wif.balanceOf(address(c)), 0);
    }

    function test_join_alreadyMember() public {
        FlatCircle c = _create(_params(3, OrderMode.JoinOrder, true));
        _join(c, bob);
        vm.prank(bob);
        vm.expectRevert(IFlatCircleEvents.AlreadyMember.selector);
        c.join();
    }

    function test_join_withoutApproval_reverts() public {
        FlatCircle c = _create(_params(3, OrderMode.JoinOrder, true));
        vm.prank(bob);
        vm.expectRevert();
        c.join();
    }

    // ------------------------------------------------------------------ Test 8: allowlist / tiers / bounds

    function test_allowlist_enforced() public {
        CircleParams memory p = _params(2, OrderMode.JoinOrder, true);
        p.allowlist = new address[](3);
        p.allowlist[0] = bob;
        p.allowlist[1] = carol;
        p.allowlist[2] = dave;
        FlatCircle c = _create(p);
        assertTrue(c.hasAllowlist());
        assertEq(c.allowlist().length, 3);
        _approve(c, erin);
        vm.prank(erin);
        vm.expectRevert(IFlatCircleEvents.NotAllowed.selector);
        c.join();
        _approve(c, alice); // creator isn't on the list either
        vm.prank(alice);
        vm.expectRevert(IFlatCircleEvents.NotAllowed.selector);
        c.join();
        _join(c, bob);
        _join(c, dave);
        assertEq(uint8(c.state()), uint8(State.Active));
    }

    function _completeCleanCircle(address u) internal {
        // u plus one helper complete a 2-member circle cleanly
        FlatCircle c = _create(_params(2, OrderMode.JoinOrder, false));
        _join(c, u);
        _join(c, users[19]);
        _roundAllPay(c);
        _roundAllPay(c);
        vm.prank(u);
        c.claim();
    }

    function test_bondTiers() public {
        assertEq(factory.tierOf(bob), 0);
        assertEq(factory.bondFor(bob, BOND), BOND);
        _completeCleanCircle(bob);
        assertEq(factory.tierOf(bob), 1);
        assertEq(factory.bondFor(bob, BOND), (BOND * 80) / 100);
        _completeCleanCircle(bob);
        assertEq(factory.tierOf(bob), 2);
        assertEq(factory.bondFor(bob, BOND), (BOND * 60) / 100);
        _completeCleanCircle(bob);
        assertEq(factory.tierOf(bob), 3);
        assertEq(factory.bondFor(bob, BOND), (BOND * 40) / 100);
        _completeCleanCircle(bob);
        assertEq(factory.tierOf(bob), 3, "Pillar caps at 3+");

        // The discounted bond is what join() actually locks.
        FlatCircle c = _create(_params(2, OrderMode.JoinOrder, false));
        uint256 before = wif.balanceOf(bob);
        _join(c, bob);
        assertEq(before - wif.balanceOf(bob), (BOND * 40) / 100);
        assertEq(_info(c, bob).bond, (BOND * 40) / 100);

        // One default flags you, whatever your history.
        _join(c, carol);
        vm.warp(c.roundEndsAt());
        _pay(c, carol);
        c.closeRound(); // bob misses
        assertEq(factory.tierOf(bob), 4);
        assertEq(factory.bondFor(bob, BOND), 2 * BOND);
        assertEq(factory.bondMultiplier(4), 200);
    }

    function test_bondFor_neverZero() public view {
        assertEq(factory.bondFor(bob, 1), 1);
    }

    function _expectInvalid(CircleParams memory p) internal {
        vm.expectRevert(IFlatCircleFactory.InvalidParams.selector);
        factory.createCircle(p);
    }

    function test_paramBounds() public {
        CircleParams memory p;

        p = _params(3, OrderMode.JoinOrder, true);
        p.name = "";
        _expectInvalid(p);
        p.name = "012345678901234567890123456789012345678901234567"; // 48 bytes ok
        factory.createCircle(p);
        p.name = "0123456789012345678901234567890123456789012345678"; // 49
        _expectInvalid(p);

        p = _params(3, OrderMode.JoinOrder, true);
        p.contribution = 0;
        _expectInvalid(p);
        p.contribution = factory.maxContribution();
        factory.createCircle(p);
        p.contribution = factory.maxContribution() + 1;
        _expectInvalid(p);
        assertEq(factory.maxContribution(), 10_000 * 10 ** usdgDecimals());

        p = _params(3, OrderMode.JoinOrder, true);
        p.roundDuration = 59;
        _expectInvalid(p);
        p.roundDuration = 60;
        factory.createCircle(p);
        p.roundDuration = 31 days + 1;
        _expectInvalid(p);

        p = _params(1, OrderMode.JoinOrder, true);
        _expectInvalid(p);
        p.maxMembers = 21;
        _expectInvalid(p);
        p.maxMembers = 20;
        factory.createCircle(p);

        p = _params(3, OrderMode.JoinOrder, true);
        p.baseBond = 0;
        _expectInvalid(p);
        p.baseBond = uint256(type(uint128).max) + 1;
        _expectInvalid(p);
        p.baseBond = BOND;
        p.swapFee = uint256(type(uint128).max) + 1;
        _expectInvalid(p);

        p = _params(3, OrderMode.JoinOrder, true);
        p.joinWindow = 10 minutes - 1;
        _expectInvalid(p);
        p.joinWindow = 14 days + 1;
        _expectInvalid(p);

        p = _params(3, OrderMode.JoinOrder, true);
        p.allowlist = new address[](2); // fewer than maxMembers
        p.allowlist[0] = bob;
        p.allowlist[1] = carol;
        _expectInvalid(p);
        p.allowlist = new address[](21);
        _expectInvalid(p);
        p.allowlist = new address[](3);
        p.allowlist[0] = bob;
        p.allowlist[1] = carol; // [2] is zero
        _expectInvalid(p);
    }

    function test_factoryConstructor_rejectsZero() public {
        vm.expectRevert(IFlatCircleFactory.InvalidParams.selector);
        new FlatCircleFactory(address(0), address(wif), BURN);
    }

    // ------------------------------------------------------------------ Test 9: hooks are circle-only

    function test_hooks_rejectNonCircles() public {
        address[] memory none = new address[](0);
        vm.startPrank(erin);
        vm.expectRevert(IFlatCircleFactory.NotCircle.selector);
        factory.onJoined(erin, 1);
        vm.expectRevert(IFlatCircleFactory.NotCircle.selector);
        factory.onBondBurned(erin, 1);
        vm.expectRevert(IFlatCircleFactory.NotCircle.selector);
        factory.onSwapFeeBurned(1);
        vm.expectRevert(IFlatCircleFactory.NotCircle.selector);
        factory.onPayout(1);
        vm.expectRevert(IFlatCircleFactory.NotCircle.selector);
        factory.onRefund(1);
        vm.expectRevert(IFlatCircleFactory.NotCircle.selector);
        factory.onCompleted(none);
        vm.stopPrank();
    }

    function test_hooks_rejectCirclesFromOtherFactories() public {
        FlatCircleFactory other = new FlatCircleFactory(address(usdg), address(wif), BURN);
        vm.prank(alice);
        address foreign = other.createCircle(_params(2, OrderMode.JoinOrder, true));
        vm.prank(foreign);
        vm.expectRevert(IFlatCircleFactory.NotCircle.selector);
        factory.onBondBurned(bob, 1);
    }

    function test_factoryViews() public {
        assertEq(factory.circleCount(), 0);
        address a = address(_create(_params(2, OrderMode.JoinOrder, true)));
        address b = address(_create(_params(3, OrderMode.FairDraw, false)));
        address d = address(_create(_params(4, OrderMode.JoinOrder, true)));
        assertEq(factory.circleCount(), 3);
        assertTrue(factory.isCircle(a));
        address[] memory page = factory.circlesPage(1, 5);
        assertEq(page.length, 2);
        assertEq(page[0], b);
        assertEq(page[1], d);
        assertEq(factory.circlesPage(3, 5).length, 0);
        assertEq(factory.circlesPage(0, 1)[0], a);
        assertEq(factory.usdgDecimals(), usdgDecimals());
        assertEq(factory.getStats().totalCircles, 3);
    }
}
