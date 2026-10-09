/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";

/// @notice The one thing the registries need from the Vault.
/// @dev Declared here rather than importing `IVault` because upstream declares `isAppRegistered`
/// as `external returns (bool)` — non-view — while the implementation is a public mapping getter
/// and therefore genuinely `view`. Importing the upstream interface would force every read path in
/// both registries to be non-view for no reason. Never rename this function: it is the Vault's ABI.
interface IVaultAppRegistry {
    function isAppRegistered(address app) external view returns (bool);
}

/// @title PoolProof
/// @notice The chain of custody that turns "somebody says this pool exists" into a fact.
///
/// @dev ############ WHY THIS IS A LIBRARY AND NOT A COPY IN EACH REGISTRY ############
///
/// Both `DeepCoreRegistry` (which attests a DeepCore's permission bitmap) and `DeepCoreLaunchRegistry`
/// (which attests that a launch's pool is real) rest on the same three-step proof, and it is the
/// only load-bearing security logic either of them has. Two copies of it is two chances to fix a
/// bug in one place and not the other, so there is exactly one copy and both call it.
///
/// ############################ WHAT THE PROOF ESTABLISHES ############################
///
/// A `PoolKey` read back out of a pool manager is not a claim, it is a measurement, because of how
/// it got there:
///
///   - `CLPoolManager.initialize` / `BinPoolManager.initialize` call `Hooks.validateHookConfig`,
///     which requires `poolKey.hooks.getHooksRegistrationBitmap() == poolKey.parameters` bitmap.
///     That is the only time core ever asks the hook anything.
///   - Immediately after, the manager writes `poolIdToPoolKey[id] = key`.
///   - Every dispatch from then on reads `key.parameters`, never the hook. `parameters` is part of
///     the pool id, so it is IMMUTABLE for the life of that pool.
///
/// So the stored key is a bitmap the hook answered with at least once, under core's own eyes and
/// not ours, and it is what that pool enforces today. A hook cannot lie to this, because the lie
/// would have stopped the pool existing.
///
/// The trust anchor is the Vault, not a list either registry keeps. A pool manager is believed iff
/// `Vault.isAppRegistered(manager)`, which is `onlyOwner` on the 48h custody timelock and grants
/// permanent authority to move Vault funds. Anything trusted that far is trusted to report its own
/// pool keys. A curator-managed allowlist instead would let an Ops hot key enroll a fake "pool
/// manager" and mint proofs for anything it liked, which is the laundering this closes.
///
/// ####################### THE ERRORS ARE DELIBERATELY DUPLICATE #######################
///
/// `UntrustedPoolManager`, `PoolNotFound` and `PoolHookMismatch` are also declared on
/// `IDeepCoreRegistry`. Error selectors come from the signature and not from the declaring scope, so
/// these revert with the identical four bytes and every existing consumer — tests included — keeps
/// matching. Do not "unify" them by making this library import the interface: the dependency would
/// run the wrong way, and a library that pulls in a registry interface cannot be reused by the next
/// contract that needs the proof.
library PoolProof {
    using PoolIdLibrary for PoolKey;

    /// @notice The pool manager named is not an app the Vault has registered, so nothing it says
    /// about its own pools can be trusted.
    error UntrustedPoolManager(address poolManager);

    /// @notice The manager holds no pool under that id, or the key it holds does not hash back to
    /// it. Either way there is no initialized pool to read from.
    error PoolNotFound(address poolManager, bytes32 poolId);

    /// @notice The pool exists, but its `hooks` field is a different contract.
    error PoolHookMismatch(bytes32 poolId, address expected, address found);

    /// @notice Gate every read below on the Vault having registered this manager as an app.
    /// @dev Kept separate from `verifiedKey` so callers can preserve their own check ordering. Both
    /// registries run it FIRST, before any other validation, so that an untrusted manager is always
    /// reported as untrusted rather than as whatever its fabricated storage happens to look like.
    function requireTrustedManager(IVaultAppRegistry vault, address poolManager) internal view {
        if (!vault.isAppRegistered(poolManager)) revert UntrustedPoolManager(poolManager);
    }

    /// @notice Resolve `poolId` on `poolManager` and return the key, or revert.
    ///
    /// @dev Three independent checks, each closing a different way the lookup could be meaningless:
    ///   1. the stored key names this manager — core's own `poolManagerMatch` guarantees it at
    ///      initialization, so a mismatch means the entry was never written by `initialize`;
    ///   2. the stored key hashes back to the id asked for — a manager that returned one fixed key
    ///      for every id would fail here;
    ///   3. an uninitialized slot returns the zero key, whose `poolManager` is `address(0)`, so
    ///      check 1 already rejects every id that was never opened.
    ///
    /// The key is READ BACK rather than accepted from a caller. Callers that hold a `PoolKey` must
    /// use it only to derive the id; every field is then re-read here, so a doctored key changes
    /// the id and simply fails to resolve.
    function verifiedKey(address poolManager, bytes32 poolId) internal view returns (PoolKey memory key) {
        (
            Currency currency0,
            Currency currency1,
            IHooks hooks,
            IPoolManager keyManager,
            uint24 fee,
            bytes32 parameters
        ) = IPoolManager(poolManager).poolIdToPoolKey(PoolId.wrap(poolId));

        if (address(keyManager) != poolManager) revert PoolNotFound(poolManager, poolId);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: hooks,
            poolManager: keyManager,
            fee: fee,
            parameters: parameters
        });
        if (PoolId.unwrap(key.toId()) != poolId) revert PoolNotFound(poolManager, poolId);
    }

    /// @notice `verifiedKey`, plus the requirement that the pool actually runs `hook`.
    /// @dev An attestation only ever speaks for the hook the pool really runs. `address(0)` is a
    /// legitimate `hooks` value for a plain pool, so callers that accept hookless pools must not
    /// route through this overload.
    function verifiedKeyFor(address poolManager, bytes32 poolId, address hook)
        internal
        view
        returns (PoolKey memory key)
    {
        key = verifiedKey(poolManager, poolId);
        if (address(key.hooks) != hook) revert PoolHookMismatch(poolId, hook, address(key.hooks));
    }
}
