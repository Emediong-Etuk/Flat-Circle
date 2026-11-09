// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {FlatCircle} from "../src/FlatCircle.sol";
import {IFlatCircleEvents, OrderMode, State} from "../src/IFlatCircle.sol";

/// @notice Test 2: FairDraw ordering, determinism, re-arm on expiry, and timing.
contract FairDrawTest is Base {
    function _filledDrawCircle(uint8 n) internal returns (FlatCircle c) {
        c = _create(_params(n, OrderMode.FairDraw, true));
        _joinFirst(c, n);
        assertEq(uint8(c.state()), uint8(State.Drawing));
        assertEq(c.seedBlock(), arb.arbBlockNumber() + c.DRAW_DELAY());
    }

    function _expectedOrder(FlatCircle c, bytes32 h) internal view returns (address[] memory o) {
        o = c.membersList();
        for (uint256 i = o.length - 1; i > 0; --i) {
            uint256 j = uint256(keccak256(abi.encode(h, address(c), i))) % (i + 1);
            (o[i], o[j]) = (o[j], o[i]);
        }
    }

    function test_draw_beforeSeedBlock_reverts() public {
        FlatCircle c = _filledDrawCircle(5);
        vm.expectRevert(IFlatCircleEvents.TooEarly.selector);
        c.draw();
        _l2Advance(c.DRAW_DELAY()); // now == seedBlock, still too early
        vm.expectRevert(IFlatCircleEvents.TooEarly.selector);
        c.draw();
    }

    function test_draw_producesValidDeterministicPermutation() public {
        FlatCircle c = _filledDrawCircle(7);
        uint256 sb = c.seedBlock();
        bytes32 h = keccak256("seed-1");
        arb.setBlockHash(sb, h);
        _l2Advance(c.DRAW_DELAY() + 1);

        address[] memory expected = _expectedOrder(c, h);
        vm.expectEmit(address(c));
        emit IFlatCircleEvents.OrderDrawn(sb, h, expected);
        c.draw();

        assertEq(uint8(c.state()), uint8(State.Active));
        assertEq(c.seedHash(), h);
        assertEq(c.roundEndsAt(), block.timestamp + ROUND);
        address[] memory o = c.orderList();
        assertEq(o.length, 7);
        // Valid permutation: every member exactly once, and payoutRound matches position.
        for (uint256 i; i < 7; ++i) {
            assertEq(o[i], expected[i]);
            assertEq(_info(c, o[i]).payoutRound, i);
            for (uint256 j = i + 1; j < 7; ++j) {
                assertTrue(o[i] != o[j]);
            }
            assertTrue(c.isMember(o[i]));
        }

        vm.expectRevert(IFlatCircleEvents.NotDrawing.selector);
        c.draw();
    }

    function test_draw_differentHashesGiveDifferentOrders() public {
        FlatCircle c1 = _filledDrawCircle(6);
        // a second identical circle with the same members
        FlatCircle c2 = _create(_params(6, OrderMode.FairDraw, true));
        _joinFirst(c2, 6);
        arb.setBlockHash(c1.seedBlock(), keccak256("a"));
        arb.setBlockHash(c2.seedBlock(), keccak256("b"));
        _l2Advance(c1.DRAW_DELAY() + 1);
        c1.draw();
        c2.draw();
        assertTrue(keccak256(abi.encode(c1.orderList())) != keccak256(abi.encode(c2.orderList())));
    }

    function test_draw_rearmsWhenHashExpired() public {
        FlatCircle c = _filledDrawCircle(4);
        uint256 sb = c.seedBlock();
        // Jump past the 256-block window so ArbSys reverts.
        arb.setBlockNumber(sb + 300);
        vm.expectEmit(address(c));
        emit IFlatCircleEvents.DrawRearmed(sb + 300 + c.DRAW_DELAY());
        c.draw();
        assertEq(uint8(c.state()), uint8(State.Drawing));
        assertEq(c.seedBlock(), sb + 300 + c.DRAW_DELAY());

        // Too early again for the new seed.
        vm.expectRevert(IFlatCircleEvents.TooEarly.selector);
        c.draw();

        // Inside the window: draw succeeds.
        _l2Advance(c.DRAW_DELAY() + 5);
        c.draw();
        assertEq(uint8(c.state()), uint8(State.Active));
        assertEq(c.orderList().length, 4);
    }

    function test_draw_atWindowEdge() public {
        FlatCircle c = _filledDrawCircle(3);
        uint256 sb = c.seedBlock();
        arb.setBlockNumber(sb + 256); // last block where the hash is still available
        c.draw();
        assertEq(uint8(c.state()), uint8(State.Active));
    }

    function test_drawState_blocksOtherActions() public {
        FlatCircle c = _filledDrawCircle(3);
        vm.prank(alice);
        vm.expectRevert(IFlatCircleEvents.NotActive.selector);
        c.contribute();
        vm.prank(alice);
        vm.expectRevert(IFlatCircleEvents.NotOpen.selector);
        c.leave();
        vm.prank(alice);
        vm.expectRevert(IFlatCircleEvents.NotOpen.selector);
        c.cancel();
        _approve(c, dave);
        vm.prank(dave);
        vm.expectRevert(IFlatCircleEvents.Full.selector);
        c.join();
    }

    function test_fairDraw_fullLifecycle() public {
        FlatCircle c = _filledDrawCircle(3);
        _l2Advance(c.DRAW_DELAY() + 1);
        c.draw();
        address[] memory o = c.orderList();
        uint256 before0 = usdg.balanceOf(o[0]);
        _roundAllPay(c);
        assertEq(usdg.balanceOf(o[0]), before0 + 3 * C - C);
        _roundAllPay(c);
        _roundAllPay(c);
        assertEq(uint8(c.state()), uint8(State.Completed));
    }

    function testFuzz_draw_isPermutation(bytes32 h, uint8 n) public {
        n = uint8(bound(n, 2, 20));
        FlatCircle c = _filledDrawCircle(n);
        arb.setBlockHash(c.seedBlock(), h == bytes32(0) ? bytes32(uint256(1)) : h);
        _l2Advance(c.DRAW_DELAY() + 1);
        c.draw();
        address[] memory o = c.orderList();
        assertEq(o.length, n);
        uint256 seen;
        for (uint256 i; i < n; ++i) {
            uint256 idx = _info(c, o[i]).payoutRound;
            assertEq(idx, i);
            // users are users[0..n-1]; mark which index this address is
            for (uint256 k; k < n; ++k) {
                if (users[k] == o[i]) {
                    assertEq(seen & (1 << k), 0, "duplicate");
                    seen |= 1 << k;
                }
            }
        }
        assertEq(seen, (1 << n) - 1);
    }
}
