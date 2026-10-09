// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";

/// @dev THE ATTACK `PermissionedPoolHook` EXISTS TO STOP.
///
/// Nothing about locking the Vault is privileged: `IVault.lock` is callable by anybody, and
/// whoever calls it becomes the `sender` every hook callback sees for the duration. So an
/// unpermitted party does not need a router's cooperation to reach the pool - they can lock the
/// Vault themselves and call `poolManager.swap` directly with `hookData` of their own choosing.
///
/// This contract does exactly that, and names a PERMITTED investor in its `hookData`. Against the
/// naive design - "decode an account out of `hookData` and check it against an allowlist" - this
/// trades successfully, because the forged attestation is indistinguishable from a real one.
/// Against the trusted-router design it cannot get past `beforeSwap`, because `sender` is this
/// contract and this contract is not in `isTrustedRouter`.
///
/// The settlement half is deliberately absent: the swap is expected to revert inside the hook
/// callback, long before any delta needs settling. If the hook's gate ever regressed, the test
/// asserting on the revert would fail loudly rather than silently passing on an unsettled lock.
contract DirectLockAttacker is ILockCallback {
    IVault public immutable vault;
    ICLPoolManager public immutable poolManager;

    constructor(IVault _vault, ICLPoolManager _poolManager) {
        vault = _vault;
        poolManager = _poolManager;
    }

    struct SwapCall {
        PoolKey key;
        ICLPoolManager.SwapParams params;
        bytes hookData;
    }

    struct LiquidityCall {
        PoolKey key;
        ICLPoolManager.ModifyLiquidityParams params;
        bytes hookData;
    }

    /// @notice Lock the Vault and swap, forging `forgedIdentity` as the account on whose behalf
    /// the trade is supposedly being made.
    function attackSwap(PoolKey memory key, ICLPoolManager.SwapParams memory params, address forgedIdentity)
        external
        returns (BalanceDelta delta)
    {
        bytes memory result =
            vault.lock(abi.encode("swap", abi.encode(SwapCall(key, params, abi.encode(forgedIdentity)))));
        return abi.decode(result, (BalanceDelta));
    }

    /// @notice Lock the Vault and add liquidity under a forged identity.
    function attackAddLiquidity(
        PoolKey memory key,
        ICLPoolManager.ModifyLiquidityParams memory params,
        address forgedIdentity
    ) external {
        vault.lock(abi.encode("modify", abi.encode(LiquidityCall(key, params, abi.encode(forgedIdentity)))));
    }

    /// @notice Lock the Vault and attempt a removal, with `hookData` supplied verbatim.
    /// @dev Used to show the EXIT path is deliberately open to an untrusted locker, and that this
    /// gives an attacker nothing: core keys a CL position by `(locker, tickLower, tickUpper,
    /// salt)`, so this contract owns no position and removes nothing.
    function attackRemoveLiquidity(
        PoolKey memory key,
        ICLPoolManager.ModifyLiquidityParams memory params,
        bytes memory hookData
    ) external {
        vault.lock(abi.encode("modify", abi.encode(LiquidityCall(key, params, hookData))));
    }

    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == address(vault), "only vault");
        (string memory action, bytes memory payload) = abi.decode(data, (string, bytes));

        if (keccak256(bytes(action)) == keccak256("swap")) {
            SwapCall memory call = abi.decode(payload, (SwapCall));
            BalanceDelta delta = poolManager.swap(call.key, call.params, call.hookData);
            return abi.encode(delta);
        }

        LiquidityCall memory liquidityCall = abi.decode(payload, (LiquidityCall));
        poolManager.modifyLiquidity(liquidityCall.key, liquidityCall.params, liquidityCall.hookData);
        return "";
    }
}
