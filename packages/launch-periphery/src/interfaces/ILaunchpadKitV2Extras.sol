/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {LegParams} from "deepcore-launchpad/src/interfaces/ILaunchpadKitV2.sol";

/// @notice The parts of `LaunchpadKitV2` this package reads that `ILaunchpadKitV2` does not declare:
/// two public immutables and one public view.
///
/// @dev `LegParams` and `PoolKey` are imported from their real definitions rather than restated, so a
/// change to either in `packages/launchpad` or `packages/core` is a compile error here rather than a
/// silent mis-encoding. The two getters take no arguments, so their selectors cannot drift with a
/// return type; `computeLegKey`'s does depend on `LegParams`, which is precisely why it is imported.
interface ILaunchpadKitV2Extras {
    function clPoolManager() external view returns (address);

    function binPoolManager() external view returns (address);

    function computeLegKey(address token, LegParams calldata leg)
        external
        view
        returns (PoolKey memory key, bytes32 poolId, bool launchTokenIsCurrency0);
}
