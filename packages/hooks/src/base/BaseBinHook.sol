/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {IBinHooks} from "infinity-core/src/pool-bin/interfaces/IBinHooks.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";

/// @title BaseBinHook
/// @notice Base contract for bin (liquidity-book) hooks on DeepCoreProtocol.
///
/// @dev ######################### SECURITY MODEL — READ BEFORE SUBCLASSING #########################
///
/// This mirrors `BaseCLHook` exactly. The five rules below are the same rules; the notes after them
/// record where the BIN surface differs from the CL surface, because several of the differences are
/// security-relevant and are easy to miss when porting a CL hook across.
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
///    otherwise. Always return `IBinHooks.<fn>.selector` — the helpers below do this for you.
///    Core ALSO checks the exact returndata LENGTH for the two callbacks that carry a fee:
///    `beforeMint` must return exactly 64 bytes and `beforeSwap` exactly 96. Returning the wrong
///    arity is an `InvalidHookResponse`, not a silent truncation.
///
/// 4. DELTA PERMISSIONS HAVE DEPENDENCIES. `*ReturnsDelta` flags require their base callback, and
///    core rejects conflicting combinations with `HookPermissionsValidationError`
///    (`BinHooks.validatePermissionsConflict`). The constructor validates this locally so a
///    misconfigured hook fails at deploy time rather than at the first pool creation, which is a
///    much worse place to discover it.
///
/// 5. HOOKS MUST NOT REVERT CARELESSLY. A reverting `beforeSwap` makes the pool untradeable for as
///    long as the condition holds. That is legitimate for a launch gate, and a denial-of-service
///    bug everywhere else. Be deliberate about which conditions revert. On bin this extends to
///    `beforeMint`/`beforeBurn`: a reverting `beforeBurn` traps LP capital.
///
/// ------------------------- BIN vs CL: THE DIFFERENCES THAT BITE -------------------------
///
/// A. THE BITMAP IS THE SAME SHAPE, WITH FOUR RENAMED BITS. Offsets 0..13 line up one-for-one with
///    CL; bits 2/3 are MINT rather than ADD_LIQUIDITY, bits 4/5 are BURN rather than
///    REMOVE_LIQUIDITY, and bits 12/13 are the matching returns-delta flags. Bits 14-15 are unused
///    on both. Verified against `IBinHooks.sol`.
///
/// B. `parameters` IS SHARED WITH `binStep`. `BinPoolParametersHelper` packs the 16-bit binStep at
///    offset 16, immediately above the hook bitmap at offsets 0..15, and core rejects any non-zero
///    bit at or above offset 32. A pool key for a bin hook is therefore
///    `bytes32(uint256(bitmap)).setBinStep(step)` — forgetting the binStep is not a defaulting
///    error, it is a `BinStepTooSmall` revert at initialization.
///
/// C. THERE IS NO `SwapParams` STRUCT. `beforeSwap`/`afterSwap` take `(bool swapForY,
///    int128 amountSpecified)` flat, and `amountSpecified` is int128, NOT int256. `swapForY == true`
///    is "sell X (currency0) for Y (currency1)", i.e. the analogue of CL's `zeroForOne`. Negative
///    `amountSpecified` is exact input, as on CL.
///
/// D. THE FEE CEILING IS 10%, NOT 100%. Core validates a bin LP fee against
///    `LPFeeLibrary.TEN_PERCENT_FEE` (100_000) in `BinPool.swap` and `BinPool.mint`, and in
///    `BinPoolManager.initialize`/`updateDynamicLPFee`. `MAX_LP_FEE` below is that ceiling; a fee
///    that would be perfectly legal on a CL pool reverts with `LPFeeTooLarge` here.
///
/// E. `beforeMint` CAN RETURN A FEE, AND THAT IS A SECURITY PROPERTY, NOT A CONVENIENCE. Adding
///    liquidity to the ACTIVE bin at a ratio different from the bin's own performs an implicit swap
///    inside core (`BinHelper.getCompositionFeesAmount`), charged at the composition fee. A hook
///    that taxes `beforeSwap` but leaves `beforeMint` unregistered on a DYNAMIC-fee pool leaves
///    that implicit swap charged at the pool's stored LP fee — which is 0 for a dynamic-fee pool
///    that never called `updateDynamicLPFee`. Mint-then-burn is then a fee-free swap straight
///    through the tax. If your hook prices swaps, it must price mints too.
///
/// F. `afterMint`/`afterBurn` DO NOT RECEIVE `feesAccrued`. The CL equivalents pass a second
///    `BalanceDelta`; the bin ones pass only the caller delta. There is no fee-accrual figure to
///    read at this layer.
///
/// G. `afterInitialize` DOES NOT RECEIVE A PRICE-DERIVED SECOND ARGUMENT. CL passes
///    `(sqrtPriceX96, tick)`; bin passes only `activeId`, on both initialize callbacks. `activeId`
///    is a uint24 and 2**23 is the 1:1 price.
///
/// H. THE FEE OVERRIDE IS STILL DYNAMIC-FEE-ONLY. `BinHooks.beforeSwap` and `BinHooks.beforeMint`
///    both read the returned fee ONLY when `key.fee.isDynamicLPFee()`, which is
///    `fee == 0x800000` EXACTLY. On a static-fee pool the fee a hook returns is discarded with no
///    revert and no event — identical to CL, and identically dangerous.
/// ###########################################################################################
abstract contract BaseBinHook is IBinHooks {
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
    IBinPoolManager public immutable poolManager;

    /*//////////////////////////////////////////////////////////////
                    PERMISSION OFFSETS (from IBinHooks)

        Bit-for-bit the same layout as CL. Only the NAMES of bits
        2-5, 12 and 13 differ, because bin has mint/burn where CL
        has add/remove-liquidity.
    //////////////////////////////////////////////////////////////*/

    uint16 internal constant BEFORE_INITIALIZE = 1 << 0;
    uint16 internal constant AFTER_INITIALIZE = 1 << 1;
    uint16 internal constant BEFORE_MINT = 1 << 2;
    uint16 internal constant AFTER_MINT = 1 << 3;
    uint16 internal constant BEFORE_BURN = 1 << 4;
    uint16 internal constant AFTER_BURN = 1 << 5;
    uint16 internal constant BEFORE_SWAP = 1 << 6;
    uint16 internal constant AFTER_SWAP = 1 << 7;
    uint16 internal constant BEFORE_DONATE = 1 << 8;
    uint16 internal constant AFTER_DONATE = 1 << 9;
    uint16 internal constant BEFORE_SWAP_RETURNS_DELTA = 1 << 10;
    uint16 internal constant AFTER_SWAP_RETURNS_DELTA = 1 << 11;
    uint16 internal constant AFTER_MINT_RETURNS_DELTA = 1 << 12;
    uint16 internal constant AFTER_BURN_RETURNS_DELTA = 1 << 13;

    /// @dev Bits 14-15 are unassigned and must remain zero. On bin, offset 16 upwards is `binStep`,
    /// so a stray bit here is not merely meaningless — it would corrupt the pool's bin step.
    uint16 internal constant RESERVED_BITS = uint16(0xC000);

    /// @notice The largest LP fee a bin pool will accept: 10%, one tenth of the CL ceiling.
    /// @dev Core enforces this in `BinPool.swap`/`BinPool.mint` via
    /// `removeOverrideAndValidate(LPFeeLibrary.TEN_PERCENT_FEE)`. Subclasses that compute a fee
    /// must clamp to this, not to `ONE_HUNDRED_PERCENT_FEE`.
    uint24 internal constant MAX_LP_FEE = LPFeeLibrary.TEN_PERCENT_FEE;

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    constructor(IBinPoolManager _poolManager) {
        poolManager = _poolManager;
        _validatePermissions(getHooksRegistrationBitmap());
    }

    /// @inheritdoc IHooks
    /// @dev Subclasses declare exactly the callbacks they implement, e.g.
    /// `return BEFORE_SWAP | BEFORE_SWAP_RETURNS_DELTA;`
    function getHooksRegistrationBitmap() public pure virtual override returns (uint16);

    /// @dev Mirrors the conflict rules core enforces in `BinHooks.validatePermissionsConflict`,
    /// checked at deploy time.
    function _validatePermissions(uint16 declared) internal pure {
        if (declared & RESERVED_BITS != 0) revert ReservedBitsSet(declared);

        bool ok = true;
        // a returns-delta permission is meaningless without the callback that returns it
        if (declared & BEFORE_SWAP_RETURNS_DELTA != 0 && declared & BEFORE_SWAP == 0) ok = false;
        if (declared & AFTER_SWAP_RETURNS_DELTA != 0 && declared & AFTER_SWAP == 0) ok = false;
        if (declared & AFTER_MINT_RETURNS_DELTA != 0 && declared & AFTER_MINT == 0) ok = false;
        if (declared & AFTER_BURN_RETURNS_DELTA != 0 && declared & AFTER_BURN == 0) ok = false;

        if (!ok) revert PermissionDependencyMissing(declared);
    }

    /*//////////////////////////////////////////////////////////////
                              INITIALIZE
    //////////////////////////////////////////////////////////////*/

    function beforeInitialize(address sender, PoolKey calldata key, uint24 activeId)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        return _beforeInitialize(sender, key, activeId);
    }

    function afterInitialize(address sender, PoolKey calldata key, uint24 activeId)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        return _afterInitialize(sender, key, activeId);
    }

    /*//////////////////////////////////////////////////////////////
                             MINT / BURN

        The bin analogue of CL's add/remove-liquidity pair. Note the
        asymmetry that CL does not have: `beforeMint` returns a fee
        override as well as a selector, because a mint into the
        active bin can perform an implicit swap.
    //////////////////////////////////////////////////////////////*/

    function beforeMint(
        address sender,
        PoolKey calldata key,
        IBinPoolManager.MintParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, uint24) {
        return _beforeMint(sender, key, params, hookData);
    }

    function afterMint(
        address sender,
        PoolKey calldata key,
        IBinPoolManager.MintParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        return _afterMint(sender, key, params, delta, hookData);
    }

    function beforeBurn(
        address sender,
        PoolKey calldata key,
        IBinPoolManager.BurnParams calldata params,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4) {
        return _beforeBurn(sender, key, params, hookData);
    }

    function afterBurn(
        address sender,
        PoolKey calldata key,
        IBinPoolManager.BurnParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        return _afterBurn(sender, key, params, delta, hookData);
    }

    /*//////////////////////////////////////////////////////////////
                                 SWAP
    //////////////////////////////////////////////////////////////*/

    function beforeSwap(
        address sender,
        PoolKey calldata key,
        bool swapForY,
        int128 amountSpecified,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BeforeSwapDelta, uint24) {
        return _beforeSwap(sender, key, swapForY, amountSpecified, hookData);
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        bool swapForY,
        int128 amountSpecified,
        BalanceDelta delta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, int128) {
        return _afterSwap(sender, key, swapForY, amountSpecified, delta, hookData);
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

    function _beforeInitialize(address, PoolKey calldata, uint24) internal virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function _afterInitialize(address, PoolKey calldata, uint24) internal virtual returns (bytes4) {
        revert HookNotImplemented();
    }

    function _beforeMint(address, PoolKey calldata, IBinPoolManager.MintParams calldata, bytes calldata)
        internal
        virtual
        returns (bytes4, uint24)
    {
        revert HookNotImplemented();
    }

    function _afterMint(address, PoolKey calldata, IBinPoolManager.MintParams calldata, BalanceDelta, bytes calldata)
        internal
        virtual
        returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    function _beforeBurn(address, PoolKey calldata, IBinPoolManager.BurnParams calldata, bytes calldata)
        internal
        virtual
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function _afterBurn(address, PoolKey calldata, IBinPoolManager.BurnParams calldata, BalanceDelta, bytes calldata)
        internal
        virtual
        returns (bytes4, BalanceDelta)
    {
        revert HookNotImplemented();
    }

    function _beforeSwap(address, PoolKey calldata, bool, int128, bytes calldata)
        internal
        virtual
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        revert HookNotImplemented();
    }

    function _afterSwap(address, PoolKey calldata, bool, int128, BalanceDelta, bytes calldata)
        internal
        virtual
        returns (bytes4, int128)
    {
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
        return (IBinHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @dev Convenience for a `beforeMint` that imposes no composition-fee override.
    /// @dev Returning 0 leaves the pool's STORED lp fee in force, which is 0 on a dynamic-fee pool
    /// that never called `updateDynamicLPFee`. See note (E) at the top of this file.
    function _passthroughMint() internal pure returns (bytes4, uint24) {
        return (IBinHooks.beforeMint.selector, 0);
    }

    /// @dev Convenience for subclasses returning no mint/burn delta.
    function _passthroughLiquidity(bytes4 selector) internal pure returns (bytes4, BalanceDelta) {
        return (selector, BalanceDeltaLibrary.ZERO_DELTA);
    }
}
