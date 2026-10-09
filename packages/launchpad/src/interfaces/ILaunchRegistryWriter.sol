/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {LaunchMetadata, LaunchpadMetadata} from "deepcore-registry/src/IDeepCoreLaunchRegistry.sol";

/// @notice The `DeepCoreLaunchRegistry` surface `LaunchpadKitV2` calls, and nothing more.
/// @dev `IDeepCoreLaunchRegistry` declares types, events and errors but no functions, so the kit names the
/// calls it makes here rather than compiling the registry implementation into its own build. The list is
/// the kit's whole privilege set on the registry: it writes its own launches (as `msg.sender`, so they are
/// `LaunchpadAttested`), lists or claims its own launchpad record, and reads two views.
interface ILaunchRegistryWriter {
    function registerLaunch(
        address poolManager,
        bytes32 poolId,
        address token,
        address launchpad,
        address creator,
        address steward,
        LaunchMetadata calldata metadata
    ) external;

    function registerLaunchpad(address launchpad, address steward, LaunchpadMetadata calldata metadata) external;

    function claimLaunchpad(address newSteward) external;

    function isLaunchpadRegistered(address launchpad) external view returns (bool);

    /// @dev `DeepCoreLaunchRegistry.vault` - the Vault whose registered apps it believes.
    function vault() external view returns (address);
}
