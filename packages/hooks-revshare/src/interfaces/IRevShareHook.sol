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
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";

/// @title IRevShareHook
/// @notice The surface an epoch distributor uses to collect its share of a pool's revenue share.
///
/// @dev THE ENTIRE INTERFACE IS PULL-BASED, AND THAT IS THE POINT. The hook never calls a
/// distributor, a beneficiary, or a token holder from inside a swap callback. A push to a hostile
/// or merely broken recipient reverts `afterSwap`, which reverts the swap, which makes the pool
/// untradeable for as long as the recipient stays broken. Every route out of this hook is
/// therefore initiated by the receiving side, in its own transaction, where a revert costs the
/// receiver gas and costs the pool nothing.
interface IRevShareHook {
    /// @notice Transfers the calling distributor's accrued share of `currency` for `key`'s pool.
    /// @dev Reverts unless `msg.sender` is the pool's configured distributor. Returns 0 (without
    /// reverting) when nothing has accrued, so a distributor can close an epoch that happened to
    /// receive nothing in one of the two currencies.
    /// @param key The pool whose distributor share is being collected.
    /// @param currency The currency to collect. Only the pool's own two currencies ever accrue.
    /// @return amount The amount transferred to `msg.sender`.
    function pullDistributorShare(PoolKey calldata key, Currency currency) external returns (uint256 amount);

    /// @notice Amount of `currency` waiting for `poolId`'s distributor to pull.
    function pendingDistributorShare(PoolId poolId, Currency currency) external view returns (uint256);

    /// @notice The address permitted to call `pullDistributorShare` for `poolId`, or zero.
    function distributorOf(PoolId poolId) external view returns (address);
}
