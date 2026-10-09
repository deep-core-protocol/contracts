// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {CurrencySettlement} from "infinity-core/test/helpers/CurrencySettlement.sol";

/// @dev What a router in `PermissionedPoolHook.isTrustedRouter` MUST look like, reduced to the one
/// property that matters:
///
///     THE CALLER DOES NOT CHOOSE THE ATTESTATION.
///
/// `hookData` is built here, from `msg.sender`, and there is no parameter through which a caller
/// can influence it. That is the entire job of a trusted router. The `CLPoolManagerRouter` that
/// core ships for testing forwards whatever `hookData` its caller hands it, which makes it a
/// perfectly good test instrument and an entirely unsafe thing to trust: the tests use it
/// precisely to demonstrate that a trusted router which forwards caller-supplied bytes voids the
/// gate.
///
/// A production router has more to do than this - it authenticates the account it settles for,
/// which here is simply `msg.sender` - but nothing it adds may reintroduce a path by which the
/// caller picks the bytes the hook reads.
///
/// This is a TEST FIXTURE. It has no slippage protection, no deadline, no multicall, no permit and
/// no fee handling, and it is not a router anybody should deploy.
contract AttestingRouter is ILockCallback {
    using CurrencySettlement for Currency;

    error OnlyVault();

    IVault public immutable vault;
    ICLPoolManager public immutable poolManager;

    constructor(IVault _vault, ICLPoolManager _poolManager) {
        vault = _vault;
        poolManager = _poolManager;
    }

    struct SwapCall {
        address account;
        PoolKey key;
        ICLPoolManager.SwapParams params;
    }

    struct LiquidityCall {
        address account;
        PoolKey key;
        ICLPoolManager.ModifyLiquidityParams params;
    }

    /// @notice Swap on behalf of `msg.sender`, attesting `msg.sender` and nobody else.
    function swap(PoolKey memory key, ICLPoolManager.SwapParams memory params) external returns (BalanceDelta delta) {
        bytes memory result = vault.lock(abi.encode("swap", abi.encode(SwapCall(msg.sender, key, params))));
        return abi.decode(result, (BalanceDelta));
    }

    /// @notice Add or remove liquidity on behalf of `msg.sender`, attesting `msg.sender`.
    function modifyPosition(PoolKey memory key, ICLPoolManager.ModifyLiquidityParams memory params)
        external
        returns (BalanceDelta delta)
    {
        bytes memory result = vault.lock(abi.encode("modify", abi.encode(LiquidityCall(msg.sender, key, params))));
        return abi.decode(result, (BalanceDelta));
    }

    function lockAcquired(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(vault)) revert OnlyVault();
        (string memory action, bytes memory payload) = abi.decode(data, (string, bytes));

        if (keccak256(bytes(action)) == keccak256("swap")) {
            SwapCall memory call = abi.decode(payload, (SwapCall));
            // The attestation. Built here; never taken from the caller.
            BalanceDelta delta = poolManager.swap(call.key, call.params, abi.encode(call.account));
            _settle(call.key, call.account, delta);
            return abi.encode(delta);
        }

        LiquidityCall memory liquidityCall = abi.decode(payload, (LiquidityCall));
        (BalanceDelta delta,) =
            poolManager.modifyLiquidity(liquidityCall.key, liquidityCall.params, abi.encode(liquidityCall.account));
        _settle(liquidityCall.key, liquidityCall.account, delta);
        return abi.encode(delta);
    }

    function _settle(PoolKey memory key, address account, BalanceDelta delta) private {
        if (delta.amount0() < 0) key.currency0.settle(vault, account, uint128(-delta.amount0()), false);
        if (delta.amount1() < 0) key.currency1.settle(vault, account, uint128(-delta.amount1()), false);
        if (delta.amount0() > 0) key.currency0.take(vault, account, uint128(delta.amount0()), false);
        if (delta.amount1() > 0) key.currency1.take(vault, account, uint128(delta.amount1()), false);
    }
}
