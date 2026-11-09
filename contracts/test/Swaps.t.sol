// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {FlatCircle} from "../src/FlatCircle.sol";
import {CircleParams, IFlatCircleEvents, OrderMode, State} from "../src/IFlatCircle.sol";

/// @notice Test 6: swap requests, fee escrow, refunds, burns and eligibility.
contract SwapsTest is Base {
    FlatCircle internal c; // order: alice(0), bob(1), carol(2), dave(3)

    function setUp() public override {
        super.setUp();
        c = _activeCircle(4, true);
    }

    function _request(address from, address to) internal {
        vm.prank(from);
        c.requestSwap(to);
    }

    function test_request_escrowsFee() public {
        uint256 before = wif.balanceOf(bob);
        vm.expectEmit(address(c));
        emit IFlatCircleEvents.SwapRequested(bob, dave, FEE);
        _request(bob, dave);
        assertEq(wif.balanceOf(bob), before - FEE);
        assertEq(wif.balanceOf(address(c)), 4 * BOND + FEE);
        (address cp, uint256 fee) = c.pendingSwapOf(bob);
        assertEq(cp, dave);
        assertEq(fee, FEE);
        assertEq(_info(c, bob).pendingSwapWith, dave);

        // Only one pending request per requester.
        vm.prank(bob);
        vm.expectRevert(IFlatCircleEvents.SwapNotEligible.selector);
        c.requestSwap(carol);
    }

    function test_cancel_refunds() public {
        uint256 before = wif.balanceOf(bob);
        _request(bob, dave);
        vm.prank(bob);
        c.cancelSwap();
        assertEq(wif.balanceOf(bob), before);
        (address cp,) = c.pendingSwapOf(bob);
        assertEq(cp, address(0));
        vm.prank(bob);
        vm.expectRevert(IFlatCircleEvents.NoPendingSwap.selector);
        c.cancelSwap();
    }

    function test_decline_refunds() public {
        uint256 before = wif.balanceOf(bob);
        _request(bob, dave);
        vm.prank(carol);
        vm.expectRevert(IFlatCircleEvents.NoPendingSwap.selector);
        c.declineSwap(bob);
        vm.expectEmit(address(c));
        emit IFlatCircleEvents.SwapDeclined(bob, dave, FEE);
        vm.prank(dave);
        c.declineSwap(bob);
        assertEq(wif.balanceOf(bob), before);
        assertEq(c.orderList()[1], bob, "order unchanged");
    }

    function test_accept_burnsFee_andSwapsSlots() public {
        _request(dave, bob); // dave (round 3) wants bob's round 1
        vm.prank(carol);
        vm.expectRevert(IFlatCircleEvents.NoPendingSwap.selector);
        c.acceptSwap(dave);

        vm.expectEmit(address(c));
        emit IFlatCircleEvents.SwapAccepted(dave, bob, FEE);
        vm.prank(bob);
        c.acceptSwap(dave);

        address[] memory o = c.orderList();
        assertEq(o[1], dave);
        assertEq(o[3], bob);
        assertEq(_info(c, dave).payoutRound, 1);
        assertEq(_info(c, bob).payoutRound, 3);
        assertEq(wif.balanceOf(BURN), FEE);
        assertEq(factory.getStats().totalWifBurned, FEE);
        assertEq(wif.balanceOf(address(c)), 4 * BOND);

        // Round 0 to alice, round 1 now to dave.
        _roundAllPay(c);
        uint256 daveBefore = usdg.balanceOf(dave);
        _roundAllPay(c);
        assertEq(usdg.balanceOf(dave), daveBefore - C + 4 * C);
        assertTrue(_info(c, dave).received);
        assertFalse(_info(c, bob).received);

        // A swap does not count as a default: dave's score still goes up.
        _roundAllPay(c);
        _roundAllPay(c);
        (uint32 completed, uint32 defaults) = factory.score(dave);
        assertEq(completed, 1);
        assertEq(defaults, 0);
    }

    function test_cannotSwap_withSelf_nonMember_currentRound_orPaid() public {
        vm.startPrank(bob);
        vm.expectRevert(IFlatCircleEvents.SwapNotEligible.selector);
        c.requestSwap(bob);
        vm.expectRevert(IFlatCircleEvents.SwapNotEligible.selector);
        c.requestSwap(erin);
        // alice's turn is the current round
        vm.expectRevert(IFlatCircleEvents.SwapNotEligible.selector);
        c.requestSwap(alice);
        vm.stopPrank();

        vm.prank(erin);
        vm.expectRevert(IFlatCircleEvents.NotMember.selector);
        c.requestSwap(bob);

        _roundAllPay(c); // alice received
        vm.prank(carol);
        vm.expectRevert(IFlatCircleEvents.SwapNotEligible.selector);
        c.requestSwap(alice);
        vm.prank(alice);
        vm.expectRevert(IFlatCircleEvents.SwapNotEligible.selector);
        c.requestSwap(carol);
    }

    function test_accept_rechecksEligibility() public {
        _request(dave, bob);
        _roundAllPay(c); // round 0 done; bob's round 1 is now current
        vm.prank(bob);
        vm.expectRevert(IFlatCircleEvents.SwapNotEligible.selector);
        c.acceptSwap(dave);
        // dave can still recover the fee
        uint256 before = wif.balanceOf(dave);
        vm.prank(dave);
        c.cancelSwap();
        assertEq(wif.balanceOf(dave), before + FEE);
    }

    function test_pendingSwapRefundedAtCompletion() public {
        // dave asks carol and nobody answers: the escrowed fee comes back when the circle completes.
        uint256 before = wif.balanceOf(dave);
        _request(dave, carol);
        _roundAllPay(c);
        _roundAllPay(c);
        _roundAllPay(c);
        _roundAllPay(c);
        assertEq(uint8(c.state()), uint8(State.Completed));
        assertEq(wif.balanceOf(dave), before, "fee refunded at completion");
        (address cp,) = c.pendingSwapOf(dave);
        assertEq(cp, address(0));
        assertEq(wif.balanceOf(address(c)), 4 * BOND, "only bonds left to claim");
    }

    function test_zeroFeeSwap() public {
        CircleParams memory p = _params(4, OrderMode.JoinOrder, true);
        p.swapFee = 0;
        FlatCircle z = _create(p);
        for (uint256 i = 4; i < 8; ++i) {
            _join(z, users[i]);
        }
        vm.prank(users[7]);
        z.requestSwap(users[6]);
        vm.prank(users[6]);
        z.acceptSwap(users[7]);
        assertEq(z.orderList()[2], users[7]);
        assertEq(z.orderList()[3], users[6]);
        assertEq(wif.balanceOf(BURN), 0);
    }
}
