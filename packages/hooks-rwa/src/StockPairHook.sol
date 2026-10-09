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
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "infinity-core/src/types/BeforeSwapDelta.sol";

import {PermissionedPoolHook} from "./PermissionedPoolHook.sol";
import {MarketHoursModule} from "./modules/MarketHoursModule.sol";

/// @title StockPairHook
/// @notice The whole tokenized-equity pair in one hook: `PermissionedPoolHook`'s compliance gate
/// plus `MarketHoursModule`'s trading calendar, halt switch and price band.
///
/// @dev ################### NO LEGAL ADVICE IS GIVEN OR IMPLIED ###################
///
/// This contract is a MECHANISM, and composing two mechanisms does not produce a compliant venue.
/// Read the contract-level notes on BOTH `PermissionedPoolHook` and `MarketHoursModule` before
/// configuring anything: between them they state, at length and deliberately, what is enforced and
/// what is not. Whether any configuration of this hook satisfies any securities law, market-
/// structure rule, exchange-registration requirement or transfer-agent obligation in any
/// jurisdiction is a question for the issuer's counsel. It is not answered here.
///
/// ------------------------------ WHY THIS EXISTS AS ONE CONTRACT ------------------------------
///
/// A pool has exactly ONE hook. An issuer who needs both an identity gate and market hours cannot
/// deploy two hooks and point a pool at both; they must be composed into a single contract, and
/// this is that contract. There is no clever indirection here on purpose: composition through a
/// delegating hook that forwards callbacks to a list of sub-hooks would put an unbounded, owner-
/// mutable call sequence on the swap hot path, and every one of those calls could revert the
/// trade. Inheritance is legible and its gas is knowable.
///
/// ------------------------------ THE ORDER OF THE CHECKS ------------------------------
///
/// `beforeSwap` runs the compliance gate FIRST and the market gate second. That ordering is
/// deliberate and it is about what an observer learns from a revert: an unpermitted party gets
/// `UntrustedLocker` or `AccountNotPermitted` whether or not the market happens to be open, so
/// nobody can use the session boundary to probe the allowlist. It costs nothing, because both
/// paths revert.
///
/// `afterSwap` runs the price band, because the price the swap ends at is the only place the print
/// is knowable. See `MarketHoursModule` for the converging-swap exception and why removing it
/// would lock the pool out of its own band after an overnight gap.
///
/// ------------------------------ EXIT, AGAIN ------------------------------
///
/// This contract does not narrow `PermissionedPoolHook`'s exit guarantee by one line.
/// `_beforeRemoveLiquidity` is inherited unchanged: no oracle, no pause, no calendar, no halt, no
/// trusted-router requirement. A halted market, a closed session, a dead price oracle and a dead
/// compliance oracle all leave withdrawal working. The only thing that can refuse an exit remains
/// `freezeDeniedExits` on a locally denylisted account, exactly as documented there.
///
/// Adding a market-hours check to the exit path would mean an issuer could trap LP capital by
/// halting, and no safety control should be able to do that.
///
/// ------------------------------ ADMIN ------------------------------
///
/// Two seats, and they are not the same seat:
///
///   * `owner` (`Ownable2Step`) - governance. Owns the compliance configuration, the trusted-router
///     set, the allow/denylists, the global pause, the compliance oracle, the price oracle, the
///     band widths, the guardian, and who each pool's issuer is. MUST be a timelock or multisig on
///     any chain holding real funds.
///
///   * `issuer` (per pool) and `marketGuardian` (global) - the fast, deliberately weaker seats,
///     which can halt and re-cut the calendar but cannot touch identity, oracles or bands. See the
///     role note in `MarketHoursModule`.
contract StockPairHook is PermissionedPoolHook, MarketHoursModule {
    using LPFeeLibrary for uint24;

    /// @param _poolManager The CL pool manager this hook serves.
    /// @param initialOwner Governance seat. On mainnet this MUST be a timelock, not an EOA.
    constructor(ICLPoolManager _poolManager, address initialOwner)
        PermissionedPoolHook(_poolManager, initialOwner)
    {}

    /// @inheritdoc IHooks
    /// @dev `PermissionedPoolHook`'s four permissions plus `afterSwap` for the price band.
    /// No returns-delta permission: this hook takes no value from the pool.
    function getHooksRegistrationBitmap() public pure override returns (uint16) {
        return BEFORE_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_REMOVE_LIQUIDITY | BEFORE_SWAP | AFTER_SWAP;
    }

    /*//////////////////////////////////////////////////////////////
                            MIXIN SEAM
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc MarketHoursModule
    function _marketAdmin() internal view override returns (address) {
        return owner();
    }

    /// @inheritdoc MarketHoursModule
    /// @dev Identical to the validation `PermissionedPoolHook.configurePool` performs, so the two
    /// configuration calls cannot disagree about which pool they are describing.
    function _requireOwnPoolKey(PoolKey calldata key) internal view override {
        if (address(key.hooks) != address(this)) revert HookMismatch(address(key.hooks));
        if (address(key.poolManager) != address(poolManager)) {
            revert PoolManagerMismatch(address(key.poolManager));
        }
        if (key.fee.isDynamicLPFee()) revert PoolMustUseStaticFee(key.fee);
    }

    /*//////////////////////////////////////////////////////////////
                                 HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Both halves must be configured before the pool can exist. Requiring the market half
    /// here is what stops an issuer initializing a pair, publishing the key, and only then
    /// discovering that the calendar was never set - at which point the hours would silently not
    /// apply, which is the worst of the available failures.
    ///
    /// The band check on the birth price runs LAST, after both configuration gates, so a
    /// misconfigured key still reports the configuration error rather than an oracle one. See
    /// `MarketHoursModule._requireInitialPriceInBand`.
    function _beforeInitialize(address sender, PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        view
        override
        returns (bytes4)
    {
        PoolId poolId = key.toId();
        if (!_markets[poolId].configured) revert MarketNotConfigured(poolId);
        bytes4 selector = super._beforeInitialize(sender, key, sqrtPriceX96);
        _requireInitialPriceInBand(poolId, sqrtPriceX96);
        return selector;
    }

    /// @dev Compliance gate, then market gate. See the ordering note above.
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) = super._beforeSwap(sender, key, params, hookData);
        _requireMarketOpen(key.toId());
        return (selector, delta, fee);
    }

    /// @dev The price band. Registered by this contract, not by `PermissionedPoolHook`, which has
    /// no `afterSwap` of its own.
    function _afterSwap(
        address, /* sender */
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta, /* delta */
        bytes calldata /* hookData */
    ) internal view override returns (bytes4, int128) {
        PoolId poolId = key.toId();
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        _requirePriceInBand(poolId, params.zeroForOne, sqrtPriceX96);
        return (ICLHooks.afterSwap.selector, int128(0));
    }

    /// @dev Compliance gate, then - only if the pool opted into `gateLiquidity` - the market gate.
    ///
    /// `gateLiquidity` defaults off because blocking additions outside hours restricts an action
    /// that cannot move the pool's price and cannot acquire the asset from anyone: on a
    /// concentrated-liquidity pool, minting adds inventory at the current price rather than
    /// trading against it. An issuer who nonetheless wants inventory frozen alongside the market -
    /// so that a halt means "nothing about this pool changes" - turns it on.
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        bytes4 selector = super._beforeAddLiquidity(sender, key, params, hookData);
        PoolId poolId = key.toId();
        if (!_markets[poolId].configured) revert MarketNotConfigured(poolId);
        if (_liquidityGated(poolId)) _requireMarketOpen(poolId);
        return selector;
    }
}
