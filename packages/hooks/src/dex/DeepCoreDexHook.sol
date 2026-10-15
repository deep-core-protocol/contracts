// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {DeepCoreDynamicFeeHook} from "./DeepCoreDynamicFeeHook.sol";
import {OracleModule} from "../oracle/OracleModule.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {BeforeSwapDelta} from "infinity-core/src/types/BeforeSwapDelta.sol";

/// @title DeepCoreDexHook
/// @notice The dynamic-fee DeepCore compiled with the price oracle: product 5 of
/// `docs/products/dynamic-fee-deepcore.md`, which specifies `DeepCoreDexHook = OracleModule +
/// DynamicFeeModule`.
///
/// ############################## WHAT IT ADDS, HONESTLY ##############################
///
/// The dynamic fee itself already exists and is ACCEPTED: `DeepCoreDynamicFeeHook` (2026-09-29,
/// with the owner-approved protocol share). This contract does not re-implement it. It INHERITS
/// it unchanged (the accepted hook gained only the `virtual` keyword on two callbacks, which
/// changes none of its bytecode, proven by comparing `deployedBytecode.object` under both
/// profiles) and adds `OracleModule`, so a dynamic-fee pool also offers a manipulation-resistant
/// time-weighted average tick to other protocols.
///
/// The fee is NOT driven by the oracle. The design's volatility term reads the pool's own tick at
/// the first swap of each second; feeding it the lagging, truncated average would make the fee
/// react slower to exactly the moves it exists to price. The two share a callback and a pool,
/// not a formula.
///
/// Everything in `DeepCoreDynamicFeeHook`'s header applies here unchanged: the fee, the protocol
/// share and its money path, the funds (one exit, `flushProtocolFees`, to the immutable
/// recipient), the roles (Safe: share for new pools only; pool owner; tuner). The oracle adds no
/// role, no value and no exit: its only state-changing entry point is the permissionless
/// `increaseCardinalityNext`, which spends the caller's gas.
///
/// Callbacks: `afterInitialize` also writes the first observation; `beforeSwap` first records the
/// pre-swap tick for the second (if it is the first swap of that second), then runs the dynamic
/// fee exactly as before. The oracle write never reverts, so it cannot make a pool untradeable.
///
/// Bitmap: the dynamic-fee hook's own, 0x08C3 (bits 0, 1, 6, 7, 11). The oracle needs bits 1 and 6,
/// which are already set. No liquidity callback.
contract DeepCoreDexHook is DeepCoreDynamicFeeHook, OracleModule {
    constructor(
        ICLPoolManager poolManager_,
        IVault vault_,
        address owner_,
        address protocolRecipient_,
        uint24 feeCap_,
        uint16 initialShareBps_,
        uint16 maxShareBps_,
        uint32 shareNoticeSeconds_,
        uint32 tunerNoticeSeconds_,
        uint24 maxMovePerUpdate_,
        uint24 oracleMaxTickDelta_,
        uint32 oracleMinWindowSeconds_,
        uint16 oracleInitialCardinality_
    )
        DeepCoreDynamicFeeHook(
            poolManager_,
            vault_,
            owner_,
            protocolRecipient_,
            feeCap_,
            initialShareBps_,
            maxShareBps_,
            shareNoticeSeconds_,
            tunerNoticeSeconds_,
            maxMovePerUpdate_
        )
        OracleModule(oracleMaxTickDelta_, oracleMinWindowSeconds_, oracleInitialCardinality_)
    {}

    function _afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        internal
        override
        returns (bytes4)
    {
        _oracleInitialize(key.toId(), tick);
        return super._afterInitialize(sender, key, sqrtPriceX96, tick);
    }

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);
        _oracleWrite(id, tick);
        return super._beforeSwap(sender, key, params, hookData);
    }

    function _oracleCurrentTick(PoolId id) internal view override returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(id);
    }
}
