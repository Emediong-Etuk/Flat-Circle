// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {FlatCircle} from "./FlatCircle.sol";
import {CircleParams, IFlatCircleFactory, Score, Stats} from "./IFlatCircle.sol";

/// @title FlatCircleFactory
/// @notice Creates Flat Circles, keeps every member's portable Flat Score, and tracks protocol stats.
/// There is no owner: once deployed, nobody can change the rules or move funds.
contract FlatCircleFactory is IFlatCircleFactory, ReentrancyGuard {
    uint8 public constant TIER_NEW = 0;
    uint8 public constant TIER_STEADY = 1;
    uint8 public constant TIER_TRUSTED = 2;
    uint8 public constant TIER_PILLAR = 3;
    uint8 public constant TIER_FLAGGED = 4;

    uint256 public constant MAX_NAME_BYTES = 48;
    uint32 public constant MIN_ROUND_DURATION = 60;
    uint32 public constant MAX_ROUND_DURATION = 31 days;
    uint32 public constant MIN_JOIN_WINDOW = 10 minutes;
    uint32 public constant MAX_JOIN_WINDOW = 14 days;
    uint8 public constant MIN_MEMBERS = 2;
    uint8 public constant MAX_MEMBERS = 20;
    uint256 public constant MAX_ALLOWLIST = 20;
    /// @notice Upper bound on bond and swap fee inputs, so tier maths can never overflow.
    uint256 public constant MAX_WIF_PARAM = type(uint128).max;

    address public immutable usdg;
    address public immutable wif;
    address public immutable burnAddress;
    uint8 public immutable usdgDecimals;
    /// @notice Per-round contribution cap (10,000 USDG). The contracts are unaudited.
    uint256 public immutable maxContribution;

    address[] internal _circles;
    mapping(address => bool) public isCircle;
    mapping(address => address[]) internal _circlesOf;
    mapping(address => mapping(address => bool)) internal _listed;
    mapping(address => Score) public score;
    Stats internal _stats;

    modifier onlyCircle() {
        _onlyCircle();
        _;
    }

    /// @param usdg_ USDG token.
    /// @param wif_ $WIF token.
    /// @param burnAddress_ Where burned $WIF is sent (0x...dEaD).
    constructor(address usdg_, address wif_, address burnAddress_) {
        if (usdg_ == address(0) || wif_ == address(0) || burnAddress_ == address(0)) revert InvalidParams();
        usdg = usdg_;
        wif = wif_;
        burnAddress = burnAddress_;
        uint8 d = IERC20Metadata(usdg_).decimals();
        usdgDecimals = d;
        maxContribution = 10_000 * 10 ** d;
    }

    /// @notice Create a new savings circle. The caller is its creator but still has to join.
    /// @param p Circle parameters; see CircleParams for bounds.
    /// @return circle Address of the new circle.
    function createCircle(CircleParams calldata p) external nonReentrant returns (address circle) {
        _validate(p);
        circle = address(new FlatCircle(p, msg.sender));
        isCircle[circle] = true;
        _circles.push(circle);
        _stats.totalCircles += 1;
        emit CircleCreated(
            circle, msg.sender, p.name, p.contribution, p.roundDuration, p.maxMembers, p.baseBond, p.orderMode
        );
    }

    // ---------------------------------------------------------------------------------------------
    // Flat Score
    // ---------------------------------------------------------------------------------------------

    /// @notice Tier of `member`: 0 New, 1 Steady, 2 Trusted, 3 Pillar, 4 Flagged (any default ever).
    function tierOf(address member) public view returns (uint8) {
        Score memory s = score[member];
        if (s.defaults > 0) return TIER_FLAGGED;
        if (s.completed >= 3) return TIER_PILLAR;
        if (s.completed == 2) return TIER_TRUSTED;
        if (s.completed == 1) return TIER_STEADY;
        return TIER_NEW;
    }

    /// @notice Bond multiplier for a tier, in percent.
    function bondMultiplier(uint8 tier) public pure returns (uint256) {
        if (tier == TIER_FLAGGED) return 200;
        if (tier == TIER_PILLAR) return 40;
        if (tier == TIER_TRUSTED) return 60;
        if (tier == TIER_STEADY) return 80;
        return 100;
    }

    /// @notice The bond `member` must lock for a circle with `baseBond`, after their tier discount
    /// or penalty. Never less than 1 base unit, so $WIF is always involved.
    function bondFor(address member, uint256 baseBond) external view returns (uint256 bond) {
        bond = (baseBond * bondMultiplier(tierOf(member))) / 100;
        if (bond == 0) bond = 1;
    }

    // ---------------------------------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------------------------------

    /// @notice Number of circles ever created.
    function circleCount() external view returns (uint256) {
        return _circles.length;
    }

    /// @notice A page of circles in creation order.
    function circlesPage(uint256 offset, uint256 limit) external view returns (address[] memory page) {
        uint256 len = _circles.length;
        if (offset >= len) return new address[](0);
        uint256 end = offset + limit > len ? len : offset + limit;
        page = new address[](end - offset);
        for (uint256 i = offset; i < end; ++i) {
            page[i - offset] = _circles[i];
        }
    }

    /// @notice Every circle `m` has ever joined (including ones they later left).
    function circlesOfMember(address m) external view returns (address[] memory) {
        return _circlesOf[m];
    }

    /// @notice Protocol-wide cumulative stats.
    function getStats() external view returns (Stats memory) {
        return _stats;
    }

    // ---------------------------------------------------------------------------------------------
    // Hooks (only callable by circles this factory deployed)
    // ---------------------------------------------------------------------------------------------

    /// @notice Records a join and the bond locked.
    function onJoined(address member, uint256 bond) external onlyCircle {
        if (!_listed[member][msg.sender]) {
            _listed[member][msg.sender] = true;
            _circlesOf[member].push(msg.sender);
        }
        _stats.totalMembersJoined += 1;
        _stats.totalWifBonded += bond;
    }

    /// @notice Records a burned bond and flags the member.
    function onBondBurned(address member, uint256 amount) external onlyCircle {
        score[member].defaults += 1;
        _stats.totalWifBurned += amount;
    }

    /// @notice Records a burned swap fee.
    function onSwapFeeBurned(uint256 amount) external onlyCircle {
        _stats.totalWifBurned += amount;
    }

    /// @notice Records a pot paid out.
    function onPayout(uint256 usdgAmount) external onlyCircle {
        _stats.totalUsdgPaidOut += usdgAmount;
    }

    /// @notice Records a bond returned to its owner.
    function onRefund(uint256 wifAmount) external onlyCircle {
        _stats.totalWifRefunded += wifAmount;
    }

    /// @notice Records a completed circle and raises the score of members who never missed.
    function onCompleted(address[] calldata cleanMembers) external onlyCircle {
        _stats.completedCircles += 1;
        for (uint256 i; i < cleanMembers.length; ++i) {
            score[cleanMembers[i]].completed += 1;
        }
    }

    // ---------------------------------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------------------------------

    function _onlyCircle() internal view {
        if (!isCircle[msg.sender]) revert NotCircle();
    }

    function _validate(CircleParams calldata p) internal view {
        uint256 nameLen = bytes(p.name).length;
        if (nameLen == 0 || nameLen > MAX_NAME_BYTES) revert InvalidParams();
        if (p.contribution == 0 || p.contribution > maxContribution) revert InvalidParams();
        if (p.roundDuration < MIN_ROUND_DURATION || p.roundDuration > MAX_ROUND_DURATION) revert InvalidParams();
        if (p.maxMembers < MIN_MEMBERS || p.maxMembers > MAX_MEMBERS) revert InvalidParams();
        if (p.baseBond == 0 || p.baseBond > MAX_WIF_PARAM) revert InvalidParams();
        if (p.swapFee > MAX_WIF_PARAM) revert InvalidParams();
        if (p.joinWindow < MIN_JOIN_WINDOW || p.joinWindow > MAX_JOIN_WINDOW) revert InvalidParams();
        uint256 al = p.allowlist.length;
        if (al > MAX_ALLOWLIST) revert InvalidParams();
        if (al > 0 && al < p.maxMembers) revert InvalidParams();
        for (uint256 i; i < al; ++i) {
            if (p.allowlist[i] == address(0)) revert InvalidParams();
        }
    }
}
