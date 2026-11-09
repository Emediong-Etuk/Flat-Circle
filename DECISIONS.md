# Decisions

One line per call made during the build, newest at the bottom.

## Phase 0

- **EVM version `cancun`.** Confirmed onchain (`TSTORE`, `MCOPY`, `PUSH0` all work). See `docs/CHAIN-FACTS.md`.
- **Storage `ReentrancyGuard`, not the transient version.** Cancun would allow transient, but the gas saving is negligible on an L2 at ~0.02 gwei, and the storage version has no tooling edge cases.
- **Solidity 0.8.28, OpenZeppelin v5.7.0, forge-std v1.17.0, Foundry 1.5.1**, all pinned. OZ is a git submodule pinned to the tag.
- **No EIP-2612 permit.** USDG's `version()` reverts. Plain `approve` + `transferFrom` everywhere.
- **Fair draw uses the future-block seed, not VRF.** Chainlink VRF v2.5 isn't listed for Robinhood Chain.
- **`DRAW_DELAY = 20` L2 blocks (~2 s).** After `seedBlock`, there are ~26 s (256 blocks) to call `draw()` before the hash expires and the contract re-arms. The UI and keeper call `draw()` automatically.
- **Burns are transfers to `0x…dEaD`,** not `WIF.burn()`, so every burn is a uniform `Transfer` event the Receipts page can index. Copy says "sent to the burn address".
- **Explorer: `robinhoodchain.blockscout.com`.** It's the one in Robinhood's docs. Verification uses `--verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/`.
- **Prices: GeckoTerminal first, DexScreener as fallback.** Both confirmed to support Robinhood Chain.
- **"Get $WIF / USDG" links go to DexScreener token pages,** not a DEX app URL we haven't confirmed for chain 4663.
- **USDG pause/freeze is a real dependency.** Paxos can pause USDG or freeze an address. Push payouts fall back to `claimableUsdg` so a frozen recipient can't brick a circle. A paused token or frozen circle contract would halt that circle. This goes in the README limitations.
- **Suggested demo bond: 1,000 WIF base (≈ $1.30).** $WIF trades around $0.0013.
