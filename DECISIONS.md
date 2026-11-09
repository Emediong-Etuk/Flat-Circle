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

## Phase 1

- **`leave()` shifts members down instead of swap-and-pop,** so JoinOrder stays true to the order people joined. At most 20 members, so the loop is cheap.
- **A recipient who misses their own round with no deposit creates no debt or shortfall.** They only short themselves (their pot is one contribution smaller), so nobody else is owed anything. Their bond still burns and the miss is recorded.
- **Swap-fee refunds don't count in `totalWifRefunded`.** That stat is bonds only, so `bonded = refunded + burned bonds + held` stays exact. Pending swap fees are pushed back automatically when a circle completes.
- **`NotCreator` is not used.** A non-creator calling `cancel()` before the join window closes gets `JoinWindowOpen`, which tells them what to wait for.
- **Extra events: `PayoutDeferred`, `DebtRecovered`, `MakeGoodCredited`.** They make shortfall and fallback payouts visible in the activity feed and Receipts page.
- **`via_ir = true`.** It keeps the factory (which embeds FlatCircle's init code) at 22 KB, under the 24 KB limit that anvil, Foundry's simulator and some wallets assume, even though Robinhood Chain allows 96 KB.
- **Linting is strict on `src/` only.** Tests use deliberate casts, bit shifts and raw transfers.
- **Demo swap timing: in a 3-member circle the swap must happen during round 1** (index 0), before its pot drops. After that only one member has a future turn, so no swap is possible. `DEMO-SCRIPT.md` and `scripts/demo-run.ts` follow this order.
- **Fork tests fund USDG from a real holder (the WIF/USDG pool) via `vm.prank`,** which is more reliable than `deal` on Paxos's proxy layout. $WIF is funded with `deal`.
