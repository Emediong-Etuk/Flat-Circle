# Flat Circle

**Ajo without the collector: savings circles on Robinhood Chain, backed by $WIF.**

Built for the World is Flat Hackathon. Work in progress: the full README (story, architecture, deployed addresses, security & limitations) lands with the mainnet deploy.

- `contracts/`: Foundry project (Solidity 0.8.28, OpenZeppelin v5.7.0)
- `web/`: Next.js app (in progress)
- `scripts/`: deploy recorder, demo runner, keeper, chain-fact checks
- `docs/CHAIN-FACTS.md`: every chain fact we rely on and how it was checked
- `DECISIONS.md`: design calls and why

## Contracts

| Contract | What it does |
|---|---|
| `FlatCircleFactory` | Creates circles, keeps each member's Flat Score (bond tiers), tracks protocol stats. No owner. |
| `FlatCircle` | One savings circle: join with a $WIF bond (+ optional USDG deposit), fair draw, rounds, swaps, claims. No admin, no upgrades, no pause. |
| `IFlatCircle.sol` | Shared types, events and errors. |

### Tests

```bash
cd contracts
forge test                                                        # unit, fuzz, invariant (60 tests)
forge test --match-path 'test/fork/*' --fork-url $RPC_URL         # real USDG + $WIF on mainnet state
forge coverage --report summary --no-match-coverage "test/"
```

What's covered: full lifecycles with exact balances (6- and 18-decimal USDG), fair-draw permutation, determinism and re-arm on hash expiry, deposit-covered misses, shortfalls with debt recovery and pro-rata make-good, early-recipient defaults, swaps (escrow, cancel, decline, accept-and-burn, eligibility), leave/cancel/claim, allowlists, all five bond tiers, parameter bounds including the 10,000 USDG cap, circle-only factory hooks, reentrancy through malicious tokens, fee-on-transfer rejection, and payouts to frozen or failing recipients falling back to claims. Invariant tests run 8,192 random actions per run across many circles and check that USDG and $WIF are never created or lost and that the burn stat matches the burn address.

Coverage (`forge coverage`, 9 Nov 2026):

| File | Lines | Statements | Branches | Functions |
|---|---|---|---|---|
| `src/FlatCircle.sol` | 100.00% (348/348) | 98.62% (428/434) | 92.54% (62/67) | 100.00% (32/32) |
| `src/FlatCircleFactory.sol` | 100.00% (81/81) | 99.11% (111/112) | 95.65% (22/23) | 100.00% (18/18) |
| **Total** | **100.00%** | **98.72%** | **93.33%** | **100.00%** |

> Experimental and unaudited. Contributions are capped at 10,000 USDG per round. Not affiliated with Robinhood Markets, Inc.
