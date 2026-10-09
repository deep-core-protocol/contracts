/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseCLHook} from "deepcore-hooks/src/base/BaseCLHook.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "infinity-core/src/types/BeforeSwapDelta.sol";

import {MarketHoursModule} from "./modules/MarketHoursModule.sol";

/// @title MarketHoursHook
/// @notice `MarketHoursModule` worn on its own: a pool that trades only during a session the
/// issuer defines, stops instantly when halted, and refuses to print outside a price band.
/// Anyone may trade it - there is no identity gate here.
///
/// @dev ################### NO LEGAL ADVICE IS GIVEN OR IMPLIED ###################
///
/// This is a MECHANISM. See `MarketHoursModule` for what it does and, more importantly, for what
/// it does not. Whether a pool configured this way satisfies any market-structure obligation in
/// any jurisdiction is a question for the issuer's counsel; it is not answered here.
///
/// ------------------------------ WHEN TO USE THIS RATHER THAN `StockPairHook` ------------------
///
/// Use this when the ASSET already carries its own transfer restriction - an ERC-1404 / ERC-3643
/// permissioned token, where the token's own `transfer` rejects non-permitted holders. In that
/// case the identity question is answered at the layer that can actually answer it (custody), and
/// what remains is the venue question: when may this thing trade, and at what prices. That is
/// exactly this contract's job, and layering a router allowlist on top of a permissioned token
/// buys very little for the trust it costs.
///
/// Use `StockPairHook` when the token is unrestricted and the pool itself has to be the gate.
///
/// ------------------------------ THE HONEST CAVEAT ------------------------------
///
/// A pool with market hours and no identity gate is a pool ANYONE can trade during those hours.
/// The hours are not a compliance control and this contract does not pretend they are. If the
/// asset needs restricted holders and the token does not enforce that, this hook alone leaves the
/// requirement unenforced.
///
/// ------------------------------ ADMIN ------------------------------
///
/// `Ownable2Step`. The owner is governance and should be `packages/governance/src/DeepCoreTimelock.sol`
/// or an equivalent multisig-plus-timelock on any chain holding real funds. The per-pool `issuer`
/// and the global `marketGuardian` are the fast, deliberately weaker seats; see the role note in
/// `MarketHoursModule`.
contract MarketHoursHook is BaseCLHook, MarketHoursModule, Ownable2Step {
    using LPFeeLibrary for uint24;

    /// @notice The pool key does not name this contract as its hook
    error HookMismatch(address declared);

    /// @notice The pool key names a different pool manager than this hook serves
    error PoolManagerMismatch(address declared);

    /// @notice This hook returns no LP fee override, so a dynamic-fee pool would sit at 0 fee
    /// forever. Reject such a pool rather than silently running a free market.
    error PoolMustUseStaticFee(uint24 fee);

    /// @notice `renounceOwnership` is permanently disabled. See the override.
    error RenounceDisabled();

    /// @notice `rescueERC20` was asked to pay the zero address.
    error RescueToZero();
    /// @notice `rescueERC20` found no balance of `token` here.
    error NothingToRescue(address token);
    /// @notice An ERC-20 sent here by mistake was moved out by the owner.
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    /// @param _poolManager The CL pool manager this hook serves.
    /// @param initialOwner Governance seat. On mainnet this MUST be a timelock, not an EOA.
    constructor(ICLPoolManager _poolManager, address initialOwner)
        BaseCLHook(_poolManager)
        Ownable(initialOwner)
    {}

    /**
     * @notice Permanently disabled. Reverts for every caller.
     *
     * @dev CLAUDE.md § "Deployed and unfixable" makes this the house rule for every contract
     * deployed from here on, and `MerkleEpochDistributor` is the reference.
     *
     * `configureMarket` and `setMarketGuardian` are the only owner-only functions, and
     * `configureMarket` is the ONLY route by which a pool's issuer, oracle, band widths,
     * `bandEnabled` and `sessionEnabled` ever change. Renouncing therefore removes no power that
     * could be abused against a trader; what it removes is every recovery:
     *
     *   * A compromised or departed issuer can never be replaced. It keeps `resume`,
     *     `setSessionHours` and the day overrides for the life of the hook, and the guardian's halt
     *     is only as durable as the issuer's willingness not to `resume`.
     *   * A band-enabled pool whose oracle is retired fails closed on every swap, and nobody can
     *     repoint the oracle or switch the band off. The pool stops trading permanently.
     *   * The guardian can never be rotated or removed.
     *
     * LP exits are unaffected either way — nothing in this hook gates removals — so this is a
     * governance-availability failure, but an irreversible one, and `transferOwnership` is itself
     * `onlyOwner`.
     *
     * The bounded form of the same intent already exists and is unaffected: an owner who wants out
     * transfers to the address that should have it. `Ownable2Step` means that cannot land somewhere
     * unreachable by typo.
     */
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Move an ERC-20 that was sent here by mistake to `to`.
    /// @dev This hook takes no hook delta and has no `receive`: it never holds value by design, so any ERC-20 balance is misdirected value with, until now, no path out
    /// (acceptance finding L-1, docs/protocol-acceptance.md, 2026-09-18). Whole balance, `SafeERC20`.
    function rescueERC20(address token, address to) external onlyOwner {
        if (to == address(0)) revert RescueToZero();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToRescue(token);
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    /// @inheritdoc IHooks
    /// @dev `beforeInitialize` refuses an unconfigured or dynamic-fee pool; `beforeSwap` applies
    /// the halt and the calendar; `afterSwap` applies the price band, which can only be judged
    /// once the resulting price exists; `beforeAddLiquidity` applies the halt and the calendar
    /// when the pool opts into `gateLiquidity`.
    ///
    /// No returns-delta permission: this hook takes no value from the pool.
    function getHooksRegistrationBitmap() public pure override returns (uint16) {
        return BEFORE_INITIALIZE | BEFORE_ADD_LIQUIDITY | BEFORE_SWAP | AFTER_SWAP;
    }

    /*//////////////////////////////////////////////////////////////
                            MIXIN SEAM
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc MarketHoursModule
    function _marketAdmin() internal view override returns (address) {
        return owner();
    }

    /// @inheritdoc MarketHoursModule
    function _requireOwnPoolKey(PoolKey calldata key) internal view override {
        if (address(key.hooks) != address(this)) revert HookMismatch(address(key.hooks));
        if (address(key.poolManager) != address(poolManager)) {
            revert PoolManagerMismatch(address(key.poolManager));
        }
        // Mirrors `_beforeInitialize`, so a misconfiguration surfaces at configuration time rather
        // than at pool creation, when the issuer has already published the key.
        if (key.fee.isDynamicLPFee()) revert PoolMustUseStaticFee(key.fee);
    }

    /*//////////////////////////////////////////////////////////////
                                 HOOKS
    //////////////////////////////////////////////////////////////*/

    /// @dev Refuses a pool the owner has not configured, and refuses a dynamic-fee pool.
    ///
    /// `sender` is ignored on purpose: it is whoever called `initialize`, which may be any
    /// periphery contract, and is not a trustworthy identity. The gate is that the OWNER must have
    /// configured this exact pool id, which cannot be forged because the pool id is the hash of
    /// the key core is initializing.
    ///
    /// On a band-enabled pool the birth price must also sit inside the band. `sqrtPriceX96` is the
    /// one input here an arbitrary caller chooses; see `_requireInitialPriceInBand`.
    function _beforeInitialize(address, /* sender */ PoolKey calldata key, uint160 sqrtPriceX96)
        internal
        view
        override
        returns (bytes4)
    {
        // A dynamic-fee pool stores an LP fee of 0 at initialization. This hook returns no
        // override and never calls `updateDynamicLPFee`, so such a pool would trade free forever.
        if (key.fee.isDynamicLPFee()) revert PoolMustUseStaticFee(key.fee);

        PoolId poolId = key.toId();
        if (!_markets[poolId].configured) revert MarketNotConfigured(poolId);
        _requireInitialPriceInBand(poolId, sqrtPriceX96);

        return ICLHooks.beforeInitialize.selector;
    }

    /// @dev The calendar and the halt. `sender` is the Vault locker and is deliberately unused:
    /// market hours are a property of the block timestamp and the pool's configuration, not of
    /// who is asking. Nothing here can be influenced by `hookData` either.
    function _beforeSwap(
        address, /* sender */
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata, /* params */
        bytes calldata /* hookData */
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        _requireMarketOpen(key.toId());
        // The pool is static-fee (enforced at initialization), so core ignores the returned fee.
        return _passthroughSwap();
    }

    /// @dev The price band, judged against the price the pool actually ended at.
    ///
    /// Reverting here reverts the whole swap, which is the point: the band is a rule about what
    /// may be PRINTED, and the print is not knowable before the swap runs.
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

    /// @dev The calendar and the halt applied to liquidity additions, if the pool opted in.
    ///
    /// Core routes here only when `liquidityDelta > 0`. There is deliberately no
    /// `beforeRemoveLiquidity`: nothing in this module may ever block an exit, so the callback
    /// that could is not registered at all. That is a stronger guarantee than an unregistered
    /// permission - core will not even call it.
    function _beforeAddLiquidity(
        address, /* sender */
        PoolKey calldata key,
        ICLPoolManager.ModifyLiquidityParams calldata, /* params */
        bytes calldata /* hookData */
    ) internal view override returns (bytes4) {
        PoolId poolId = key.toId();
        if (!_markets[poolId].configured) revert MarketNotConfigured(poolId);
        if (_liquidityGated(poolId)) _requireMarketOpen(poolId);
        return ICLHooks.beforeAddLiquidity.selector;
    }
}
