// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 HookProtocol
// Derived from PancakeSwap Infinity (GPL-2.0-or-later)
pragma solidity ^0.8.24;

/// @title TransientSlot — EIP-1153 backend
/// @notice Raw slot accessors backed by TSTORE/TLOAD. Values written here are
///         discarded automatically at the end of the transaction.
/// @dev This is the DEFAULT backend, used on chains with Cancun (EIP-1153) support.
///      The storage backend in `../storage/TransientSlot.sol` MUST expose an identical
///      API so that consuming libraries compile unchanged against either one.
///
///      INVARIANT SHARED WITH THE STORAGE BACKEND:
///      every slot written during a lock must be zero by the time the lock exits.
///      Under this backend that is free (the EVM clears it); under the storage backend
///      it is load-bearing for correctness. Do not rely on auto-clearing in consuming code.
library TransientSlot {
    /// @notice True when this build clears transient state automatically at end of transaction.
    /// @dev Consumed by deploy scripts and tests to assert the correct build for the target chain.
    bool internal constant IS_EIP1153 = true;

    function setUint(uint256 slot, uint256 value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function getUint(uint256 slot) internal view returns (uint256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function setInt(uint256 slot, int256 value) internal {
        assembly ("memory-safe") {
            tstore(slot, value)
        }
    }

    function getInt(uint256 slot) internal view returns (int256 value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }

    function setAddress(uint256 slot, address value) internal {
        assembly ("memory-safe") {
            tstore(slot, and(value, 0xffffffffffffffffffffffffffffffffffffffff))
        }
    }

    function getAddress(uint256 slot) internal view returns (address value) {
        assembly ("memory-safe") {
            value := tload(slot)
        }
    }
}
