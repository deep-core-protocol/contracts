/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity ^0.8.26;

/// @title IWrappedNative - the two functions of a canonical wrapped-native contract DeepCore uses
/// @notice Written from the public ABI of the deployed wrapped-native contract on each chain. No
/// third-party source is vendored, imported or derived from: these are two selectors, declared here
/// so the router can call them. The address is a constructor argument, never a constant, and may be
/// zero on a chain where DeepCore does not want the router to wrap at all.
interface IWrappedNative {
    /// @notice Mints wrapped native 1:1 for the native sent with the call.
    function deposit() external payable;

    /// @notice Burns `amount` wrapped native and sends the caller the same amount of native.
    function withdraw(uint256 amount) external;
}
