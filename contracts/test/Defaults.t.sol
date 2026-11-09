// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {FlatCircle} from "../src/FlatCircle.sol";
import {IFlatCircleEvents, MemberView, State, Stats} from "../src/IFlatCircle.sol";

/// @notice Tests 3-5: missed rounds, shortfalls, debt recovery and the early-recipient default.
contract DefaultsTest is Base {
    function _claim(FlatCircle c, address u) internal {
        vm.prank(u);
        c.claim();
    }

    /// Test 3: a miss covered by the deposit keeps the pot full, but the bond still burns.
    function test_missWithDeposit_potFull_bondBurns() public {
        FlatCircle c = _activeCircle(3, true);
        uint256 aliceBefore = usdg.balanceOf(alice);

        _pay(c, alice);
        _pay(c, bob);
        vm.warp(c.roundEndsAt() - 1);
        vm.expectRevert(IFlatCircleEvents.RoundNotOver.selector);
        c.closeRound();
        vm.warp(c.roundEndsAt());

        vm.expectEmit(address(c));
        emit IFlatCircleEvents.DepositUsed(0, carol, C);
        vm.expectEmit(address(c));
        emit IFlatCircleEvents.BondBurned(carol, BOND);
        vm.expectEmit(address(c));
        emit IFlatCircleEvents.RoundClosed(0, alice, 3 * C, 0);
        vm.prank(dave); // anyone can close
        c.closeRound();

        assertEq(usdg.balanceOf(alice), aliceBefore - C + 3 * C, "pot stayed full");
        assertEq(wif.balanceOf(BURN), BOND, "bond at burn address");
        MemberView memory m = _info(c, carol);
        assertTrue(m.defaulted);
        assertTrue(m.bondBurned);
        assertEq(m.misses, 1);
        assertEq(m.depositAvailable, 0);
        assertEq(m.debt, 0);
        (, uint32 defaults) = factory.score(carol);
        assertEq(defaults, 1);
        assertEq(factory.tierOf(carol), 4);
        assertEq(factory.bondFor(carol, BOND), 2 * BOND);
        Stats memory st = factory.getStats();
        assertEq(st.totalWifBurned, BOND);

        // A late payment after the close no longer applies to that round; carol pays round 1 normally.
        _roundAllPay(c);
        _roundAllPay(c);
        assertEq(uint8(c.state()), uint8(State.Completed));
        assertEq(_info(c, carol).claimableWif, 0, "burned bond not refundable");
        assertEq(_info(c, carol).claimableUsdg, 0, "deposit used");
        assertEq(_info(c, alice).claimableWif, BOND);
        _claim(c, alice);
        _claim(c, bob);
        vm.prank(carol);
        vm.expectRevert(IFlatCircleEvents.NothingToClaim.selector);
        c.claim();

        // Only clean members' scores go up.
        (uint32 cc,) = factory.score(carol);
        (uint32 ac,) = factory.score(alice);
        assertEq(cc, 0);
        assertEq(ac, 1);
        assertEq(usdg.balanceOf(address(c)), 0);
        assertEq(wif.balanceOf(address(c)), 0);
    }

    /// Test 4: a second miss with no deposit left shorts the pot; the debt is taken from the
    /// defaulter's later payout and paid back to the shorted recipient at the end.
    function test_doubleMiss_shortfall_debtRecovered_makeGood() public {
        FlatCircle c = _activeCircle(4, true); // order: alice, bob, carol, dave
        uint256 s = _usdgStart();

        _roundWithMiss(c, dave); // round 0: deposit covers dave
        assertEq(_info(c, dave).depositAvailable, 0);

        // Round 1: dave misses again, no deposit: bob receives 3C instead of 4C.
        _roundWithMiss(c, dave);
        assertEq(c.shortfall(1), C);
        assertEq(c.paidOut(1), 3 * C);
        assertEq(_info(c, dave).debt, C);
        assertEq(_info(c, dave).misses, 2);
        assertEq(wif.balanceOf(BURN), BOND, "bond burns only once");
        (, uint32 defaults) = factory.score(dave);
        assertEq(defaults, 1);

        // Round 2: everyone pays, carol receives in full.
        _roundAllPay(c);
        assertEq(c.paidOut(2), 4 * C);

        // Round 3: dave's own payout loses his debt to the make-good pool.
        _pay(c, alice);
        _pay(c, bob);
        _pay(c, carol);
        vm.expectEmit(address(c));
        emit IFlatCircleEvents.DebtRecovered(3, dave, C);
        _pay(c, dave);
        assertEq(c.paidOut(3), 3 * C);
        assertEq(_info(c, dave).debt, 0);
        assertEq(uint8(c.state()), uint8(State.Completed));
        assertEq(c.makeGoodPool(), 0);
        assertEq(_info(c, bob).claimableUsdg, C + C, "deposit + make-good");

        _claim(c, alice);
        _claim(c, bob);
        _claim(c, carol);
        // Honest members end exactly even; dave is even in USDG but lost his bond.
        assertEq(usdg.balanceOf(alice), s);
        assertEq(usdg.balanceOf(bob), s);
        assertEq(usdg.balanceOf(carol), s);
        assertEq(usdg.balanceOf(dave), s);
        assertEq(wif.balanceOf(dave), START_WIF - BOND);
        assertEq(usdg.balanceOf(address(c)), 0);
    }

    /// Test 4b: no deposits, a member misses two rounds before their payout; the pool is shared
    /// pro-rata between both shorted recipients.
    function test_noDeposit_twoShortRounds_proRata() public {
        FlatCircle c = _activeCircle(4, false); // order: alice, bob, carol, dave
        _roundWithMiss(c, dave); // alice shorted C
        _roundWithMiss(c, dave); // bob shorted C
        assertEq(_info(c, dave).debt, 2 * C);
        _roundAllPay(c);
        _roundAllPay(c); // dave receives 4C - 2C
        assertEq(c.paidOut(3), 2 * C);
        assertEq(_info(c, alice).claimableUsdg, C);
        assertEq(_info(c, bob).claimableUsdg, C);
        _claim(c, alice);
        _claim(c, bob);
        assertEq(usdg.balanceOf(alice), _usdgStart());
        assertEq(usdg.balanceOf(bob), _usdgStart());
        assertEq(usdg.balanceOf(address(c)), 0);
    }

    /// Test 4c: the debt is larger than the defaulter's whole payout, and the pool is split three ways.
    function test_debtExceedsPayout() public {
        FlatCircle c = _activeCircle(3, false); // order: alice, bob, carol
        _roundWithMiss(c, carol); // round 0: alice shorted C, carol debt C
        // Round 1 (bob's): only alice pays. bob misses his own round (no debt); carol owes 2C.
        _pay(c, alice);
        vm.warp(c.roundEndsAt());
        c.closeRound();
        assertEq(_info(c, bob).debt, 0, "own-round miss creates no debt");
        assertEq(_info(c, carol).debt, 2 * C);
        assertEq(c.shortfall(1), C);
        // Round 2 (carol's): only alice pays, so the pot is C and all of it goes to the make-good pool.
        _pay(c, alice);
        vm.warp(c.roundEndsAt());
        c.closeRound();
        assertEq(c.paidOut(2), 0);
        assertEq(_info(c, carol).debt, C, "C recovered, C still owed");
        assertEq(_info(c, bob).debt, C, "bob missed carol's round");
        assertEq(c.shortfall(2), C);
        // Pool of C split evenly over three short rounds, rounding dust to the last.
        uint256 a = _info(c, alice).claimableUsdg;
        uint256 b = _info(c, bob).claimableUsdg;
        uint256 k = _info(c, carol).claimableUsdg;
        assertEq(a, C / 3);
        assertEq(b, C / 3);
        assertEq(a + b + k, C);
        assertEq(usdg.balanceOf(address(c)), C);
    }

    /// Test 5: an early recipient who stops paying after their payout. The bond burns and the loss
    /// stays with the shorted later recipients; the defaulter's unpaid debt is recorded.
    function test_earlyRecipientDefault_residualLoss_noDeposit() public {
        FlatCircle c = _activeCircle(3, false); // order: alice, bob, carol
        uint256 s = _usdgStart();
        _roundAllPay(c); // alice receives 3C
        _roundWithMiss(c, alice); // bob gets 2C
        _roundWithMiss(c, alice); // carol gets 2C
        assertEq(uint8(c.state()), uint8(State.Completed));
        assertEq(_info(c, alice).debt, 2 * C, "unrecovered debt is on record");
        assertEq(wif.balanceOf(BURN), BOND);
        assertEq(_info(c, bob).claimableUsdg, 0, "nothing to make good");
        // Documented behaviour: alice is up 2C, bob and carol are each down C.
        assertEq(usdg.balanceOf(alice), s + 2 * C);
        assertEq(usdg.balanceOf(bob), s - C);
        assertEq(usdg.balanceOf(carol), s - C);
        assertEq(usdg.balanceOf(address(c)), 0);
        assertEq(factory.tierOf(alice), 4);
    }

    /// Test 5b: same, with deposits on. The deposit absorbs the first miss.
    function test_earlyRecipientDefault_residualLoss_withDeposit() public {
        FlatCircle c = _activeCircle(3, true);
        uint256 s = _usdgStart();
        _roundAllPay(c);
        _roundWithMiss(c, alice); // deposit covers: bob full
        _roundWithMiss(c, alice); // carol shorted C
        assertEq(c.paidOut(1), 3 * C);
        assertEq(c.paidOut(2), 2 * C);
        _claim(c, bob);
        _claim(c, carol);
        assertEq(usdg.balanceOf(alice), s + C);
        assertEq(usdg.balanceOf(bob), s);
        assertEq(usdg.balanceOf(carol), s - C);
        assertEq(usdg.balanceOf(address(c)), 0);
    }

    /// A recipient who skips their own round with no deposit just gets a smaller pot; nobody else loses.
    function test_recipientMissesOwnRound() public {
        FlatCircle c = _activeCircle(3, false);
        _roundAllPay(c);
        _roundWithMiss(c, bob); // bob's own round
        assertEq(c.paidOut(1), 2 * C);
        assertEq(c.shortfall(1), 0);
        assertEq(_info(c, bob).debt, 0);
        assertTrue(_info(c, bob).bondBurned);
        _roundAllPay(c);
        assertEq(usdg.balanceOf(alice), _usdgStart());
        assertEq(usdg.balanceOf(bob), _usdgStart());
        assertEq(usdg.balanceOf(carol), _usdgStart());
    }

    /// Nobody pays: everyone's bond burns and deposits fund the pot.
    function test_nobodyPays() public {
        FlatCircle c = _activeCircle(3, true);
        vm.warp(c.roundEndsAt());
        c.closeRound();
        assertEq(wif.balanceOf(BURN), 3 * BOND);
        assertEq(c.paidOut(0), 3 * C);
        assertEq(factory.getStats().totalWifBurned, 3 * BOND);
        // Next round gets a fresh full duration from the close.
        assertEq(c.roundEndsAt(), block.timestamp + ROUND);
    }

    /// The deadline resets from the moment a round is closed, even when closing late.
    function test_lateClose_givesNextRoundFullDuration() public {
        FlatCircle c = _activeCircle(3, true);
        vm.warp(c.roundEndsAt() + 1 hours);
        c.closeRound();
        assertEq(c.roundEndsAt(), block.timestamp + ROUND);
    }
}
