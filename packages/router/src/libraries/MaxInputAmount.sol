// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 DeepCoreProtocol — portable transient backend
pragma solidity ^0.8.24;

import {TransientSlot} from "hp-transient/TransientSlot.sol";

/// @notice A library used to store the maximum desired amount of input tokens for exact output swaps; used for checking slippage
///
/// @dev SELF-CLEARING INVARIANT (load-bearing under the storage backend):
/// `V3SwapRouter.v3SwapExactOutput` sets the cap, performs the swap, then sets it back to 0.
/// The reset is unconditional on the success path and a revert rolls it back, so no stale cap
/// can survive into a later transaction and loosen a subsequent slippage check.
library MaxInputAmount {
    // The slot holding the the maximum desired amount of input tokens, transiently. bytes32(uint256(keccak256("MaxAmountIn")) - 1)
    uint256 constant MAX_AMOUNT_IN_SLOT = 0xaf28d9864a81dfdf71cab65f4e5d79a0cf9b083905fb8971425e6cb581b3f692;

    function set(uint256 maxAmountIn) internal {
        TransientSlot.setUint(MAX_AMOUNT_IN_SLOT, maxAmountIn);
    }

    function get() internal view returns (uint256 maxAmountIn) {
        maxAmountIn = TransientSlot.getUint(MAX_AMOUNT_IN_SLOT);
    }
}
