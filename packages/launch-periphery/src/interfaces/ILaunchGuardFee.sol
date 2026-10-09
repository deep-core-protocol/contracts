/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

/// @notice The one read `DeepCoreLaunchAndBuy` makes of a launch guard: the LP fee a swap pays NOW.
///
/// @dev Declared here rather than imported so this contract compiles without pulling either guard's
/// full source into its compilation unit. Both `LaunchGuardHook` and `BinLaunchGuardHook` declare
/// `currentFee(PoolId)`, and `PoolId` is a user-defined value type over `bytes32`, so the ABI
/// signature - and therefore the selector - is `currentFee(bytes32)`. That equivalence is not
/// assumed: `test_SELECTOR_currentFeeMatchesBothGuards` calls both guards through this interface and
/// through their own types and asserts the answers agree.
///
/// It reverts (`LaunchNotConfigured`) for a pool no launch has claimed, which is the correct
/// behaviour here - this contract only ever reads a pool the kit configured microseconds earlier.
interface ILaunchGuardFee {
    function currentFee(bytes32 poolId) external view returns (uint24);
}
