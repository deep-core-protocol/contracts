/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {DeepCoreMetadata} from "deepcore-registry/src/IDeepCoreRegistry.sol";

/// @notice The three registry entry points the launchpad kit uses.
/// @dev `IDeepCoreRegistry` declares the registry's events, errors and types but no functions -
/// its callable surface lives on the concrete `DeepCoreRegistry`. This narrow interface lets the
/// kit call that surface without compiling the whole registry implementation into its own build,
/// and makes the exact privileges the kit exercises legible at a glance: it may list a hook and
/// hand the listing over. It cannot verify, deprecate or flag anything.
interface IHookRegistryListing {
    function register(address hook, DeepCoreMetadata calldata metadata) external;

    function transferSteward(address hook, address newSteward) external;

    function isRegistered(address hook) external view returns (bool);
}
