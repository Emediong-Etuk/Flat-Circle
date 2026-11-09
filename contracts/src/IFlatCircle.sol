// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice How a circle decides who receives the pot in each round.
enum OrderMode {
    JoinOrder,
    FairDraw
}

/// @notice Lifecycle of a circle.
/// Open -> (Drawing, FairDraw only) -> Active -> Completed, or Open -> Cancelled.
enum State {
    Open,
    Drawing,
    Active,
    Completed,
    Cancelled
}

/// @notice Parameters chosen by the creator of a circle.
struct CircleParams {
    string name; // 1..48 bytes
    uint256 contribution; // USDG base units per round, 0 < x <= maxContribution
    uint32 roundDuration; // seconds, 60 .. 31 days
    uint8 maxMembers; // 2..20
    uint256 baseBond; // $WIF base units, > 0
    uint256 swapFee; // $WIF base units burned on an accepted swap (0 allowed)
    uint32 joinWindow; // seconds the circle stays open to fill, 10 min .. 14 days
    bool depositRequired; // members escrow one contribution at join
    OrderMode orderMode;
    address[] allowlist; // empty = open to anyone; otherwise only these may join (max 20)
}

/// @notice A member's portable reliability record.
struct Score {
    uint32 completed;
    uint32 defaults;
}

/// @notice Protocol-wide cumulative counters.
struct Stats {
    uint64 totalCircles;
    uint64 completedCircles;
    uint64 totalMembersJoined;
    uint256 totalUsdgPaidOut;
    uint256 totalWifBonded;
    uint256 totalWifBurned;
    uint256 totalWifRefunded;
}

/// @notice One-call snapshot of a circle for the frontend.
struct CircleSummary {
    State state;
    string name;
    uint256 contribution;
    uint32 roundDuration;
    uint8 maxMembers;
    uint8 memberCount;
    uint256 baseBond;
    uint256 swapFee;
    uint32 joinWindow;
    bool depositRequired;
    OrderMode orderMode;
    bool hasAllowlist;
    address creator;
    address factory;
    uint64 createdAt;
    uint64 createdAtBlock;
    uint64 joinDeadline;
    uint256 currentRound; // 0-based; equals maxMembers once completed
    uint64 roundEndsAt;
    uint256 potSoFar; // USDG collected for the current round
    uint256 paidCount; // members who paid the current round
    uint256 seedBlock;
    bytes32 seedHash;
    uint256 makeGoodPool;
    uint256 l2BlockNumber; // current L2 block, so the UI knows when draw() is callable
}

/// @notice Per-member snapshot for the frontend.
struct MemberView {
    address account;
    uint256 bond;
    bool bondBurned;
    uint256 depositAvailable;
    bool defaulted;
    uint32 misses;
    uint256 debt;
    uint8 payoutRound; // 0-based; only meaningful once the order is set
    bool received;
    bool paidThisRound;
    uint256 claimableUsdg;
    uint256 claimableWif;
    address pendingSwapWith;
}

/// @notice Arbitrum's ArbSys precompile at 0x64 (the subset we use).
interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
    function arbBlockHash(uint256 blockNumber) external view returns (bytes32);
}

/// @notice The factory surface that circles call.
interface IFlatCircleFactory {
    error NotCircle();
    error InvalidParams();

    event CircleCreated(
        address indexed circle,
        address indexed creator,
        string name,
        uint256 contribution,
        uint32 roundDuration,
        uint8 maxMembers,
        uint256 baseBond,
        OrderMode orderMode
    );

    function usdg() external view returns (address);
    function wif() external view returns (address);
    function burnAddress() external view returns (address);
    function bondFor(address member, uint256 baseBond) external view returns (uint256);

    function onJoined(address member, uint256 bond) external;
    function onBondBurned(address member, uint256 amount) external;
    function onSwapFeeBurned(uint256 amount) external;
    function onPayout(uint256 usdgAmount) external;
    function onRefund(uint256 wifAmount) external;
    function onCompleted(address[] calldata cleanMembers) external;
}

/// @notice Events and errors of a single circle. Rounds are 0-based onchain; the UI shows round + 1.
interface IFlatCircleEvents {
    event Joined(address indexed member, uint256 bond, uint256 deposit);
    event Left(address indexed member, uint256 bondRefunded, uint256 depositRefunded);
    event Filled(uint256 memberCount);
    event Cancelled(address indexed by);
    event DrawRearmed(uint256 newSeedBlock);
    event OrderDrawn(uint256 seedBlock, bytes32 seedHash, address[] order);
    event Contributed(uint256 indexed round, address indexed member, uint256 amount);
    event DepositUsed(uint256 indexed round, address indexed member, uint256 amount);
    event BondBurned(address indexed member, uint256 amount);
    event RoundClosed(uint256 indexed round, address indexed recipient, uint256 payout, uint256 shortfall);
    event PayoutDeferred(uint256 indexed round, address indexed recipient, uint256 amount);
    event DebtRecovered(uint256 indexed round, address indexed member, uint256 amount);
    event MakeGoodCredited(uint256 indexed round, address indexed recipient, uint256 amount);
    event SwapRequested(address indexed requester, address indexed counterparty, uint256 feeEscrowed);
    event SwapCancelled(address indexed requester, address indexed counterparty, uint256 feeRefunded);
    event SwapDeclined(address indexed requester, address indexed counterparty, uint256 feeRefunded);
    event SwapAccepted(address indexed requester, address indexed counterparty, uint256 feeBurned);
    event Completed(uint256 cleanMembers);
    event Claimed(address indexed member, uint256 usdg, uint256 wif);

    error NotOpen();
    error NotActive();
    error NotDrawing();
    error Full();
    error AlreadyMember();
    error NotMember();
    error NotAllowed();
    error JoinWindowClosed();
    error JoinWindowOpen();
    error AlreadyPaid();
    error RoundNotOver();
    error TooEarly();
    error SwapNotEligible();
    error NoPendingSwap();
    error NothingToClaim();
    error UnexpectedTransferAmount();
}
