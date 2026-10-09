// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {LaunchGuardHook, ILaunchTokenOrigin} from "deepcore-hooks/src/launch/LaunchGuardHook.sol";

/// @dev TEST ONLY. The guard Kit v1 (`LaunchpadKit`, not deployed by DeepCore) was built
/// against: the PRE-TAX bitmap (`beforeInitialize | beforeSwap`, 0x0041), which v1 asserts in its
/// constructor, and the fee as an LP FEE OVERRIDE, which is what v1's pools pay. Kit v1 keeps hosting its
/// pools on the retired block-numbered guard; nothing pairs it with the current guard on any chain. This
/// shim exists so v1's own tests and the (unused) v1 deploy script keep exercising v1 against a
/// timestamp-clocked guard without changing v1's Sourcify-verified source.
///
/// WHY IT OVERRIDES THE SWAP PATH (2026-09-28). The current guard takes its fee itself, in the quote
/// currency, as a hook delta, and refuses to initialize a pool without a fee split. Under v1's bitmap core
/// reads no hook delta, so that take would leave the hook with a vault claim nobody paid for and every swap
/// would fail to settle; and v1 writes no fee split. So this shim restores what the guard did when v1 was
/// written: no fee split required, the decayed fee handed to core as the LP fee, nothing taken. Never
/// deploy it.
contract LegacyBitmapLaunchGuardHook is LaunchGuardHook {
    constructor(ICLPoolManager pm, ILaunchTokenOrigin factory, address taxRecipient)
        LaunchGuardHook(pm, factory, taxRecipient, 0)
    {}

    function getHooksRegistrationBitmap() public pure override returns (uint16) {
        return BEFORE_INITIALIZE | BEFORE_SWAP;
    }

    function _beforeInitialize(address, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (!LPFeeLibrary.isDynamicLPFee(key.fee)) revert PoolMustUseDynamicFee(key.fee);
        PoolId poolId = key.toId();
        if (_launches[poolId].owner == address(0)) revert LaunchNotConfigured(poolId);
        return ICLHooks.beforeInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, ICLPoolManager.SwapParams calldata params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        Launch storage l = _launches[poolId];
        if (l.owner == address(0)) revert LaunchNotConfigured(poolId);

        if (l.enabled) {
            uint256 startTime = l.startTime;
            if (block.timestamp < startTime) revert TradingNotOpen(poolId, startTime, block.timestamp);
            uint128 maxBuyPerTx = l.maxBuyPerTx;
            if (maxBuyPerTx != 0 && block.timestamp - startTime < l.decaySeconds) {
                _enforceMaxBuy(params, l.launchTokenIsCurrency0, maxBuyPerTx);
            }
        }
        if (!l.launched) {
            l.launched = true;
            emit LaunchStarted(poolId, block.timestamp);
        }
        return (
            ICLHooks.beforeSwap.selector,
            BeforeSwapDeltaLibrary.ZERO_DELTA,
            _feeNow(l) | LPFeeLibrary.OVERRIDE_FEE_FLAG
        );
    }
}
