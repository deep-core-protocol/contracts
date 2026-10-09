/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {
    RiskClass,
    PERM_BEFORE_SWAP,
    PERM_AFTER_SWAP,
    PERM_AFTER_ADD_LIQUIDITY,
    PERM_AFTER_REMOVE_LIQUIDITY,
    PERM_BEFORE_REMOVE_LIQUIDITY,
    PERM_BEFORE_SWAP_RETURNS_DELTA,
    PERM_AFTER_SWAP_RETURNS_DELTA,
    PERM_AFTER_ADD_LIQUIDITY_RETURNS_DELTA,
    PERM_AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA,
    PERM_RESERVED_BITS,
    PERM_RETURNS_DELTA_MASK,
    PERM_BEFORE_MASK
} from "../IDeepCoreRegistry.sol";

/// @title PermissionMath
/// @notice One definition of what a permission bitmap MEANS.
///
/// @dev A capability class is the single most consequential thing either registry prints next to a
/// contract, and the launch index prints it for the hook sitting in a launched pool's swap path.
/// If `DeepCoreRegistry` and `DeepCoreLaunchRegistry` each carried their own copy of `classify`, the day
/// somebody adds a bit to the returns-delta family the two surfaces would disagree about the same
/// pool — and the reader would have no way to tell which screen to believe. So there is one copy,
/// here, and `DeepCoreRegistry.classify` / `isValidBitmap` stay on the ABI as thin forwards.
///
/// Pure, stateless, and deliberately free of any notion of who is asking.
library PermissionMath {
    /// @notice Whether a bitmap is one core would accept.
    /// @dev Mirrors `BaseCLHook._validatePermissions`.
    function isValidBitmap(uint16 permissions) internal pure returns (bool) {
        return permissions & PERM_RESERVED_BITS == 0 && dependenciesSatisfied(permissions);
    }

    /// @dev A returns-delta bit is meaningless without the callback that returns the delta.
    function dependenciesSatisfied(uint16 p) internal pure returns (bool) {
        if (p & PERM_BEFORE_SWAP_RETURNS_DELTA != 0 && p & PERM_BEFORE_SWAP == 0) return false;
        if (p & PERM_AFTER_SWAP_RETURNS_DELTA != 0 && p & PERM_AFTER_SWAP == 0) return false;
        if (p & PERM_AFTER_ADD_LIQUIDITY_RETURNS_DELTA != 0 && p & PERM_AFTER_ADD_LIQUIDITY == 0) return false;
        if (p & PERM_AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA != 0 && p & PERM_AFTER_REMOVE_LIQUIDITY == 0) {
            return false;
        }
        return true;
    }

    /// @notice Capability class of a bitmap. Derived, not curated — no role can change this.
    function classify(uint16 permissions) internal pure returns (RiskClass) {
        // Can take value out of a swap or a liquidity movement, or can refuse a withdrawal
        // forever. Both end with a user unable to get their money back out.
        if (permissions & PERM_RETURNS_DELTA_MASK != 0 || permissions & PERM_BEFORE_REMOVE_LIQUIDITY != 0) {
            return RiskClass.ValueExtracting;
        }
        // Holds a veto over some action.
        if (permissions & PERM_BEFORE_MASK != 0) return RiskClass.Restrictive;
        return RiskClass.Passive;
    }
}
