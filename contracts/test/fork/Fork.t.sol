// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {FlatCircleFactory} from "../../src/FlatCircleFactory.sol";
import {FlatCircle} from "../../src/FlatCircle.sol";
import {CircleParams, OrderMode, State, Stats} from "../../src/IFlatCircle.sol";
import {MockArbSys} from "../mocks/MockArbSys.sol";

/// @notice Runs against Robinhood Chain mainnet state with the real USDG and $WIF.
/// forge test --match-path 'test/fork/*' --fork-url $RPC_URL
/// Skipped automatically when not forking chain 4663.
contract ForkTest is Test {
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant WIF = 0x5173b8eA6923c2d40267890D45C46a3480954773;
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    address internal constant ARB_SYS = address(0x64);
    /// WIF/USDG pool on Up V3 (holds both tokens), used if `deal` can't find USDG's balance slot.
    address internal constant HOLDER = 0xc3A41A216afE024cf9F38a01C67E80De8916802c;

    IERC20 internal usdg = IERC20(USDG);
    IERC20 internal wif = IERC20(WIF);
    FlatCircleFactory internal factory;
    MockArbSys internal arb;
    address[] internal users;
    uint256 internal constant ONE_USDG = 1e6;
    uint256 internal constant BOND = 1_000e18;
    uint256 internal constant FEE = 10e18;

    function setUp() public {
        if (block.chainid != 4663) {
            vm.skip(true);
            return;
        }
        // ArbSys doesn't exist in forge's EVM; etch the mock and pin it to the forked block.
        vm.etch(ARB_SYS, type(MockArbSys).runtimeCode);
        arb = MockArbSys(ARB_SYS);
        arb.setBlockNumber(block.number);
        factory = new FlatCircleFactory(USDG, WIF, BURN);
        for (uint256 i; i < 3; ++i) {
            users.push(makeAddr(string.concat("fork", vm.toString(i))));
            _fundUsdg(users[i], 20 * ONE_USDG);
            deal(WIF, users[i], 10_000e18);
        }
    }

    function _fundUsdg(address to, uint256 amount) internal {
        // Paxos's proxy layout isn't always found by stdstore, so take it from a real holder.
        vm.prank(HOLDER);
        usdg.transfer(to, amount);
        assertEq(usdg.balanceOf(to), amount);
    }

    function test_fork_tokenFacts() public {
        assertEq(IERC20Metadata(USDG).decimals(), 6);
        assertEq(IERC20Metadata(WIF).decimals(), 18);
        assertEq(factory.usdgDecimals(), 6);
        assertEq(factory.maxContribution(), 10_000e6);

        // Exact amounts on transfer and transferFrom (no fee-on-transfer, no rebasing).
        address a = users[0];
        address b = users[1];
        uint256 b0u = usdg.balanceOf(b);
        uint256 b0w = wif.balanceOf(b);
        vm.prank(a);
        usdg.transfer(b, 1_234_567);
        vm.prank(a);
        wif.transfer(b, 1e18);
        assertEq(usdg.balanceOf(b) - b0u, 1_234_567);
        assertEq(wif.balanceOf(b) - b0w, 1e18);

        vm.prank(a);
        usdg.approve(b, 1e6);
        vm.prank(b);
        usdg.transferFrom(a, b, 1e6);
        assertEq(usdg.balanceOf(b) - b0u, 2_234_567);

        uint256 dead0 = wif.balanceOf(BURN);
        vm.prank(a);
        wif.transfer(BURN, 5e18);
        assertEq(wif.balanceOf(BURN) - dead0, 5e18);
    }

    function test_fork_fullLifecycle_realTokens() public {
        CircleParams memory p;
        p.name = "Fork Circle";
        p.contribution = ONE_USDG;
        p.roundDuration = 2 minutes;
        p.maxMembers = 3;
        p.baseBond = BOND;
        p.swapFee = FEE;
        p.joinWindow = 1 days;
        p.depositRequired = true;
        p.orderMode = OrderMode.FairDraw;

        vm.prank(users[0]);
        FlatCircle c = FlatCircle(factory.createCircle(p));
        uint256 dead0 = wif.balanceOf(BURN);

        for (uint256 i; i < 3; ++i) {
            vm.startPrank(users[i]);
            usdg.approve(address(c), 4 * ONE_USDG);
            wif.approve(address(c), BOND + FEE);
            c.join();
            vm.stopPrank();
        }
        assertEq(uint8(c.state()), uint8(State.Drawing));
        assertEq(wif.balanceOf(address(c)), 3 * BOND);
        assertEq(usdg.balanceOf(address(c)), 3 * ONE_USDG);

        arb.setBlockNumber(c.seedBlock() + 1);
        c.draw();
        address[] memory o = c.orderList();

        // Swap during round 0 (in a 3-member circle it's the only time two turns are still ahead):
        // o[2] takes o[1]'s turn and the fee burns.
        vm.prank(o[2]);
        c.requestSwap(o[1]);
        vm.prank(o[1]);
        c.acceptSwap(o[2]);
        assertEq(c.orderList()[1], o[2]);
        assertEq(c.orderList()[2], o[1]);
        assertEq(wif.balanceOf(BURN) - dead0, FEE);
        o = c.orderList();

        // Round 0: everyone pays, the pot drops instantly.
        uint256 r0 = usdg.balanceOf(o[0]);
        for (uint256 i; i < 3; ++i) {
            vm.prank(o[i]);
            c.contribute();
        }
        assertEq(usdg.balanceOf(o[0]), r0 - ONE_USDG + 3 * ONE_USDG);

        // Round 1: o[0] misses; deposit covers, bond burns.
        vm.prank(o[1]);
        c.contribute();
        vm.prank(o[2]);
        c.contribute();
        vm.warp(c.roundEndsAt());
        c.closeRound();
        assertEq(wif.balanceOf(BURN) - dead0, FEE + BOND);

        // Round 2: everyone pays, the circle completes, honest members claim.
        for (uint256 i; i < 3; ++i) {
            vm.prank(o[i]);
            c.contribute();
        }
        assertEq(uint8(c.state()), uint8(State.Completed));
        for (uint256 i = 1; i < 3; ++i) {
            uint256 w0 = wif.balanceOf(o[i]);
            vm.prank(o[i]);
            c.claim();
            assertEq(wif.balanceOf(o[i]) - w0, BOND);
        }
        assertEq(wif.balanceOf(address(c)), 0);
        assertEq(usdg.balanceOf(address(c)), 0);

        Stats memory st = factory.getStats();
        assertEq(st.totalWifBurned, FEE + BOND);
        assertEq(st.totalWifRefunded, 2 * BOND);
        assertEq(st.totalUsdgPaidOut, 9 * ONE_USDG);
        assertEq(factory.tierOf(o[0]), 4);
        assertEq(factory.tierOf(o[1]), 1);
    }
}
