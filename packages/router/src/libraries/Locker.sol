// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 DeepCoreProtocol — portable transient backend
pragma solidity ^0.8.24;

import {TransientSlot} from "hp-transient/TransientSlot.sol";

/// @notice A library to implement a reentrancy lock in transient storage.
/// @dev Instead of storing a boolean, the locker's address is stored to allow the contract to know who locked the contract
///
/// @dev SELF-CLEARING INVARIANT (load-bearing under the storage backend):
/// `Lock.isNotLocked` writes the locker, runs the body, then writes address(0). The clear is
/// unconditional on the success path, and a revert rolls the frame's writes back, so nothing
/// survives the transaction under either backend. The self-reentrancy branch writes nothing at
/// all. Do not restructure that modifier without re-checking this holds.
library Locker {
    // The slot holding the locker state, transiently. bytes32(uint256(keccak256("Locker")) - 1)
    uint256 constant LOCKER_SLOT = 0x0e87e1788ebd9ed6a7e63c70a374cd3283e41cad601d21fbe27863899ed4a708;

    function set(address locker) internal {
        // The locker is always msg.sender or address(0) so does not need to be cleaned
        TransientSlot.setAddress(LOCKER_SLOT, locker);
    }

    function get() internal view returns (address locker) {
        locker = TransientSlot.getAddress(LOCKER_SLOT);
    }

    function isLocked() internal view returns (bool) {
        return Locker.get() != address(0);
    }
}
