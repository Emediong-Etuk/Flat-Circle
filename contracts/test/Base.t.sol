// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {FlatCircleFactory} from "../src/FlatCircleFactory.sol";
import {FlatCircle} from "../src/FlatCircle.sol";
import {CircleParams, MemberView, OrderMode, State} from "../src/IFlatCircle.sol";
import {MockArbSys} from "./mocks/MockArbSys.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

abstract contract Base is Test {
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    address internal constant ARB_SYS = address(0x64);

    MockERC20 internal usdg;
    MockERC20 internal wif;
    FlatCircleFactory internal factory;
    MockArbSys internal arb;

    address[] internal users;
    address internal alice;
    address internal bob;
    address internal carol;
    address internal dave;
    address internal erin;

    uint256 internal C; // one contribution
    uint256 internal constant BOND = 1_000e18;
    uint256 internal constant FEE = 50e18;
    uint32 internal constant ROUND = 2 minutes;
    uint32 internal constant WINDOW = 1 days;
    uint256 internal constant START_USDG = 1_000_000; // whole tokens per user
    uint256 internal constant START_WIF = 1_000_000e18;

    /// @dev Override to test other USDG decimals.
    function usdgDecimals() internal pure virtual returns (uint8) {
        return 6;
    }

    function setUp() public virtual {
        vm.etch(ARB_SYS, type(MockArbSys).runtimeCode);
        arb = MockArbSys(ARB_SYS);
        arb.setBlockNumber(1_000);
        vm.warp(1_750_000_000);

        usdg = new MockERC20("Global Dollar", "USDG", usdgDecimals());
        wif = new MockERC20("World is Flat", "WIF", 18);
        factory = new FlatCircleFactory(address(usdg), address(wif), BURN);
        C = 10 * 10 ** usdgDecimals();

        string[5] memory names = ["alice", "bob", "carol", "dave", "erin"];
        for (uint256 i; i < 20; ++i) {
            address u = i < 5 ? makeAddr(names[i]) : makeAddr(string.concat("user", vm.toString(i)));
            users.push(u);
            usdg.mint(u, START_USDG * 10 ** usdgDecimals());
            wif.mint(u, START_WIF);
        }
        (alice, bob, carol, dave, erin) = (users[0], users[1], users[2], users[3], users[4]);
    }

    // ---------------------------------------------------------------------------------------------
    // Helpers
    // ---------------------------------------------------------------------------------------------

    function _params(uint8 n, OrderMode mode, bool deposit) internal view returns (CircleParams memory p) {
        p.name = "Market Circle";
        p.contribution = C;
        p.roundDuration = ROUND;
        p.maxMembers = n;
        p.baseBond = BOND;
        p.swapFee = FEE;
        p.joinWindow = WINDOW;
        p.depositRequired = deposit;
        p.orderMode = mode;
    }

    function _create(CircleParams memory p) internal returns (FlatCircle c) {
        vm.prank(alice);
        c = FlatCircle(factory.createCircle(p));
    }

    function _approve(FlatCircle c, address u) internal {
        vm.startPrank(u);
        usdg.approve(address(c), type(uint256).max);
        wif.approve(address(c), type(uint256).max);
        vm.stopPrank();
    }

    function _join(FlatCircle c, address u) internal {
        _approve(c, u);
        vm.prank(u);
        c.join();
    }

    function _joinFirst(FlatCircle c, uint256 n) internal {
        for (uint256 i; i < n; ++i) {
            _join(c, users[i]);
        }
    }

    /// @dev New JoinOrder circle with the first n users joined (so it's Active).
    function _activeCircle(uint8 n, bool deposit) internal returns (FlatCircle c) {
        c = _create(_params(n, OrderMode.JoinOrder, deposit));
        _joinFirst(c, n);
        assertEq(uint8(c.state()), uint8(State.Active));
    }

    function _pay(FlatCircle c, address u) internal {
        vm.prank(u);
        c.contribute();
    }

    /// @dev Every member except `skip` pays, then time passes and the round is closed.
    function _roundWithMiss(FlatCircle c, address skip) internal {
        address[] memory m = c.membersList();
        for (uint256 i; i < m.length; ++i) {
            if (m[i] != skip) _pay(c, m[i]);
        }
        vm.warp(c.roundEndsAt());
        c.closeRound();
    }

    function _roundAllPay(FlatCircle c) internal {
        address[] memory m = c.membersList();
        for (uint256 i; i < m.length; ++i) {
            _pay(c, m[i]);
        }
    }

    function _l2Advance(uint256 blocks) internal {
        arb.setBlockNumber(arb.arbBlockNumber() + blocks);
    }

    function _info(FlatCircle c, address u) internal view returns (MemberView memory) {
        return c.memberInfo(u);
    }

    function _usdgStart() internal pure returns (uint256) {
        return START_USDG * 10 ** usdgDecimals();
    }
}
