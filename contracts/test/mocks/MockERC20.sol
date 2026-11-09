// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Test token with knobs: decimals, a transfer fee, and frozen addresses that can't
/// send or receive (like a Paxos freeze on USDG).
contract MockERC20 is ERC20 {
    uint8 internal immutable _dec;
    uint256 public feeBps;
    mapping(address => bool) public frozen;

    error Frozen(address account);

    constructor(string memory n, string memory s, uint8 d) ERC20(n, s) {
        _dec = d;
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setFeeBps(uint256 bps) external {
        feeBps = bps;
    }

    function setFrozen(address a, bool f) external {
        frozen[a] = f;
    }

    function _update(address from, address to, uint256 value) internal override {
        if (frozen[from]) revert Frozen(from);
        if (frozen[to]) revert Frozen(to);
        uint256 fee = from != address(0) && to != address(0) ? (value * feeBps) / 10_000 : 0;
        if (fee > 0) super._update(from, address(0), fee);
        super._update(from, to, value - fee);
    }
}
