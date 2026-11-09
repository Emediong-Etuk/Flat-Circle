// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Base} from "./Base.t.sol";
import {FlatCircle} from "../src/FlatCircle.sol";
import {FlatCircleFactory} from "../src/FlatCircleFactory.sol";
import {CircleParams, MemberView, OrderMode, State, Stats} from "../src/IFlatCircle.sol";
import {MockArbSys} from "./mocks/MockArbSys.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev Shared accounting identities.
library Accounting {
    /// USDG owed by a circle: deposits + claimables + make-good pool + the current round's collected pot.
    function usdgOwed(FlatCircle c) internal view returns (uint256 owed) {
        MemberView[] memory ms = c.membersInfo();
        for (uint256 i; i < ms.length; ++i) {
            owed += ms[i].depositAvailable + ms[i].claimableUsdg;
        }
        owed += c.makeGoodPool();
        if (c.state() == State.Active) owed += c.potCollected(c.currentRound());
    }

    /// $WIF owed by a circle: locked bonds + claimable bonds + escrowed swap fees.
    /// Also returns the bond part alone.
    function wifOwed(FlatCircle c) internal view returns (uint256 owed, uint256 bonds) {
        MemberView[] memory ms = c.membersInfo();
        State s = c.state();
        bool live = s == State.Open || s == State.Drawing || s == State.Active;
        for (uint256 i; i < ms.length; ++i) {
            uint256 held = live && !ms[i].bondBurned ? ms[i].bond : 0;
            bonds += held + ms[i].claimableWif;
            owed += held + ms[i].claimableWif + c.swapFeeEscrow(ms[i].account);
        }
    }
}

/// @notice Test 12a: fuzzed full lifecycles with random pay/miss patterns and swaps.
contract FuzzLifecycleTest is Base {
    using Accounting for FlatCircle;

    function _check(FlatCircle c) internal view {
        assertEq(usdg.balanceOf(address(c)), c.usdgOwed(), "usdg accounting");
        (uint256 w,) = c.wifOwed();
        assertEq(wif.balanceOf(address(c)), w, "wif accounting");
    }

    function _try(FlatCircle c, address who, bytes memory data) internal returns (bool ok) {
        vm.prank(who);
        (ok,) = address(c).call(data);
    }

    function testFuzz_lifecycle(uint8 nRaw, bool deposit, bool fair, uint256 payBits, uint256 swapBits) public {
        uint8 n = uint8(bound(nRaw, 2, 8));
        FlatCircle c = _create(_params(n, fair ? OrderMode.FairDraw : OrderMode.JoinOrder, deposit));
        _joinFirst(c, n);
        if (fair) {
            _l2Advance(c.DRAW_DELAY() + 1);
            c.draw();
        }
        _check(c);
        bool everyonePays = payBits >> 255 == 1; // half the runs exercise the clean path

        for (uint256 r; r < n; ++r) {
            address[] memory m = c.membersList();
            if (swapBits & (1 << r) != 0) {
                address a = m[(swapBits >> 16) % n];
                address b = m[(swapBits >> 24) % n];
                if (_try(c, a, abi.encodeCall(FlatCircle.requestSwap, (b)))) {
                    if ((swapBits >> (32 + r)) & 1 == 1) _try(c, b, abi.encodeCall(FlatCircle.acceptSwap, (a)));
                    else if ((swapBits >> (48 + r)) & 1 == 1) _try(c, b, abi.encodeCall(FlatCircle.declineSwap, (a)));
                    // otherwise leave it pending
                }
                _check(c);
            }
            for (uint256 i; i < n; ++i) {
                if (everyonePays || (payBits >> ((r * 8 + i) % 255)) & 1 == 1) {
                    _pay(c, m[i]);
                    _check(c);
                }
            }
            if (c.currentRound() == r) {
                vm.warp(c.roundEndsAt());
                c.closeRound();
            }
            _check(c);
        }
        assertEq(uint8(c.state()), uint8(State.Completed));

        address[] memory all = c.membersList();
        for (uint256 i; i < n; ++i) {
            MemberView memory v = c.memberInfo(all[i]);
            if (v.claimableUsdg + v.claimableWif > 0) {
                vm.prank(all[i]);
                c.claim();
            }
        }
        assertEq(usdg.balanceOf(address(c)), 0, "usdg left behind");
        assertEq(wif.balanceOf(address(c)), 0, "wif left behind");

        uint256 sumU;
        uint256 sumW;
        for (uint256 i; i < n; ++i) {
            sumU += usdg.balanceOf(all[i]);
            sumW += wif.balanceOf(all[i]);
        }
        assertEq(sumU, n * _usdgStart(), "usdg conserved");
        assertEq(sumW + wif.balanceOf(BURN), n * START_WIF, "wif conserved");
        Stats memory st = factory.getStats();
        assertEq(st.totalWifBurned, wif.balanceOf(BURN));
        assertEq(st.totalWifBonded, st.totalWifRefunded + (st.totalWifBurned - _feesBurned(c)));
        if (everyonePays) {
            for (uint256 i; i < n; ++i) {
                assertEq(usdg.balanceOf(all[i]), _usdgStart(), "clean circle: everyone even");
            }
        }
    }

    function _feesBurned(FlatCircle c) internal view returns (uint256) {
        // every bond burned was a member's own bond; whatever else reached BURN is swap fees
        MemberView[] memory ms = c.membersInfo();
        uint256 bondsBurned;
        for (uint256 i; i < ms.length; ++i) {
            if (ms[i].bondBurned) bondsBurned += ms[i].bond;
        }
        return wif.balanceOf(BURN) - bondsBurned;
    }
}

/// @dev Drives random actions across a series of circles for invariant testing.
contract Handler is Test {
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;
    FlatCircleFactory public factory;
    MockERC20 public usdg;
    MockERC20 public wif;
    MockArbSys public arb;
    address[] public actors;
    FlatCircle[] public circles;
    uint256 public calls;

    constructor(FlatCircleFactory f, MockERC20 u, MockERC20 w, MockArbSys a, address[] memory act) {
        factory = f;
        usdg = u;
        wif = w;
        arb = a;
        actors = act;
        _newCircle(7);
    }

    function circleCount() external view returns (uint256) {
        return circles.length;
    }

    function circleAt(uint256 i) external view returns (FlatCircle) {
        return circles[i];
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function _cur() internal view returns (FlatCircle) {
        return circles[circles.length - 1];
    }

    function _newCircle(uint256 seed) internal {
        CircleParams memory p;
        p.name = "inv";
        p.contribution = 10e6;
        p.roundDuration = 120;
        p.maxMembers = uint8(2 + (seed % 4));
        p.baseBond = 1_000e18;
        p.swapFee = 50e18;
        p.joinWindow = 1 days;
        p.depositRequired = seed % 2 == 0;
        p.orderMode = seed % 3 == 0 ? OrderMode.FairDraw : OrderMode.JoinOrder;
        FlatCircle c = FlatCircle(factory.createCircle(p));
        circles.push(c);
        for (uint256 i; i < p.maxMembers; ++i) {
            address u = actors[((seed % actors.length) + i) % actors.length];
            vm.startPrank(u);
            usdg.approve(address(c), type(uint256).max);
            wif.approve(address(c), type(uint256).max);
            c.join();
            vm.stopPrank();
        }
    }

    /// Moves the current circle forward; starts a new one once it's finished.
    function advance(uint256 seed) external {
        ++calls;
        FlatCircle c = _cur();
        State s = c.state();
        if (s == State.Completed) {
            _newCircle(seed);
        } else if (s == State.Drawing) {
            arb.setBlockNumber(arb.arbBlockNumber() + 21 + (seed % 400)); // sometimes past the window
            c.draw();
        } else if (s == State.Active) {
            vm.warp(block.timestamp + 121);
            c.closeRound();
        }
    }

    function pay(uint256 who) external {
        ++calls;
        FlatCircle c = _cur();
        if (c.state() != State.Active) return;
        address[] memory m = c.membersList();
        address u = m[who % m.length];
        if (c.paid(c.currentRound(), u)) return;
        vm.prank(u);
        c.contribute();
    }

    function swap(uint256 a, uint256 b, uint256 action) external {
        ++calls;
        FlatCircle c = _cur();
        if (c.state() != State.Active) return;
        address[] memory m = c.membersList();
        address x = m[a % m.length];
        address y = m[b % m.length];
        vm.prank(x);
        (bool ok,) = address(c).call(abi.encodeCall(FlatCircle.requestSwap, (y)));
        if (!ok) return;
        vm.prank(action % 3 == 0 ? x : y);
        if (action % 3 == 0) c.cancelSwap();
        else if (action % 3 == 1) c.acceptSwap(x);
        else c.declineSwap(x);
    }

    function claim(uint256 circleIdx, uint256 who) external {
        ++calls;
        FlatCircle c = circles[circleIdx % circles.length];
        address u = actors[who % actors.length];
        MemberView memory v = c.memberInfo(u);
        if (v.claimableUsdg + v.claimableWif == 0) return;
        vm.prank(u);
        c.claim();
    }
}

/// @notice Test 12b: invariants across random action sequences and many circles.
contract InvariantTest is Base {
    using Accounting for FlatCircle;

    Handler internal handler;
    uint256 internal constant ACTORS = 6;

    function setUp() public override {
        super.setUp();
        address[] memory act = new address[](ACTORS);
        for (uint256 i; i < ACTORS; ++i) {
            act[i] = users[i];
        }
        handler = new Handler(factory, usdg, wif, arb, act);
        targetContract(address(handler));
    }

    function invariant_circleAccounting() public view {
        uint256 n = handler.circleCount();
        for (uint256 i; i < n; ++i) {
            FlatCircle c = handler.circleAt(i);
            assertEq(usdg.balanceOf(address(c)), c.usdgOwed(), "usdg: balance == obligations");
            (uint256 w,) = c.wifOwed();
            assertEq(wif.balanceOf(address(c)), w, "wif: balance == obligations");
        }
    }

    function invariant_conservation() public view {
        uint256 sumU;
        uint256 sumW;
        for (uint256 i; i < ACTORS; ++i) {
            sumU += usdg.balanceOf(users[i]);
            sumW += wif.balanceOf(users[i]);
        }
        uint256 n = handler.circleCount();
        for (uint256 i; i < n; ++i) {
            address c = address(handler.circleAt(i));
            sumU += usdg.balanceOf(c);
            sumW += wif.balanceOf(c);
        }
        assertEq(sumU, ACTORS * _usdgStart(), "usdg in == out + held");
        assertEq(sumW + wif.balanceOf(BURN), ACTORS * START_WIF, "wif in == refunded + burned + held");
    }

    function invariant_burnStatMatchesBurnAddress() public view {
        assertEq(factory.getStats().totalWifBurned, wif.balanceOf(BURN));
    }

    function invariant_bondLedger() public view {
        // bonded == refunded + burned bonds + bonds still held or claimable
        Stats memory st = factory.getStats();
        uint256 n = handler.circleCount();
        uint256 bondsOutstanding;
        uint256 bondsBurned;
        for (uint256 i; i < n; ++i) {
            FlatCircle c = handler.circleAt(i);
            (, uint256 b) = c.wifOwed();
            bondsOutstanding += b;
            MemberView[] memory ms = c.membersInfo();
            for (uint256 k; k < ms.length; ++k) {
                if (ms[k].bondBurned) bondsBurned += ms[k].bond;
            }
        }
        assertEq(st.totalWifBonded, st.totalWifRefunded + bondsBurned + bondsOutstanding);
    }
}
