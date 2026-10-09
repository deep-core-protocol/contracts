// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
// Copyright (C) 2026 DeepCoreProtocol — portable transient backend
pragma solidity ^0.8.24;

import {TransientSlot} from "hp-transient/TransientSlot.sol";

/// @notice A reentrancy lock that stores the caller's address as the lock
///
/// @dev SELF-CLEARING INVARIANT (load-bearing under the storage backend):
/// the modifier writes the locker, runs the body, then writes address(0). On the success path
/// the clear is explicit. On the revert path the EVM rolls back the frame's storage writes, so
/// the slot is restored to zero either way. No slot survives a transaction, so unlike
/// MixedQuoterRecorder this needs no explicit sweep.
///
/// Do NOT convert this to an early-return / non-modifier form without re-checking that the
/// clearing write is still unconditional on the success path.
contract ReentrancyLock {
    // The slot holding the locker state, transiently. bytes32(uint256(keccak256("LockedBy")) - 1)
    uint256 constant LOCKED_BY_SLOT = 0x0aedd6bde10e3aa2adec092b02a3e3e805795516cda41f27aa145b8f300af87a;

    error ContractLocked();

    modifier isNotLocked() {
        if (_getLocker() != address(0)) revert ContractLocked();
        _setLocker(msg.sender);
        _;
        _setLocker(address(0));
    }

    function _setLocker(address locker) internal {
        TransientSlot.setAddress(LOCKED_BY_SLOT, locker);
    }

    function _getLocker() internal view returns (address locker) {
        locker = TransientSlot.getAddress(LOCKED_BY_SLOT);
    }
}
