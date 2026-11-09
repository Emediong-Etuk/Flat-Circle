// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {FlatCircle} from "../src/FlatCircle.sol";
import {FlatCircleFactory} from "../src/FlatCircleFactory.sol";
import {IFlatCircleEvents, OrderMode, State} from "../src/IFlatCircle.sol";
import {ReentrantToken} from "./mocks/ReentrantToken.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @dev Returns false (instead of reverting) on transfers to a blocked address.
contract ReturnsFalseToken is ERC20 {
    mapping(address => bool) public blocked;

    constructor() ERC20("False", "FLS") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function setBlocked(address a, bool b) external {
        blocked[a] = b;
    }

    function transfer(address to, uint256 a) public override returns (bool) {
        if (blocked[to]) return false;
        return super.transfer(to, a);
    }
}

/// @notice Tests 10-11: reentrancy, exact-amount pulls, and payouts that can't be pushed.
contract SecurityTest is Base {
    ReentrantToken internal evil;
    FlatCircleFactory internal evilFactory;

    function _evilCircle(bool evilIsUsdg) internal returns (FlatCircle c) {
        evil = new ReentrantToken();
        evilFactory = evilIsUsdg
            ? new FlatCircleFactory(address(evil), address(wif), BURN)
            : new FlatCircleFactory(address(usdg), address(evil), BURN);
        vm.prank(alice);
        c = FlatCircle(evilFactory.createCircle(_params(2, OrderMode.JoinOrder, true)));
        for (uint256 i; i < 2; ++i) {
            evil.mint(users[i], 1e30);
            vm.startPrank(users[i]);
            evil.approve(address(c), type(uint256).max);
            usdg.approve(address(c), type(uint256).max);
            wif.approve(address(c), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _assertBlocked() internal view {
        assertTrue(evil.attempted(), "attack ran");
        assertTrue(evil.blocked(), "re-entry blocked");
        bytes memory d = evil.revertData();
        assertEq(bytes4(d), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
    }

    function test_reentrancy_viaUsdg_duringJoin() public {
        FlatCircle c = _evilCircle(true);
        evil.arm(address(c), abi.encodeCall(FlatCircle.leave, ()));
        vm.prank(alice);
        c.join();
        _assertBlocked();
        assertTrue(c.isMember(alice));
    }

    function test_reentrancy_viaUsdg_duringContributeAndPayout() public {
        FlatCircle c = _evilCircle(true);
        vm.prank(alice);
        c.join();
        vm.prank(bob);
        c.join();

        evil.arm(address(c), abi.encodeCall(FlatCircle.closeRound, ()));
        vm.prank(alice);
        c.contribute();
        _assertBlocked();

        // bob's payment closes the round; the payout transfer tries to re-enter claim()
        evil.arm(address(c), abi.encodeCall(FlatCircle.claim, ()));
        vm.prank(bob);
        c.contribute();
        _assertBlocked();
        assertEq(c.currentRound(), 1);
    }

    function test_reentrancy_viaWif_duringBondBurn() public {
        FlatCircle c = _evilCircle(false);
        vm.prank(alice);
        c.join();
        vm.prank(bob);
        c.join();
        vm.prank(alice);
        c.contribute();
        vm.warp(c.roundEndsAt());
        evil.arm(address(c), abi.encodeCall(FlatCircle.contribute, ()));
        c.closeRound(); // bob misses: bond burn transfer tries to re-enter
        _assertBlocked();
        assertEq(evil.balanceOf(BURN), BOND);
    }

    function test_reentrancy_viaWif_duringClaim() public {
        FlatCircle c = _evilCircle(false);
        vm.prank(alice);
        c.join();
        vm.prank(alice);
        c.cancel();
        evil.arm(address(c), abi.encodeCall(FlatCircle.claim, ()));
        vm.prank(alice);
        c.claim();
        _assertBlocked();
        assertEq(evil.balanceOf(address(c)), 0, "claimed once");
    }

    function test_feeOnTransfer_rejected() public {
        FlatCircle c = _create(_params(3, OrderMode.JoinOrder, true));
        _approve(c, bob);
        usdg.setFeeBps(100);
        vm.prank(bob);
        vm.expectRevert(IFlatCircleEvents.UnexpectedTransferAmount.selector);
        c.join();
        usdg.setFeeBps(0);
        wif.setFeeBps(1);
        vm.prank(bob);
        vm.expectRevert(IFlatCircleEvents.UnexpectedTransferAmount.selector);
        c.join();
    }

    // ------------------------------------------------------------------ Test 11: failed push

    function test_frozenRecipient_payoutCredited_circleContinues() public {
        FlatCircle c = _activeCircle(3, true); // order alice, bob, carol
        _roundAllPay(c);
        // Round 1 is bob's. bob pays, then gets frozen before the pot drops.
        _pay(c, bob);
        _pay(c, alice);
        usdg.setFrozen(bob, true);
        uint256 bobBefore = usdg.balanceOf(bob);
        vm.expectEmit(address(c));
        emit IFlatCircleEvents.PayoutDeferred(1, bob, 3 * C);
        _pay(c, carol);
        assertEq(c.currentRound(), 2, "circle moved on");
        assertEq(usdg.balanceOf(bob), bobBefore);
        assertEq(_info(c, bob).claimableUsdg, 3 * C);
        assertTrue(_info(c, bob).received);
        assertEq(factory.getStats().totalUsdgPaidOut, 6 * C);

        // Frozen bob can't pay round 2: deposit covers him; the circle still completes.
        _pay(c, alice);
        _pay(c, carol);
        vm.warp(c.roundEndsAt());
        c.closeRound();
        assertEq(uint8(c.state()), uint8(State.Completed));

        usdg.setFrozen(bob, false);
        vm.prank(bob);
        c.claim();
        assertEq(usdg.balanceOf(bob), bobBefore + 3 * C);
    }

    function test_returnsFalseRecipient_payoutCredited() public {
        ReturnsFalseToken t = new ReturnsFalseToken();
        FlatCircleFactory f = new FlatCircleFactory(address(t), address(wif), BURN);
        vm.prank(alice);
        FlatCircle c = FlatCircle(f.createCircle(_params(2, OrderMode.JoinOrder, false)));
        for (uint256 i; i < 2; ++i) {
            t.mint(users[i], 1e12);
            vm.startPrank(users[i]);
            t.approve(address(c), type(uint256).max);
            wif.approve(address(c), type(uint256).max);
            c.join();
            vm.stopPrank();
        }
        t.setBlocked(alice, true);
        vm.prank(alice);
        c.contribute();
        vm.prank(bob);
        c.contribute();
        assertEq(c.memberInfo(alice).claimableUsdg, 2 * C);
        t.setBlocked(alice, false);
        vm.prank(alice);
        c.claim();
        assertEq(t.balanceOf(alice), 1e12 - C + 2 * C);
    }
}
