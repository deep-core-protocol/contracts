// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {BaseCLHook} from "../base/BaseCLHook.sol";
import {OracleModule} from "./OracleModule.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ILockCallback} from "infinity-core/src/interfaces/ILockCallback.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "infinity-core/src/types/BeforeSwapDelta.sol";

/// @title DeepCoreOracleHook
/// @notice The price oracle DeepCore: `OracleModule` alone, as a CL hook. A pool born on it keeps a
/// truncated time-weighted average tick that other contracts read with `consult`. Design of record:
/// `docs/products/price-oracle-deepcore.md`.
///
/// It takes no delta, sets no fee, holds nothing and has NO ROLE: no owner, no pause, no setter.
/// Every parameter is a constructor immutable. The callbacks are `onlyPoolManager` (BaseCLHook) and
/// read the tick from the pool, never from an argument.
///
/// ############################## WHAT IT MUST NOT BE USED FOR ##############################
///
///  1. a spot price (it is an average that lags by design);
///  2. a window under `ORACLE_MIN_WINDOW_SECONDS` (refused);
///  3. liquidations, collateral valuation or minting against a THIN pool (a time-weighted mean
///     resists a short attack, not an attacker who can hold a thin pool's price for the window);
///  4. launch tokens (launch pools cannot carry this hook);
///  5. the reference of a price band on the same pool;
///  6. settlement with no second source;
///  7. a quiet pool without checking `lastWriteAge`;
///  8. a pool with a fee-on-transfer or rebasing token;
///  9. anything across chains;
/// 10. proof that a DeepCore is safe.
///
/// ############################## FUNDS ##############################
///
/// The hook is never owed anything. Value can reach it only by mistake: an ERC-20 transfer, ERC-6909
/// vault claims transferred to it, or native forced in (`selfdestruct`). ONE path out for all of it:
/// `sweep(currency)`, permissionless, which redeems any claims through the hook's own vault lock and
/// pays the WHOLE balance to the immutable `protocolRecipient`. `receive` accepts only the vault (the
/// native leg of a redemption). No `fallback`. ERC-721/1155 have no path in (no receiver hooks).
///
/// Bitmap: afterInitialize | beforeSwap = bits 1, 6 = 0x0042. No liquidity callback, so it can
/// never block or trap a position, and `DeepCoreLPLocker` accepts positions on it. No beforeInitialize:
/// any key may be born on it; a dynamic-fee key here keeps an LP fee of zero for ever (nothing sets
/// it), which is that pool creator's choice and harms nobody but its own LPs.
contract DeepCoreOracleHook is BaseCLHook, OracleModule, ReentrancyGuard, ILockCallback {
    using CurrencyLibrary for Currency;

    IVault public immutable vault;
    /// @notice The only address a swept unit can reach (the Safe).
    address public immutable protocolRecipient;

    /// @dev Set only across this contract's own `vault.lock` call in `sweep`.
    bool private _lockCallbackArmed;

    error ZeroAddress();
    error VaultMismatch();
    error NothingToSweep(Currency currency);
    error NativeNotAccepted();
    error UnexpectedLockCallback();

    event Swept(Currency indexed currency, address indexed recipient, uint256 amount);

    /// @param poolManager_ DeepCore's CL pool manager; `vault_` must be its vault.
    /// @param protocolRecipient_ The Safe: where misdirected value is swept.
    constructor(
        ICLPoolManager poolManager_,
        IVault vault_,
        address protocolRecipient_,
        uint24 maxTickDelta_,
        uint32 minWindowSeconds_,
        uint16 initialCardinality_
    ) BaseCLHook(poolManager_) OracleModule(maxTickDelta_, minWindowSeconds_, initialCardinality_) {
        if (address(vault_) == address(0) || protocolRecipient_ == address(0)) revert ZeroAddress();
        if (address(poolManager_.vault()) != address(vault_)) revert VaultMismatch();
        vault = vault_;
        protocolRecipient = protocolRecipient_;
    }

    /// @notice Native reaches this contract only as redeemed vault claims (inside `sweep`).
    receive() external payable {
        if (msg.sender != address(vault)) revert NativeNotAccepted();
    }

    function getHooksRegistrationBitmap() public pure override returns (uint16) {
        return AFTER_INITIALIZE | BEFORE_SWAP;
    }

    /*//////////////////////////////////////////////////////////////
                               CALLBACKS
    //////////////////////////////////////////////////////////////*/

    function _afterInitialize(address, PoolKey calldata key, uint160, int24 tick) internal override returns (bytes4) {
        _oracleInitialize(key.toId(), tick);
        return ICLHooks.afterInitialize.selector;
    }

    /// @dev Never reverts: one static read of the pool, at most two slot writes, no external call to
    /// anything settable. Returns no delta and no fee override.
    function _beforeSwap(address, PoolKey calldata key, ICLPoolManager.SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        (, int24 tick,,) = poolManager.getSlot0(id);
        _oracleWrite(id, tick);
        return (ICLHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _oracleCurrentTick(PoolId id) internal view override returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(id);
    }

    /*//////////////////////////////////////////////////////////////
                                 FUNDS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pay everything this contract holds in `currency` (redeemed vault claims included) to
    /// the immutable protocol recipient. Permissionless.
    function sweep(Currency currency) external nonReentrant returns (uint256 amount) {
        uint256 claims = vault.balanceOf(address(this), currency);
        if (claims != 0) {
            _lockCallbackArmed = true;
            vault.lock(abi.encode(currency, claims));
            _lockCallbackArmed = false;
        }
        amount = currency.balanceOfSelf();
        if (amount == 0) revert NothingToSweep(currency);
        emit Swept(currency, protocolRecipient, amount);
        currency.transfer(protocolRecipient, amount);
    }

    /// @inheritdoc ILockCallback
    /// @dev Reachable only across `sweep`'s own `vault.lock`. `burn` credits +amount, `take` debits it.
    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(vault) || !_lockCallbackArmed) revert UnexpectedLockCallback();
        (Currency currency, uint256 amount) = abi.decode(data, (Currency, uint256));
        vault.burn(address(this), currency, amount);
        vault.take(currency, address(this), amount);
        return "";
    }
}
