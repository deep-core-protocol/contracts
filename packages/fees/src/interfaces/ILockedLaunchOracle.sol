/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: MIT
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity ^0.8.20;

/// @title ILockedLaunchOracle
/// @notice The one question `DeepCoreProtocolFeeControllerV3` asks a launchpad: is this pool a launch
/// you created whose seeded liquidity is permanently locked?
///
/// @dev Independently authored and import-free so a kit (GPL) and the SDK (MIT) can both build
/// against it. `poolId` is `PoolId.unwrap(key.toId())`; the ABI of core's `PoolId` is `bytes32`, so
/// the selector is `isLockedLaunch(bytes32)` = `0x91bfe5c1` either way.
///
/// IMPLEMENTER REQUIREMENTS. The controller cannot check any of these; it relies on all of them.
///
///  1. Answer `true` ONLY for a pool this contract initialized itself, whose seeded position it
///     transferred into the DeepCore LP locker in the SAME transaction, with no `try`/`catch` between
///     writing the answer and asserting the lock. If the lock fails the transaction must revert,
///     taking the answer with it.
///  2. The answer must be written BEFORE calling `initialize`: core reads the protocol fee inside
///     `initialize`, once, and never again.
///  3. Never clear it, and never set it from any other code path (no admin, no reconfiguration).
///  4. A plain storage read: no external calls, no reentrancy-guard check (the kit is mid-call when
///     core asks), comfortably under 50,000 gas, returning exactly one ABI-encoded `bool`.
interface ILockedLaunchOracle {
    function isLockedLaunch(bytes32 poolId) external view returns (bool);
}
