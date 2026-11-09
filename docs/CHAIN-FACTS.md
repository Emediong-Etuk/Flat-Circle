# Robinhood Chain: confirmed facts

Checked on **9 Nov 2026** against mainnet (`https://rpc.mainnet.chain.robinhood.com`) and the official docs at `docs.robinhood.com/chain`. Each row says how it was checked so anyone can re-run it.

`R=https://rpc.mainnet.chain.robinhood.com` in the commands below.

## Network

| Fact | Value | How checked |
|---|---|---|
| Chain ID | `4663` (`0x1237`) | `cast chain-id -r $R` → `4663`; docs `/chain/connecting` |
| Stack | Arbitrum Nitro L2, Ethereum blobs for DA | docs `/chain/connecting` |
| Native gas token | ETH | docs `/chain/connecting` |
| ArbOS | `arbOSVersion()` returns `116` (Arbitrum reports ArbOS version + 55, so ArbOS 61) | `cast call 0x…64 'arbOSVersion()(uint256)' -r $R` |
| Public RPC | `https://rpc.mainnet.chain.robinhood.com` (rate-limited, docs say "not for production") | docs `/chain/connecting` |
| QuickNode endpoint format | `https://{ENDPOINT}.robinhood-mainnet.quiknode.pro/{TOKEN}` | docs `/chain/connecting` |
| Recommended provider | Alchemy: `https://robinhood-mainnet.g.alchemy.com/v2/{API_KEY}` | docs `/chain/connecting` |
| **Official explorer** | **`https://robinhoodchain.blockscout.com`** (Blockscout). `explorer.chain.robinhood.com` does not serve mainnet; `explorer.testnet.chain.robinhood.com` is testnet. | docs `/chain/connecting`, `/chain/add-network-to-wallet`, `/chain/deploy-smart-contracts` |
| Verification | `forge verify-contract … --chain-id 4663 --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/` | docs `/chain/deploy-smart-contracts` |
| Block time | ~**0.102 s** (10,000 blocks averaged) | timestamps of `arbBlockNumber` and `arbBlockNumber - 10000` |
| Gas price at check time | ~0.020 gwei | `cast gas-price -r $R` → `20108000` |
| Ordering | First-come-first-served by sequencer arrival; no priority gas auctions | docs `/chain/differences-from-ethereum` |
| Screening | Sequencer excludes transactions tied to sanctioned addresses; reads unaffected | docs `/chain/differences-from-ethereum` |
| Max contract size | 96 KB code, 192 KB init code | docs `/chain/differences-from-ethereum` |

## EVM version: `cancun` confirmed

Tested by running tiny init-code snippets with `cast call -r $R --create <bytecode>`:

| Opcode | Fork | Result |
|---|---|---|
| `PUSH0` | Shanghai | works |
| `TSTORE` / `TLOAD` | Cancun | works (returned `1`) |
| `MCOPY` | Cancun | works (returned `0x2a`) |
| `CLZ` | Osaka | works (returned `255`) |
| `BLOBBASEFEE` | Cancun | **not supported**: "BLOBBASEFEE is not supported on Arbitrum" |
| `PREVRANDAO` | — | returns constant `1` (not randomness) |
| `NUMBER` | — | returns the **L1** block number (`0x1928323` ≈ 26.38M), not L2 |

We compile with `evm_version = "cancun"`. Solidity never emits `BLOBBASEFEE` unless `block.blobbasefee` is used, and we don't use it.

## ArbSys precompile (`0x0000000000000000000000000000000000000064`)

| Fact | Value | How checked |
|---|---|---|
| `arbBlockNumber()` | real L2 block (~110.26M) | `cast call 0x…64 'arbBlockNumber()(uint256)' -r $R` |
| `arbChainID()` | `4663` | `cast call 0x…64 'arbChainID()(uint256)' -r $R` |
| `arbBlockHash(n)` | matches `eth_getBlockByNumber(n).hash` for recent blocks | compared with `cast block <n> -f hash` |
| `arbBlockHash` window | **reverts outside the last 256 blocks** with `InvalidBlockNumber(requested, current)` (selector `0xd5dc642d`) | called with `L-255` and `L-260` while the chain moved on |
| Window in time | 256 × 0.102 s ≈ **26 seconds** | |
| On anvil | calls to `0x64` fail with `InvalidFEOpcode` → we need `MockArbSys` | anvil fork test |

## Tokens

### USDG (Paxos Global Dollar)

| Fact | Value | How checked |
|---|---|---|
| Address | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` | docs `/chain/contracts` lists it; onchain `symbol()` = `USDG` |
| `name()` / `symbol()` | `Global Dollar` / `USDG` | `cast call` |
| **`decimals()`** | **`6`** | `cast call $U 'decimals()(uint8)' -r $R` |
| Proxy | yes, EIP-1967; implementation `0x68184c449e1a8f34fa18d289737129fd27b66f8f` at check time | `cast storage $U 0x3608…2bbc` |
| `version()` | **reverts** with custom error `0x800ab12c` | `cast call $U 'version()(string)'` |
| `DOMAIN_SEPARATOR()` | exists, but given `version()` reverts, **we do not use permit** | `cast call` |
| Admin controls | `owner()` = `0xcFA0388f5ddf905FdC08c45c716C15Dc10A14C6F`, `paused()` exists (currently `false`), `isFrozen(address)` exists. Paxos can pause the token and freeze addresses. | `cast call` |
| Transfer behaviour | exact amounts on `transfer` and `transferFrom`; zero-amount transfer succeeds | anvil fork: impersonated the WIF/USDG pool, moved 1,234,567 and 1,000,000 base units, balance deltas exact |
| USD price | ≈ $0.9998 | GeckoTerminal simple price API |

### $WIF (World is Flat)

| Fact | Value | How checked |
|---|---|---|
| Address | `0x5173b8eA6923c2d40267890D45C46a3480954773` | onchain `name()` = `World is Flat`, `symbol()` = `WIF` |
| **`decimals()`** | **`18`** | `cast call $W 'decimals()(uint8)' -r $R` |
| Supply | `999,996,177.10…` WIF. It started at 1B and `burn()` reduces supply, so ~3,823 WIF have been burned that way. | `totalSupply()` |
| Contract type | minimal ERC20, **not a proxy**, no `owner()`, no `paused()`; has `burn(uint256)` and `burnFrom(address,uint256)` plus metadata views (`description()` = "Finance is the last unflat thing. That's your leverage.", an IPFS logo URI) | `cast selectors $(cast code $W)`, `cast call` |
| Burn address holds | ~116,272 WIF at `0x…dEaD` already | `balanceOf(0x…dEaD)` |
| Transfer behaviour | exact amounts on `transfer` and `transferFrom`; transfer to `0x…dEaD` succeeds and emits one `Transfer` log | anvil fork |
| USD price | ≈ **$0.0013** per WIF, so 1,000 WIF ≈ $1.30 | GeckoTerminal + DexScreener |

### Burn address

`0x000000000000000000000000000000000000dEaD`, passed to the factory as an immutable constructor parameter. Burns are `transfer(dEaD, amount)`, so every burn appears uniformly as a `Transfer` to `0x…dEaD` and is counted in `stats.totalWifBurned`. These don't lower `totalSupply()` (unlike `WIF.burn()`); the docs and UI say "sent to the burn address".

## Randomness / Chainlink VRF

- **Chainlink VRF v2.5 is not live on Robinhood Chain.** The supported-networks page (`docs.chain.link/vrf/v2-5/supported-networks`, fetched 9 Nov 2026) mentions Robinhood only in the Data Feeds nav ("tokenized equity feeds"), not as a VRF network.
- Robinhood docs (`/chain/differences-from-ethereum`): `prevrandao` is constant; use an oracle such as Chainlink VRF; `blockhash` is "only reliable for recent blocks".
- → We use the **future-block seed** design (seed = `arbBlockHash(seedBlock)` with re-arm on expiry). Limits are in the README security section.

## Prices and DEXes

| Source | Supports Robinhood Chain? | Notes |
|---|---|---|
| GeckoTerminal | yes, network id `robinhood` | `GET https://api.geckoterminal.com/api/v2/simple/networks/robinhood/token_price/<addr1>,<addr2>` returns both prices. **Primary price source.** |
| DexScreener | yes, chain id `robinhood` | `GET https://api.dexscreener.com/latest/dex/tokens/<addr>`. Fallback source. |

$WIF pools at check time (DexScreener):

| Pool | DEX | Liquidity |
|---|---|---|
| WIF/ETH `0x71ef…8c79` (v4 pool id) | Uniswap | ~$97k |
| WIF/WETH `0xB0C7…e5aA` | Up V3 | ~$29k |
| WIF/USDG `0xc3A4…802c` | Up V3 | ~$6k |

USDG has deep Uniswap pools on Robinhood Chain against many tokens. The UI's "Get $WIF / USDG" helper links to the **DexScreener pages** for these tokens (confirmed URLs, each links to a swap). We do not link to a DEX app URL we haven't confirmed supports chain 4663.

## Local-fork gotchas

- `anvil --fork-url $R --chain-id 4663` works.
- ArbSys at `0x64` does not exist on anvil → `MockArbSys` etched with `vm.etch` (tests) or `anvil_setCode` (local fork).
- On anvil, `block.number` returns the forked **L2** number, while mainnet returns the **L1** number. Our contracts never read `block.number`; all L2 block logic goes through `_l2BlockNumber()`.

## Sandbox notes (affects how we deploy, not the design)

- Blockscout's web pages and `/api` returned a Cloudflare challenge to command-line requests from this build sandbox. `forge verify-contract` may need to run from Greg's machine. We'll try from here first at deploy time.
