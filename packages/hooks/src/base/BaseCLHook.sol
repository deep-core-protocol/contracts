/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "infinity-core/src/types/BeforeSwapDelta.sol";

/// @title BaseCLHook
/// @notice Base contract for concentrated-liquidity hooks on DeepCoreProtocol.
///
/// @dev ######################### SECURITY MODEL — READ BEFORE SUBCLASSING #########################
///
/// 1. ACCESS CONTROL. Every callback is `onlyPoolManager`. Hook callbacks are trusted by the pool
///    manager to report deltas and fee overrides; a callback reachable by an arbitrary caller lets
///    an attacker drive the hook's internal accounting out of sync with the pool (fake a swap to
///    trip a launch cap, replay a fee decay, corrupt volume counters). Never relax this, and never
///    add an external state-mutating function that assumes it is only reachable via a callback.
///
/// 2. BITMAP MUST MATCH IMPLEMENTATION. `Hooks.validateHookConfig` compares the pool key's
///    registration bitmap against this contract's `getHooksRegistrationBitmap()` at pool
///    initialization and reverts on mismatch. Declaring a permission you have not implemented is
///    therefore not a silent no-op — the default implementations below revert with
///    `HookNotImplemented` so the mistake surfaces immediately rather than mid-swap.
///
///    Note this is the protocol's core developer advantage: permissions live in the pool key and
///    are cross-checked against the hook, so a hook works from ANY address. There is no CREATE2
///    salt mining, unlike Uniswap v4 which encodes permissions in the hook's address bits.
///
/// 3. RETURN SELECTORS. Core checks the returned selector and reverts with `InvalidHookResponse`
///    otherwise. Always return `IHooks.<fn>.selector` — the helpers below do this for you.
///
/// 4. DELTA PERMISSIONS HAVE DEPENDENCIES. `*ReturnsDelta` flags require their base callback, and
///    core rejects conflicting combinations with `HookPermissionsValidationError`. The constructor
///    validates this locally so a misconfigured hook fails at deploy time rather than at the first
///    pool creation, which is a much worse place to discover it.
///
/// 5. HOOKS MUST NOT REVERT CARELESSLY. A reverting `beforeSwap` makes the pool untradeable for as
///    long as the condition holds. That is legitimate for a launch gate, and a denial-of-service
///    bug everywhere else. Be deliberate about which conditions revert.
/// ###########################################################################################
abstract contract BaseCLHook is ICLHooks {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    /// @notice Callback invoked by an address other than the pool manager
    error NotPoolManager();

    /// @notice A permission was declared in the bitmap but the callback is not implemented
    error HookNotImplemented();

    /// @notice A returns-delta permission was declared without its required base callback
    /// @param declared The bitmap that failed validation
    error PermissionDependencyMissing(uint16 declared);

    /// @notice Bits 14 and 15 carry no meaning and must be zero
    error ReservedBitsSet(uint16 declared);

    /// @notice The pool manager permitted to invoke this hook's callbacks
    ICLPoolManager public immutable poolManager;

    /*//////////////////////////////////////////////////////////////
                    PERMISSION OFFSETS (from ICLHooks)
    //////////////////////////////////////////////////////////////*/

    uint16 internal constant BEFORE_INITIALIZE = 1 << 0;
    uint16 internal constant AFTER_INITIALIZE = 1 << 1;
    uint16 internal constant BEFORE_ADD_LIQUIDITY = 1 << 2;
    uint16 internal constant AFTER_ADD_LIQUIDITY = 1 << 3;
    uint16 internal constant BEFORE_REMOVE_LIQUIDITY = 1 << 4;
    uint16 internal constant AFTER_REMOVE_LIQUIDITY = 1 << 5;
    uint16 internal constant BEFORE_SWAP = 1 << 6;
    uint16 internal constant AFTER_SWAP = 1 << 7;
    uint16 internal constant BEFORE_DONATE = 1 << 8;
    uint16 internal constant AFTER_DONATE = 1 << 9;
    uint16 internal constant BEFORE_SWAP_RETURNS_DELTA = 1 << 10;
    uint16 internal constant AFTER_SWAP_RETURNS_DELTA = 1 << 11;
    uint16 internal constant AFTER_ADD_LIQUIDITY_RETURNS_DELTA = 1 << 12;
    uint16 internal constant AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA = 1 << 13;

    /// @dev Bits 14-15 are unassigned and must remain zero
    uint16 internal constant RESERVED_BITS = uint16(0xC000);

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(ICLPoolManager _poolManager) {
        poolManager = _poolManager;
        _validatePermissions(getHooksRegistrationBitmap());
    }

    /// @inheritdoc IHooks
    /// @dev Subclasses declare exactly the callbacks they implement, e.g.
    /// `return BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA;`
    function getHooksRegistrationBitmap() public pure virtual override returns (uint16);

    /// @dev Mirrors the conflict rules core enforces in CLHooks/Hooks, checked at deploy time.
    function _validatePermissions(uint16 declared) internal pure {
        if (declared & RESERVED_BITS != 0) revert ReservedBitsSet(declared);

        bool ok = true;
        // a returns-delta permission is meaningless without the callback that returns it
        if (declared & BEFORE_SWAP_RETURNS_DELTA != 0 && declared & BEFORE_SWAP == 0) ok = false;
        if (declared & AFTER_SWAP_RETURNS_DELTA != 0 && declared & AFTER_SWAP == 0) ok = false;
        if (declared & AFTER_ADD_LIQUIDITY_RETURNS_DELTA != 0 && declared & AFTER_ADD_LIQUIDITY == 0) ok = false;
        if (declared & AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA != 0 && declared & AFTER_REMOVE_LIQUIDITY == 0) ok = false;

        if (!ok) revert PermissionDependencyMissing(declared);
    }

    /*//////////////////////////////////////////////////////////////
                              INITIALIZE
    //////////////////////////////////////////////////////////////*/

    function beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        return _beforeInitialize(sender, key, sqrtPriceX96);
    }

    function afterInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96, int24 tick)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        return _afterInitialize(sender, key, sqrtPriceX96, tick);
    }

    /*//////////////////////////////////////////////////////////////
                              LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    function beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        return _beforeAddLiquidity(sender, key, params, hookData);
    }

    function afterAddLiquidity(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        return _afterAddLiquidity(sender, key, params, delta, feesAccrued, hookData);
    }

    function beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        return _beforeRemoveLiquidity(sender, key, params, hookData);
    }

    function afterRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        BalanceDelta delta,
        BalanceDelta feesAccrued,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        return _afterRemoveLiquidity(sender, key, params, delta, feesAccrued, hookData);
    }

    /*//////////////////////////////////////////////////////////////
                                 SWAP
    //////////////////////////////////////////////////////////////*/

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        return _beforeSwap(sender, key, params, hookData);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        return _afterSwap(sender, key, params, delta, hookData);
    }

    /*//////////////////////////////////////////////////////////////
                                DONATE
    //////////////////////////////////////////////////////////////*/

    function beforeDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        return _beforeDonate(sender, key, amount0, amount1, hookData);
    }

    function afterDonate(
        address sender,
        PoolKey calldata key,
        uint256 amount0,
        uint256 amount1,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        return _afterDonate(sender, key, amount0, amount1, hookData);
    }

    /*//////////////////////////////////////////////////////////////
        OVERRIDE POINTS — default to reverting, so a declared-but-
        unimplemented permission fails loudly instead of silently.
    //////////////////////////////////////////////////////////////*/

    function _beforeInitialize(address, PoolKey calldata, uint160) internal virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function _afterInitialize(address, PoolKey calldata, uint160, int24) internal virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function _afterAddLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal virtual returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function _afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ICLPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) internal virtual returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function _beforeSwap(address, PoolKey calldata, ICLPoolManager.SwapParams calldata, bytes calldata)
        internal
        virtual
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    function _afterSwap(
        address,
        PoolKey calldata,
        ICLPoolManager.SwapParams calldata,
        BalanceDelta,
        bytes calldata
    ) internal virtual returns (bytes4, int128) {
        revert HookNotImplemented();
    }

    function _beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function _afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        internal
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev Convenience for subclasses that take no delta and no fee override.
    function _passthroughSwap() internal pure returns (bytes4, BeforeSwapDelta, uint24) {
        return (ICLHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Convenience for subclasses returning no liquidity delta.
    function _passthroughLiquidity(bytes4 selector) internal pure returns (bytes4, BalanceDelta) {
        return (selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
}
