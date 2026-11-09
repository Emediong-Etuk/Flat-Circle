// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {
    CircleParams,
    CircleSummary,
    IArbSys,
    IFlatCircleEvents,
    IFlatCircleFactory,
    MemberView,
    OrderMode,
    State
} from "./IFlatCircle.sol";

/// @title FlatCircle
/// @notice One rotating savings circle (ajo / esusu / susu). Every member pays `contribution` USDG each
/// round and one member receives the whole pot. Members lock a $WIF bond that burns if they miss a
/// payment and is returned when the circle ends. There is no admin, no upgrade path and no pause.
/// @dev Deployed by FlatCircleFactory, which validates the params. Rounds are 0-based.
contract FlatCircle is IFlatCircleEvents, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// @notice Arbitrum ArbSys precompile, used for real L2 block numbers and hashes.
    address internal constant ARB_SYS = address(0x0000000000000000000000000000000000000064);
    /// @notice L2 blocks between filling a FairDraw circle and the block whose hash seeds the draw.
    uint256 public constant DRAW_DELAY = 20;

    struct Member {
        uint256 bond;
        uint256 depositAvailable;
        uint256 debt;
        uint256 claimableUsdg;
        uint256 claimableWif;
        uint32 misses;
        uint8 index;
        uint8 payoutRound;
        bool exists;
        bool bondBurned;
        bool defaulted;
        bool received;
    }

    IFlatCircleFactory public immutable factory;
    IERC20 public immutable usdg;
    IERC20 public immutable wif;
    address public immutable burnAddress;
    address public immutable creator;
    uint256 public immutable contribution;
    uint256 public immutable baseBond;
    uint256 public immutable swapFee;
    uint32 public immutable roundDuration;
    uint32 public immutable joinWindow;
    uint8 public immutable maxMembers;
    bool public immutable depositRequired;
    OrderMode public immutable orderMode;
    bool public immutable hasAllowlist;
    uint64 public immutable createdAt;
    uint64 public immutable createdAtBlock;
    uint64 public immutable joinDeadline;

    string public name;

    State public state;
    uint256 public currentRound;
    uint64 public roundEndsAt;
    uint256 public seedBlock;
    bytes32 public seedHash;
    /// @notice USDG recovered from defaulters' payouts, shared with shorted recipients at the end.
    uint256 public makeGoodPool;

    address[] internal _members;
    address[] internal _order;
    address[] internal _allowlist;
    mapping(address => bool) public allowed;
    mapping(address => Member) internal _m;

    mapping(uint256 => mapping(address => bool)) public paid;
    mapping(uint256 => uint256) public paidCount;
    mapping(uint256 => uint256) public potCollected;
    mapping(uint256 => uint256) public shortfall;
    mapping(uint256 => uint256) public paidOut;

    mapping(address => address) public pendingSwap;
    mapping(address => uint256) public swapFeeEscrow;

    /// @param p Circle parameters, already validated by the factory.
    /// @param creator_ The account that created the circle.
    constructor(CircleParams memory p, address creator_) {
        IFlatCircleFactory f = IFlatCircleFactory(msg.sender);
        factory = f;
        usdg = IERC20(f.usdg());
        wif = IERC20(f.wif());
        burnAddress = f.burnAddress();
        creator = creator_;
        name = p.name;
        contribution = p.contribution;
        baseBond = p.baseBond;
        swapFee = p.swapFee;
        roundDuration = p.roundDuration;
        joinWindow = p.joinWindow;
        maxMembers = p.maxMembers;
        depositRequired = p.depositRequired;
        orderMode = p.orderMode;
        hasAllowlist = p.allowlist.length > 0;
        createdAt = uint64(block.timestamp);
        createdAtBlock = uint64(_l2BlockNumber());
        joinDeadline = uint64(block.timestamp + p.joinWindow);
        for (uint256 i; i < p.allowlist.length; ++i) {
            allowed[p.allowlist[i]] = true;
        }
        _allowlist = p.allowlist;
    }

    // ---------------------------------------------------------------------------------------------
    // Open phase
    // ---------------------------------------------------------------------------------------------

    /// @notice Join the circle: locks your $WIF bond (sized by your Flat Score) and, if required,
    /// a deposit of one contribution in USDG. Approve both tokens to this circle first.
    function join() external nonReentrant {
        State s = state;
        if (s == State.Drawing || s == State.Active) revert Full();
        if (s != State.Open) revert NotOpen();
        if (block.timestamp >= joinDeadline) revert JoinWindowClosed();
        Member storage m = _m[msg.sender];
        if (m.exists) revert AlreadyMember();
        if (hasAllowlist && !allowed[msg.sender]) revert NotAllowed();

        uint256 bond = factory.bondFor(msg.sender, baseBond);
        uint256 dep = depositRequired ? contribution : 0;
        m.exists = true;
        m.bond = bond;
        m.depositAvailable = dep;
        // forge-lint: disable-next-line(unsafe-typecast) -- at most 20 members
        m.index = uint8(_members.length);
        _members.push(msg.sender);

        _pull(wif, msg.sender, bond);
        if (dep > 0) _pull(usdg, msg.sender, dep);
        factory.onJoined(msg.sender, bond);
        emit Joined(msg.sender, bond, dep);

        if (_members.length == maxMembers) _onFilled();
    }

    /// @notice Leave a circle that hasn't filled yet. Your bond and deposit come straight back.
    function leave() external nonReentrant {
        if (state != State.Open) revert NotOpen();
        Member storage m = _m[msg.sender];
        if (!m.exists) revert NotMember();
        uint256 bond = m.bond;
        uint256 dep = m.depositAvailable;

        // Shift later members down so JoinOrder stays true to join order.
        uint256 n = _members.length;
        for (uint256 i = m.index; i + 1 < n; ++i) {
            address next = _members[i + 1];
            _members[i] = next;
            // forge-lint: disable-next-line(unsafe-typecast) -- at most 20 members
            _m[next].index = uint8(i);
        }
        _members.pop();
        delete _m[msg.sender];

        wif.safeTransfer(msg.sender, bond);
        if (dep > 0) usdg.safeTransfer(msg.sender, dep);
        factory.onRefund(bond);
        emit Left(msg.sender, bond, dep);
    }

    /// @notice Cancel a circle that hasn't filled. The creator can cancel any time; anyone can cancel
    /// once the join window has closed. Every member's bond and deposit become claimable.
    function cancel() external nonReentrant {
        if (state != State.Open) revert NotOpen();
        if (msg.sender != creator && block.timestamp < joinDeadline) revert JoinWindowOpen();
        state = State.Cancelled;
        uint256 n = _members.length;
        for (uint256 i; i < n; ++i) {
            Member storage m = _m[_members[i]];
            m.claimableWif += m.bond;
            m.claimableUsdg += m.depositAvailable;
            m.depositAvailable = 0;
        }
        emit Cancelled(msg.sender);
    }

    /// @notice FairDraw only: reveal the payout order from the hash of `seedBlock`. If that hash has
    /// left ArbSys's 256-block window, the seed is re-armed to a new future block and this call
    /// returns without reverting so it can simply be retried.
    function draw() external nonReentrant {
        if (state != State.Drawing) revert NotDrawing();
        uint256 nowBlock = _l2BlockNumber();
        uint256 sb = seedBlock;
        if (nowBlock <= sb) revert TooEarly();
        bytes32 h = _l2BlockHash(sb);
        if (h == bytes32(0)) {
            uint256 next = nowBlock + DRAW_DELAY;
            seedBlock = next;
            emit DrawRearmed(next);
            return;
        }
        seedHash = h;

        address[] memory o = _members;
        for (uint256 i = o.length - 1; i > 0; --i) {
            uint256 j = uint256(keccak256(abi.encode(h, address(this), i))) % (i + 1);
            (o[i], o[j]) = (o[j], o[i]);
        }
        _setOrder(o);
        _activate();
        emit OrderDrawn(sb, h, o);
    }

    // ---------------------------------------------------------------------------------------------
    // Active phase
    // ---------------------------------------------------------------------------------------------

    /// @notice Pay this round's contribution. If you're the last to pay, the pot drops in this same
    /// transaction. Late payment counts as long as nobody has closed the round yet.
    function contribute() external nonReentrant {
        if (state != State.Active) revert NotActive();
        if (!_m[msg.sender].exists) revert NotMember();
        uint256 r = currentRound;
        if (paid[r][msg.sender]) revert AlreadyPaid();

        paid[r][msg.sender] = true;
        uint256 count = ++paidCount[r];
        potCollected[r] += contribution;

        _pull(usdg, msg.sender, contribution);
        emit Contributed(r, msg.sender, contribution);

        if (count == _members.length) _closeRound();
    }

    /// @notice Close the current round once its deadline has passed. Anyone can call this.
    /// Unpaid members are covered by their deposit if they have one; either way their bond burns.
    function closeRound() external nonReentrant {
        if (state != State.Active) revert NotActive();
        if (block.timestamp < roundEndsAt && paidCount[currentRound] < _members.length) revert RoundNotOver();
        _closeRound();
    }

    /// @notice Ask `other` to swap payout turns with you. Escrows the swap fee in $WIF, which burns
    /// if they accept. Neither of you may have received yet, and neither turn may be the current round.
    /// @param other The member whose turn you want.
    function requestSwap(address other) external nonReentrant {
        if (state != State.Active) revert NotActive();
        if (!_m[msg.sender].exists) revert NotMember();
        if (pendingSwap[msg.sender] != address(0)) revert SwapNotEligible();
        if (!_swapEligible(msg.sender, other)) revert SwapNotEligible();
        uint256 fee = swapFee;
        pendingSwap[msg.sender] = other;
        swapFeeEscrow[msg.sender] = fee;
        if (fee > 0) _pull(wif, msg.sender, fee);
        emit SwapRequested(msg.sender, other, fee);
    }

    /// @notice Withdraw your pending swap request and get the escrowed fee back.
    function cancelSwap() external nonReentrant {
        address other = pendingSwap[msg.sender];
        if (other == address(0)) revert NoPendingSwap();
        uint256 fee = _clearSwap(msg.sender);
        if (fee > 0) wif.safeTransfer(msg.sender, fee);
        emit SwapCancelled(msg.sender, other, fee);
    }

    /// @notice Accept a swap request aimed at you. Your turns trade places and the requester's
    /// escrowed fee is sent to the burn address.
    /// @param requester The member who asked to swap with you.
    function acceptSwap(address requester) external nonReentrant {
        if (state != State.Active) revert NotActive();
        if (pendingSwap[requester] != msg.sender) revert NoPendingSwap();
        if (!_swapEligible(requester, msg.sender)) revert SwapNotEligible();

        Member storage a = _m[requester];
        Member storage b = _m[msg.sender];
        uint8 ra = a.payoutRound;
        uint8 rb = b.payoutRound;
        _order[ra] = msg.sender;
        _order[rb] = requester;
        a.payoutRound = rb;
        b.payoutRound = ra;

        uint256 fee = _clearSwap(requester);
        if (fee > 0) {
            wif.safeTransfer(burnAddress, fee);
            factory.onSwapFeeBurned(fee);
        }
        emit SwapAccepted(requester, msg.sender, fee);
    }

    /// @notice Decline a swap request aimed at you. The requester gets their fee back.
    /// @param requester The member who asked to swap with you.
    function declineSwap(address requester) external nonReentrant {
        if (pendingSwap[requester] != msg.sender) revert NoPendingSwap();
        uint256 fee = _clearSwap(requester);
        if (fee > 0) wif.safeTransfer(requester, fee);
        emit SwapDeclined(requester, msg.sender, fee);
    }

    /// @notice Withdraw everything credited to you: unused deposit, returned bond, make-good share,
    /// cancelled-circle refunds, or a payout that couldn't be pushed to you.
    function claim() external nonReentrant {
        Member storage m = _m[msg.sender];
        uint256 u = m.claimableUsdg;
        uint256 w = m.claimableWif;
        if (u == 0 && w == 0) revert NothingToClaim();
        m.claimableUsdg = 0;
        m.claimableWif = 0;
        if (u > 0) usdg.safeTransfer(msg.sender, u);
        if (w > 0) {
            wif.safeTransfer(msg.sender, w);
            factory.onRefund(w);
        }
        emit Claimed(msg.sender, u, w);
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Everything the circle page needs in one call.
    function summary() external view returns (CircleSummary memory s) {
        s.state = state;
        s.name = name;
        s.contribution = contribution;
        s.roundDuration = roundDuration;
        s.maxMembers = maxMembers;
        // forge-lint: disable-next-line(unsafe-typecast) -- at most 20 members
        s.memberCount = uint8(_members.length);
        s.baseBond = baseBond;
        s.swapFee = swapFee;
        s.joinWindow = joinWindow;
        s.depositRequired = depositRequired;
        s.orderMode = orderMode;
        s.hasAllowlist = hasAllowlist;
        s.creator = creator;
        s.factory = address(factory);
        s.createdAt = createdAt;
        s.createdAtBlock = createdAtBlock;
        s.joinDeadline = joinDeadline;
        s.currentRound = currentRound;
        s.roundEndsAt = roundEndsAt;
        s.potSoFar = potCollected[currentRound];
        s.paidCount = paidCount[currentRound];
        s.seedBlock = seedBlock;
        s.seedHash = seedHash;
        s.makeGoodPool = makeGoodPool;
        s.l2BlockNumber = _l2BlockNumber();
    }

    /// @notice Per-member state, in join order.
    function membersInfo() external view returns (MemberView[] memory out) {
        uint256 n = _members.length;
        out = new MemberView[](n);
        for (uint256 i; i < n; ++i) {
            out[i] = _view(_members[i]);
        }
    }

    /// @notice State of a single account (zeroed if not a member).
    function memberInfo(address account) external view returns (MemberView memory) {
        return _view(account);
    }

    /// @notice Members in join order.
    function membersList() external view returns (address[] memory) {
        return _members;
    }

    /// @notice Payout order: `orderList()[r]` receives the pot in round r. Empty until set.
    function orderList() external view returns (address[] memory) {
        return _order;
    }

    /// @notice The allowlist the circle was created with (empty if open to anyone).
    function allowlist() external view returns (address[] memory) {
        return _allowlist;
    }

    /// @notice Whether `account` is currently a member.
    function isMember(address account) external view returns (bool) {
        return _m[account].exists;
    }

    /// @notice The swap `requester` has pending, if any.
    function pendingSwapOf(address requester) external view returns (address counterparty, uint256 fee) {
        return (pendingSwap[requester], swapFeeEscrow[requester]);
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _onFilled() internal {
        emit Filled(_members.length);
        if (orderMode == OrderMode.JoinOrder) {
            _setOrder(_members);
            _activate();
        } else {
            state = State.Drawing;
            seedBlock = _l2BlockNumber() + DRAW_DELAY;
        }
    }

    function _setOrder(address[] memory o) internal {
        _order = o;
        for (uint256 i; i < o.length; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast) -- at most 20 members
            _m[o[i]].payoutRound = uint8(i);
        }
    }

    function _activate() internal {
        state = State.Active;
        roundEndsAt = uint64(block.timestamp + roundDuration);
    }

    function _closeRound() internal {
        uint256 r = currentRound;
        uint256 n = _members.length;
        uint256 c = contribution;
        address recipient = _order[r];

        // Effects: settle every unpaid member.
        address[] memory burnWho = new address[](n);
        uint256[] memory burnAmt = new uint256[](n);
        uint256 burns;
        for (uint256 i; i < n; ++i) {
            address a = _members[i];
            if (paid[r][a]) continue;
            Member storage m = _m[a];
            if (m.depositAvailable >= c) {
                m.depositAvailable -= c;
                potCollected[r] += c;
                emit DepositUsed(r, a, c);
            } else if (a != recipient) {
                // Uncovered miss: this round's recipient is shorted, and the miss becomes debt.
                shortfall[r] += c;
                m.debt += c;
            }
            // A recipient who misses their own round with no deposit just gets a smaller pot.
            m.misses += 1;
            m.defaulted = true;
            if (!m.bondBurned) {
                m.bondBurned = true;
                burnWho[burns] = a;
                burnAmt[burns] = m.bond;
                ++burns;
            }
        }

        uint256 payout = potCollected[r];
        Member storage rm = _m[recipient];
        if (rm.debt > 0 && payout > 0) {
            uint256 d = rm.debt < payout ? rm.debt : payout;
            rm.debt -= d;
            payout -= d;
            makeGoodPool += d;
            emit DebtRecovered(r, recipient, d);
        }
        rm.received = true;
        paidOut[r] = payout;
        uint256 short = shortfall[r];

        bool last = r + 1 == n;
        currentRound = r + 1;
        if (!last) roundEndsAt = uint64(block.timestamp + roundDuration);

        // Interactions.
        for (uint256 i; i < burns; ++i) {
            if (burnAmt[i] > 0) wif.safeTransfer(burnAddress, burnAmt[i]);
            factory.onBondBurned(burnWho[i], burnAmt[i]);
            emit BondBurned(burnWho[i], burnAmt[i]);
        }
        if (payout > 0) {
            if (!_tryPushUsdg(recipient, payout)) {
                rm.claimableUsdg += payout;
                emit PayoutDeferred(r, recipient, payout);
            }
            factory.onPayout(payout);
        }
        emit RoundClosed(r, recipient, payout, short);

        if (last) _finalize();
    }

    function _finalize() internal {
        state = State.Completed;
        uint256 n = _members.length;

        // Share recovered debt with the recipients of short rounds, pro-rata by shortfall.
        uint256 pool = makeGoodPool;
        if (pool > 0) {
            uint256 totalShort;
            uint256 lastShort;
            for (uint256 r; r < n; ++r) {
                if (shortfall[r] > 0) {
                    totalShort += shortfall[r];
                    lastShort = r;
                }
            }
            makeGoodPool = 0;
            uint256 distributed;
            for (uint256 r; r < n; ++r) {
                uint256 s = shortfall[r];
                if (s == 0) continue;
                uint256 share = r == lastShort ? pool - distributed : (pool * s) / totalShort;
                distributed += share;
                address to = _order[r];
                _m[to].claimableUsdg += share;
                emit MakeGoodCredited(r, to, share);
            }
        }

        uint256 cleanCount;
        for (uint256 i; i < n; ++i) {
            if (_m[_members[i]].misses == 0) ++cleanCount;
        }
        address[] memory clean = new address[](cleanCount);
        address[] memory refundWho = new address[](n);
        uint256[] memory refundAmt = new uint256[](n);
        uint256 refunds;
        uint256 k;
        for (uint256 i; i < n; ++i) {
            address a = _members[i];
            Member storage m = _m[a];
            m.claimableUsdg += m.depositAvailable;
            m.depositAvailable = 0;
            if (!m.bondBurned) m.claimableWif += m.bond;
            if (m.misses == 0) clean[k++] = a;
            if (pendingSwap[a] != address(0)) {
                refundWho[refunds] = a;
                refundAmt[refunds] = _clearSwap(a);
                ++refunds;
            }
        }

        for (uint256 i; i < refunds; ++i) {
            if (refundAmt[i] > 0) wif.safeTransfer(refundWho[i], refundAmt[i]);
        }
        factory.onCompleted(clean);
        emit Completed(cleanCount);
    }

    function _clearSwap(address requester) internal returns (uint256 fee) {
        fee = swapFeeEscrow[requester];
        delete pendingSwap[requester];
        delete swapFeeEscrow[requester];
    }

    function _swapEligible(address a, address b) internal view returns (bool) {
        if (a == b) return false;
        Member storage ma = _m[a];
        Member storage mb = _m[b];
        if (!ma.exists || !mb.exists) return false;
        if (ma.received || mb.received) return false;
        uint256 r = currentRound;
        return ma.payoutRound > r && mb.payoutRound > r;
    }

    function _view(address a) internal view returns (MemberView memory v) {
        Member storage m = _m[a];
        v.account = a;
        v.bond = m.bond;
        v.bondBurned = m.bondBurned;
        v.depositAvailable = m.depositAvailable;
        v.defaulted = m.defaulted;
        v.misses = m.misses;
        v.debt = m.debt;
        v.payoutRound = m.payoutRound;
        v.received = m.received;
        v.paidThisRound = paid[currentRound][a];
        v.claimableUsdg = m.claimableUsdg;
        v.claimableWif = m.claimableWif;
        v.pendingSwapWith = pendingSwap[a];
    }

    /// @dev Pulls exactly `amount` or reverts, so fee-on-transfer or rebasing tokens can't break accounting.
    function _pull(IERC20 token, address from, uint256 amount) internal {
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(from, address(this), amount);
        if (token.balanceOf(address(this)) - before != amount) revert UnexpectedTransferAmount();
    }

    /// @dev Push a payout without reverting, so one recipient that can't receive (for example a
    /// frozen USDG address) can't block the circle. On failure the caller credits a claim instead.
    function _tryPushUsdg(address to, uint256 amount) internal returns (bool) {
        (bool ok, bytes memory data) = address(usdg).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok) return false;
        if (data.length == 0) return address(usdg).code.length > 0;
        if (data.length < 32) return false;
        return abi.decode(data, (uint256)) == 1;
    }

    function _l2BlockNumber() internal view returns (uint256) {
        return IArbSys(ARB_SYS).arbBlockNumber();
    }

    /// @dev Returns 0 when the hash is unavailable (ArbSys reverts outside the last 256 blocks).
    function _l2BlockHash(uint256 n) internal view returns (bytes32) {
        try IArbSys(ARB_SYS).arbBlockHash(n) returns (bytes32 h) {
            return h;
        } catch {
            return bytes32(0);
        }
    }
}
