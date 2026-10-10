<p align="center">
  <a href="https://deepcore.fun">
    <img src=".github/assets/og-image-1200x630.png" alt="DeepCore: launch on one core. Tokens, Launchpads and DEXes at deepcore.fun" width="720">
  </a>
</p>

# DeepCore Protocol contracts

The Solidity sources of DeepCore Protocol, as submitted for audit: the settlement core, the
periphery and router, DeepCore's own hooks, the launch kit, lockers, fee controllers, registry,
governance and the routed-fill contracts, each with its tests and deploy scripts.

Deployed addresses are published in the SDK address book, written only from on-chain read-back.

## Features

DeepCore is one shared liquidity core that Launchpads and DEXes build on, instead of each deploying
its own AMM. This repository holds every contract behind it:

- **One shared core.** A single Vault with concentrated-liquidity (CL) and Bin pool managers, on the
  Infinity architecture, with HyperEVM as the first chain. Settlement compiles against EIP-1153
  transient storage or a storage backend from the same source.
- **Launchpads and DEXes in one transaction.** `DeepCorePadFactory` creates a Launchpad or DEX site as
  a clone with its owner, name and brand stored on chain.
- **Token launches.** `LaunchpadKitV2` opens a launch on a CL range or a shaped Bin distribution,
  tradable on the real pool from the first block, with the liquidity locked by `DeepCoreLPLocker` /
  `DeepCoreBinLPLocker`. The launch guards apply an anti-snipe fee that decays over the opening
  window and an optional, time-limited creator tax.
- **Utilities.** Liquidity locks, token locks and vesting, multisend, Merkle airdrops and team splits.
- **Hooks.** Revenue-share, dynamic-fee, market-hours and stock-pair hooks, price-band oracles, and a
  registry that records what each hook is permitted to do.
- **Routing.** `DeepCoreFillRouter` fills a trade on DeepCore pools or another venue, for a fee that
  sits under an immutable cap.
- **Bounded admin.** Every protocol fee lives inside a cap fixed in the contract; increases take
  effect only after a public notice period, decreases apply at once, and `renounceOwnership` is
  disabled on DeepCore's own contracts. Governance is a multisig with a timelock.

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

## What differs from upstream, in one paragraph

`Vault.sync()` is gated by `isLocked` and `Vault.lock()` clears the reserve slots on exit, in both
builds, so no reserve written during a lock can survive it; this matters on the storage backend,
where values persist across transactions. The settlement layer is compiled against one of two
API-identical transient backends chosen per build profile. The regression guard is
`packages/core/test/transient/TransientBackendSafety.t.sol`.

## Reporting

Security reports: contact@deepcore.fun.
