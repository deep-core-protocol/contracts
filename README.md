<p align="center">
  <a href="https://deepcore.fun">
    <img src=".github/assets/og-image-1200x630.png" alt="DeepCore: launch on one core. Tokens, Launchpads and DEXes at deepcore.fun" width="720">
  </a>
</p>

# DeepCore Protocol contracts

The Solidity sources of DeepCore Protocol, as submitted for audit: the settlement core, the
periphery and router, DeepCore's own hooks, the launch kit, lockers, fee controllers, registry,
governance, the routed-fill contracts, limit orders and DCA, managed vaults and liquidity rewards,
each with its tests and deploy scripts.

**Live on HyperEVM · BNB Chain · Robinhood Chain · Base, at the same addresses on every chain.** The
full address set ships in the SDK address book
([`deep-sdk/src/deployments/index.ts`](https://github.com/deep-core-protocol/deep-sdk/blob/main/src/deployments/index.ts)),
written from on-chain read-back, and the contracts are verified on [Sourcify](https://sourcify.dev).

## Deployed addresses

The same address on HyperEVM (999), BNB Chain (56), Robinhood Chain (4663) and Base (8453).

| Contract | Address | Explorer |
|---|---|---|
| `Vault` | `0x405515DB94aDBF3A827349f2C096809639581D09` | [HyperEVM](https://hyperevmscan.io/address/0x405515DB94aDBF3A827349f2C096809639581D09) · [BNB](https://bscscan.com/address/0x405515DB94aDBF3A827349f2C096809639581D09) · [Robinhood](https://robin.etherscan.io/address/0x405515DB94aDBF3A827349f2C096809639581D09) · [Base](https://basescan.org/address/0x405515DB94aDBF3A827349f2C096809639581D09) |
| CL pool manager (`CLPoolManager`) | `0xE23978EBBf83Eab3f0226674d1183b5D3ED32FeC` | [HyperEVM](https://hyperevmscan.io/address/0xE23978EBBf83Eab3f0226674d1183b5D3ED32FeC) · [BNB](https://bscscan.com/address/0xE23978EBBf83Eab3f0226674d1183b5D3ED32FeC) · [Robinhood](https://robin.etherscan.io/address/0xE23978EBBf83Eab3f0226674d1183b5D3ED32FeC) · [Base](https://basescan.org/address/0xE23978EBBf83Eab3f0226674d1183b5D3ED32FeC) |
| Bin pool manager (`BinPoolManager`) | `0x004a786C4cB79358e2f86467B0eBFD87028648F4` | [HyperEVM](https://hyperevmscan.io/address/0x004a786C4cB79358e2f86467B0eBFD87028648F4) · [BNB](https://bscscan.com/address/0x004a786C4cB79358e2f86467B0eBFD87028648F4) · [Robinhood](https://robin.etherscan.io/address/0x004a786C4cB79358e2f86467B0eBFD87028648F4) · [Base](https://basescan.org/address/0x004a786C4cB79358e2f86467B0eBFD87028648F4) |
| `UniversalRouter` | `0xF480dE4ff93257c18caD36F93E0EeB85A5d5819a` | [HyperEVM](https://hyperevmscan.io/address/0xF480dE4ff93257c18caD36F93E0EeB85A5d5819a) · [BNB](https://bscscan.com/address/0xF480dE4ff93257c18caD36F93E0EeB85A5d5819a) · [Robinhood](https://robin.etherscan.io/address/0xF480dE4ff93257c18caD36F93E0EeB85A5d5819a) · [Base](https://basescan.org/address/0xF480dE4ff93257c18caD36F93E0EeB85A5d5819a) |
| Routed-fill router (`DeepCoreFillRouter`) | `0x7878624417E9d69219EAdD14bA1B01459C87b578` | [HyperEVM](https://hyperevmscan.io/address/0x7878624417E9d69219EAdD14bA1B01459C87b578) · [BNB](https://bscscan.com/address/0x7878624417E9d69219EAdD14bA1B01459C87b578) · [Robinhood](https://robin.etherscan.io/address/0x7878624417E9d69219EAdD14bA1B01459C87b578) · [Base](https://basescan.org/address/0x7878624417E9d69219EAdD14bA1B01459C87b578) |
| Launch kit (`LaunchpadKitV2`) | `0x78781DC6a34F0dcA85929Db22e04815096aAD378` | [HyperEVM](https://hyperevmscan.io/address/0x78781DC6a34F0dcA85929Db22e04815096aAD378) · [BNB](https://bscscan.com/address/0x78781DC6a34F0dcA85929Db22e04815096aAD378) · [Robinhood](https://robin.etherscan.io/address/0x78781DC6a34F0dcA85929Db22e04815096aAD378) · [Base](https://basescan.org/address/0x78781DC6a34F0dcA85929Db22e04815096aAD378) |
| Launchpad / DEX factory (`DeepCorePadFactory`) | `0x7878647BCeBc138d3Af70a49399C06C5fbFBce78` | [HyperEVM](https://hyperevmscan.io/address/0x7878647BCeBc138d3Af70a49399C06C5fbFBce78) · [BNB](https://bscscan.com/address/0x7878647BCeBc138d3Af70a49399C06C5fbFBce78) · [Robinhood](https://robin.etherscan.io/address/0x7878647BCeBc138d3Af70a49399C06C5fbFBce78) · [Base](https://basescan.org/address/0x7878647BCeBc138d3Af70a49399C06C5fbFBce78) |
| Protocol fee controller (`DeepCoreProtocolFeeControllerV4`) | `0x7878BAB23799d3e015998906Ea33327C183e3d78` | [HyperEVM](https://hyperevmscan.io/address/0x7878BAB23799d3e015998906Ea33327C183e3d78) · [BNB](https://bscscan.com/address/0x7878BAB23799d3e015998906Ea33327C183e3d78) · [Robinhood](https://robin.etherscan.io/address/0x7878BAB23799d3e015998906Ea33327C183e3d78) · [Base](https://basescan.org/address/0x7878BAB23799d3e015998906Ea33327C183e3d78) |
| CL LP locker (`DeepCoreLPLocker`) | `0x7878cB60Ba330c34ffA027Cdd062696eD9D08878` | [HyperEVM](https://hyperevmscan.io/address/0x7878cB60Ba330c34ffA027Cdd062696eD9D08878) · [BNB](https://bscscan.com/address/0x7878cB60Ba330c34ffA027Cdd062696eD9D08878) · [Robinhood](https://robin.etherscan.io/address/0x7878cB60Ba330c34ffA027Cdd062696eD9D08878) · [Base](https://basescan.org/address/0x7878cB60Ba330c34ffA027Cdd062696eD9D08878) |
| Bin LP locker (`DeepCoreBinLPLocker`) | `0x7878B240E282026e2318f69966A5e1c44293dc78` | [HyperEVM](https://hyperevmscan.io/address/0x7878B240E282026e2318f69966A5e1c44293dc78) · [BNB](https://bscscan.com/address/0x7878B240E282026e2318f69966A5e1c44293dc78) · [Robinhood](https://robin.etherscan.io/address/0x7878B240E282026e2318f69966A5e1c44293dc78) · [Base](https://basescan.org/address/0x7878B240E282026e2318f69966A5e1c44293dc78) |
| CL launch guard (`LaunchGuardHook`) | `0x787888386b536536176aC6E0b0F3f398A929db78` | [HyperEVM](https://hyperevmscan.io/address/0x787888386b536536176aC6E0b0F3f398A929db78) · [BNB](https://bscscan.com/address/0x787888386b536536176aC6E0b0F3f398A929db78) · [Robinhood](https://robin.etherscan.io/address/0x787888386b536536176aC6E0b0F3f398A929db78) · [Base](https://basescan.org/address/0x787888386b536536176aC6E0b0F3f398A929db78) |
| Bin launch guard (`BinLaunchGuardHook`) | `0x787802F88BB73FcF49B3e879A47bDB1C42852178` | [HyperEVM](https://hyperevmscan.io/address/0x787802F88BB73FcF49B3e879A47bDB1C42852178) · [BNB](https://bscscan.com/address/0x787802F88BB73FcF49B3e879A47bDB1C42852178) · [Robinhood](https://robin.etherscan.io/address/0x787802F88BB73FcF49B3e879A47bDB1C42852178) · [Base](https://basescan.org/address/0x787802F88BB73FcF49B3e879A47bDB1C42852178) |

Every other contract (registries, position managers, quoters, token and position locks, multisend,
Merkle drops, splits, dynamic-fee hooks, revenue-share hook) is in the address book.

## Features

DeepCore is one shared liquidity core that Launchpads and DEXes build on, instead of each deploying
its own AMM. This repository holds every contract behind it:

- **One shared core.** A single Vault with concentrated-liquidity (CL) and Bin pool managers, on the
  Infinity architecture. Settlement compiles against EIP-1153 transient storage or a storage backend
  from the same source.
- **Token launches.** `LaunchpadKitV2` opens a launch in one transaction on a CL range or a shaped Bin
  distribution, tradable on the real pool from the first block, with the liquidity locked forever by
  `DeepCoreLPLocker` / `DeepCoreBinLPLocker`. No curve contract and no migration.
- **Anti-snipe fee.** The launch guards charge an opening fee of up to 50% on CL (10% on Bin) that
  decays to the pool's trade fee over a window of at least 60 seconds, for example 50% to 0.3%.
- **Creator tax.** Optional buy and sell rates up to 10%, expiring on their own (at most 180 days,
  with no transaction), and frozen, like the whole launch configuration, from the first trade.
- **Launchpads and DEXes in one transaction.** `DeepCorePadFactory` creates a Launchpad or DEX as a
  clone at the same address on every chain, with its owner, name, brand and launch terms (including
  its own fee share) stored on chain.
- **Routing.** Trades on DeepCore pools pay no router fee; `DeepCoreFillRouter` fills a trade on
  another venue for 0.15% (`feeBps()` on chain), under an immutable cap.
- **Locks and distribution.** Liquidity locks, token locks and vesting, Merkle airdrops, team splits
  and multisend.
- **Hooks.** Dynamic-fee hooks for CL and Bin pools, a revenue-share hook, market-hours and
  stock-pair hooks with price-band oracles, an on-chain price oracle module, and a registry that
  records what each hook may do.
- **Orders, vaults and rewards.** `DeepCoreRangeOrders` (CL limit orders) and `DeepCoreDCA` are Vault
  lockers that need no hook, so they work on any pool; `DeepCoreManagedVault` clones hold two positions
  around the oracle's TWAP and never swap; `DeepCoreLiquidityRewardsHook` streams project-funded
  rewards to in-range liquidity. Every fee is frozen per order, plan or vault inside an immutable cap.
- **Bounded admin.** The contracts are owned by a 2-of-3 Safe multisig. Fees and caps are immutable
  or move only behind notice delays written in the contracts (an increase waits, a decrease applies at
  once), and `renounceOwnership` is disabled on DeepCore's own contracts. Every upkeep call is
  permissionless.

## Packages

| Package | What it is | Licence |
|---|---|---|
| `packages/core` | Vault, CL and Bin pool managers, libraries. A fork of `pancakeswap/infinity-core` with a hardened Vault and two transient-storage backends | GPL-2.0-or-later |
| `packages/periphery` | Position managers, quoters. A fork of `pancakeswap/infinity-periphery` | GPL-2.0-or-later |
| `packages/router` | UniversalRouter. A fork of `pancakeswap/infinity-universal-router` | GPL-2.0-or-later (file headers) |
| `packages/hooks` | Base hooks, the launch guards and creator tax, the dynamic-fee hooks | GPL-2.0-or-later |
| `packages/hooks-revshare` | Revenue-share hook and the epoch distributors | GPL-2.0-or-later |
| `packages/hooks-rwa` | Market-hours, stock-pair and permissioned-pool hooks, price-band oracles | GPL-2.0-or-later |
| `packages/launchpad` | `LaunchpadKitV2`, lockers, token factory, Launchpad factory, splits, locks, multisend, Merkle drops | GPL-2.0-or-later |
| `packages/launch-periphery` | Launch-and-buy | GPL-2.0-or-later |
| `packages/registry` | The hook registry and the launch registry | GPL-2.0-or-later |
| `packages/fees` | Protocol fee controllers | GPL-2.0-or-later |
| `packages/governance` | Timelock and votes token | GPL-2.0-or-later |
| `packages/routing` | Routed-fill router and executor | GPL-2.0-or-later |
| `packages/orders` | `DeepCoreRangeOrders` (CL limit orders) and `DeepCoreDCA` (scheduled swaps): Vault lockers, not hooks | GPL-2.0-or-later |
| `packages/vaults` | `DeepCoreVaultFactory` and `DeepCoreManagedVault` clones: managed liquidity around the oracle TWAP | GPL-2.0-or-later |
| `packages/lp-rewards` | `DeepCoreLiquidityRewardsHook`: project-funded rewards streamed to in-range CL liquidity | GPL-2.0-or-later |

Upstream copyright notices and licence headers are kept as shipped. The upstream audit reports the
forks came with are under `packages/periphery/audits` and `packages/router/audits`; they cover the
upstream code, not DeepCore's changes.

## Build and test

Requires [Foundry](https://getfoundry.sh) 1.8.1.

```sh
git clone --recurse-submodules https://github.com/deep-core-protocol/contracts
cd contracts/packages/<package>
forge test                          # default profile: EIP-1153 transient storage, evm_version cancun
FOUNDRY_PROFILE=legacy forge test   # legacy profile: storage backend, evm_version shanghai
```

Every package builds under both profiles from the same source. Packages find each other by relative
path (`../core`, `../hooks`, ...), so keep the `packages/` layout as it is.

Two things to know before building:

- **Do not initialise `packages/periphery/lib/infinity-core` or `packages/router/lib/infinity-periphery`.**
  They are not carried here on purpose. Periphery and the router compile against this repository's
  `packages/core` and `packages/periphery` through their remappings; an upstream copy would silently
  substitute the unhardened Vault.
- **`packages/launchpad` is a via-IR build** and needs roughly 6 GB of memory per compiler process.
  `packages/orders`, `packages/vaults` and `packages/lp-rewards` are via-IR too (the last two pin low
  optimizer runs to fit EIP-170; `lp-rewards` compiles the real `CLPositionManager` at 9,000 runs for
  its tests). Build one package at a time on a small machine.

## What differs from upstream, in one paragraph

`Vault.sync()` is gated by `isLocked` and `Vault.lock()` clears the reserve slots on exit, in both
builds, so no reserve written during a lock can survive it; this matters on the storage backend,
where values persist across transactions. The settlement layer is compiled against one of two
API-identical transient backends chosen per build profile. The regression guard is
`packages/core/test/transient/TransientBackendSafety.t.sol`.

## Reporting

Security reports: contact@deepcore.fun.
