// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseCLHook} from "deepcore-hooks/src/base/BaseCLHook.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "infinity-core/src/types/BeforeSwapDelta.sol";

contract FeeDeepCore is BaseCLHook {
    uint24 constant LOW = 500;
    uint24 constant HIGH = 3000;
    int256 constant LARGE = 10 ether;

    constructor(ICLPoolManager _poolManager) BaseCLHook(_poolManager) {}

    /// Bit 6 only. poolKey.parameters must carry exactly this value.
    function getHooksRegistrationBitmap() public pure override returns (uint16) {
        return BEFORE_SWAP;
    }

    function _beforeSwap(address, PoolKey calldata, ICLPoolManager.SwapParams calldata params, bytes calldata)
        internal pure override returns (bytes4, BeforeSwapDelta, uint24)
    {
        // amountSpecified is negative for exact input, positive for exact output.
        int256 amount = params.amountSpecified;
        uint24 fee = (amount >= LARGE || amount <= -LARGE) ? HIGH : LOW;

        // OVERRIDE_FEE_FLAG is what makes core apply the fee, and it is read
        // only on a dynamic-fee pool. Return the selector or core reverts.
        return (ICLHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, fee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }
}
