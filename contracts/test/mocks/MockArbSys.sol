// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Stand-in for Arbitrum's ArbSys precompile (0x64), which doesn't exist on anvil or in forge.
/// Etch it at 0x64 with `vm.etch` (tests) or `anvil_setCode` (local fork).
/// By default it follows `block.number` (on an anvil fork that is the forked L2 block number).
/// Tests can pin the block number and set specific hashes.
contract MockArbSys {
    error InvalidBlockNumber(uint256 requested, uint256 current);

    bool public useFixed;
    uint256 public fixedNumber;
    mapping(uint256 => bytes32) public hashOverride;

    function setBlockNumber(uint256 n) external {
        useFixed = true;
        fixedNumber = n;
    }

    function setBlockHash(uint256 n, bytes32 h) external {
        hashOverride[n] = h;
    }

    function arbBlockNumber() public view returns (uint256) {
        return useFixed ? fixedNumber : block.number;
    }

    /// @dev Mirrors the real precompile: only the 256 blocks before the current one are available.
    function arbBlockHash(uint256 n) external view returns (bytes32 h) {
        uint256 cur = arbBlockNumber();
        if (n >= cur || cur - n > 256) revert InvalidBlockNumber(n, cur);
        h = hashOverride[n];
        if (h != bytes32(0)) return h;
        h = blockhash(n);
        if (h == bytes32(0)) h = keccak256(abi.encode("MockArbSys", n));
    }

    function arbChainID() external view returns (uint256) {
        return block.chainid;
    }
}
