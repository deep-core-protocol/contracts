// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 HookProtocol
// Derived from PancakeSwap Infinity (GPL-2.0-or-later)
pragma solidity ^0.8.24;

/// @title TransientSlot — persistent-storage backend for pre-Cancun chains
/// @notice Raw slot accessors backed by SSTORE/SLOAD, for EVMs without EIP-1153.
///         API-identical to `../eip1153/TransientSlot.sol`; selected via the
///         `hp-transient/` remapping under the `legacy` foundry profile.
///
/// @dev ############################ READ THIS BEFORE EDITING ############################
///
///      Unlike TSTORE, values written here PERSIST ACROSS TRANSACTIONS. Every consuming
///      library is therefore responsible for zeroing every slot it touches before the
///      enclosing lock exits. State that survives a lock is not a leak, it is a DRAIN:
///
///        Vault._settle computes `paid = balanceOfSelf() - reservesBefore`. If a stale
///        non-zero `reservesBefore` survives into a later transaction, an attacker can
///        call settle() having transferred nothing and be credited the difference,
///        then take() it. See test/transient/StorageBackendLeak.t.sol.
///
///      Two mitigations enforce the invariant, and BOTH are required:
///        1. Vault.sync() is gated by `isLocked` (in both builds, so semantics never
///           diverge by chain), so no reserve can be written outside a lock.
///        2. Vault.lock() clears the reserve slots on exit via VaultReserve.clear().
///
///      Slot-collision safety: callers derive slots from keccak256 of domain-separated
///      strings (e.g. keccak256("SETTLEMENT_LOCKER") - 1), which cannot collide with
///      Solidity's sequentially-allocated state slots or its mapping slots, by the same
///      argument used for EIP-1967. Never pass a small integer slot to this library.
///      ###############################################################################
library TransientSlot {
    /// @notice False: this build does NOT auto-clear. Consuming code must zero its slots.
    /// @dev Deploy scripts assert this matches the target chain's EIP-1153 support.
    bool internal constant IS_EIP1153 = false;

    function setUint(uint256 slot, uint256 value) internal {
        assembly ("memory-safe") {
            sstore(slot, value)
        }
    }

    function getUint(uint256 slot) internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := sload(slot)
        }
    }

    function setInt(uint256 slot, int256 value) internal {
        assembly ("memory-safe") {
            sstore(slot, value)
        }
    }

    function getInt(uint256 slot) internal view returns (int256 value) {
        assembly ("memory-safe") {
            value := sload(slot)
        }
    }

    function setAddress(uint256 slot, address value) internal {
        assembly ("memory-safe") {
            sstore(slot, and(value, 0xffffffffffffffffffffffffffffffffffffffff))
        }
    }

    function getAddress(uint256 slot) internal view returns (address value) {
        assembly ("memory-safe") {
            value := sload(slot)
        }
    }
}
