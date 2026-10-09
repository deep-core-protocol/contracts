/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {
    HOOKS_BEFORE_BURN_OFFSET,
    HOOKS_AFTER_BURN_OFFSET,
    HOOKS_AFTER_BURN_RETURNS_DELTA_OFFSET
} from "infinity-core/src/pool-bin/interfaces/IBinHooks.sol";

import {IBinPositionManager} from "infinity-periphery/src/pool-bin/interfaces/IBinPositionManager.sol";
import {IBinFungibleToken} from "infinity-periphery/src/pool-bin/interfaces/IBinFungibleToken.sol";
import {IImmutableState} from "infinity-periphery/src/interfaces/IImmutableState.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";

import {IDeepCoreBinLPLocker, BinLock, LockParams} from "./interfaces/IDeepCoreBinLPLocker.sol";

/// @title DeepCoreBinLPLocker
/// @notice A one-way door for Bin-pool liquidity shares. Shares that enter are never withdrawn or
/// transferred, and the bin-liquidity they were worth on arrival is never burned. Only the value they
/// GAIN afterwards - LP swap fees, composition fees, donations - is ever realised, and it is split
/// between the launch's creator, an optional integrator and the protocol in proportions fixed at lock.
///
/// @dev ############################ WHY THIS NEEDS ARITHMETIC ############################
///
/// Bin LP fees compound into `reserveOfBin` (`BinPool.swap`); nothing accrues per position, so the only
/// way to realise a fee is to BURN shares. The CL locker's "the liquidity argument is the literal 0" has
/// no Bin equivalent. The guarantee is instead the following invariant, and `collectFees` is the only
/// code path that can decrease a lock's shares:
///
///   For every lock k and bin b, with L_b = P_b*x + y*2^128 (core's `getBin` liquidity) and S_b the
///   bin's total shares:      shares[k][b] * L_b / S_b  >=  principal[k][b]
///   where principal[k][b] = ceil(sharesAtLock * L_b / S_b), written once at lock.
///
/// It holds because (read from this fork, see docs/kit-v2-integration.md section 10):
///   1. Every core operation leaves L_b / S_b equal or higher: an in-bin swap prices every unit at the
///      bin's fixed price and rounds for the bin, then adds the LP fee; third-party mints and burns
///      round their shares/outputs down; composition fees and donations only add reserves.
///   2. No operation moves value between bins, so the per-bin statement is exact.
///   3. A harvest keeps `ceil(principal * S / L)` shares (rounded UP) and core pays the burn floored,
///      which raises L/S for what remains. Both rounding directions point at the principal.
///
/// Selling launch tokens to buyers converts a bin's x into y at P_b and leaves L_b unchanged, so SALE
/// PROCEEDS ARE PRINCIPAL. They stay locked, exactly as they do in a bought-through CL range in
/// `DeepCoreLPLocker`, and the protocol floor never applies to them.
///
/// ############################ THE NO-WITHDRAW SURFACE ############################
///
///   1. Only a share holder or its `approveForAll` operator can `batchTransferFrom` or
///      `BIN_REMOVE_LIQUIDITY` shares (`BinFungibleToken`, `checkApproval`). This contract holds them.
///   2. This contract never calls `approveForAll`, and calls `batchTransferFrom` only with
///      `from = msg.sender, to = address(this)`. The fork has no signature permit for bin shares, and this
///      contract implements no ERC-1271 - adding it must never happen.
///   3. The only other position-manager call is `modifyLiquidities` with a plan built in `collectFees`:
///      `BIN_REMOVE_LIQUIDITY(from = this, amounts = harvestableShares(...))` then
///      `TAKE_PAIR(currency0, currency1, this)`.
///
/// ############################### ACCOUNTING ###############################
///
/// Identical to `DeepCoreLPLocker`: pull payments; credit what ARRIVED (balance delta); `totalOwed` is the
/// sum of all claimable balances; `skim` credits true surplus to the protocol; creator and integrator
/// shares floor and the protocol receives the remainder.
///
/// ########################## WHAT IT DOES NOT PROTECT ##########################
///
///   * Fees are delivered in each bin's CURRENT composition, valued at the bin's price. Uncollected fees
///     carry the bin's price exposure until someone collects. Collect often.
///   * Fees accrued before a lock are principal (the baseline is the share price at lock).
///   * Shares `batchTransferFrom`-ed to this address without `lock` are orphans: no record, never burned,
///     never moved, permanent liquidity. Same class as a CL NFT plain-transferred to `DeepCoreLPLocker`.
///   * Pools whose hook registers `beforeBurn`/`afterBurn` are refused. A hook that keeps the LP fee near
///     zero and charges its own fee instead is NOT detected: the floor applies to LP fees.
///   * A token issuer (pause, `adminBurn`): as `DeepCoreLPLocker`. A paused token reverts the whole harvest;
///     the fees stay in the bins and keep compounding.
///
/// ############################### NO ADMIN ###############################
///
/// No owner, no pause, no upgrade, no setter. The only mutable role is a lock's `creator`, which only that
/// creator can hand on.
contract DeepCoreBinLPLocker is IDeepCoreBinLPLocker, ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using PoolIdLibrary for PoolKey;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Basis-point denominator. A unit, not configuration.
    uint16 public constant BPS_DENOMINATOR = 10_000;

    /// @notice Upper bound on `maxBinsPerLock` itself, so no deployment can promise a lock size that no
    /// block could ever collect.
    uint16 public constant MAX_BINS_HARD_CAP = 256;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice The only position manager whose shares this locker accepts, and the only contract it ever
    /// calls with a state-changing call.
    IBinPositionManager public immutable positionManager;

    /// @notice The Bin pool manager behind `positionManager`. Every lock's `key.poolManager` must equal it.
    IBinPoolManager public immutable binPoolManager;

    /// @notice The Vault behind `positionManager`. The only address allowed to send native currency.
    address public immutable vault;

    /// @notice Receives `protocolBps` of every collection, and every `skim`. Deploy it as the Safe.
    address public immutable protocolRecipient;

    /// @notice Lowest `protocolBps` a lock may declare.
    uint16 public immutable minProtocolBps;

    /// @notice Highest `protocolBps` a lock may declare.
    uint16 public immutable maxProtocolBps;

    /// @notice Highest `integratorBps` a lock may declare.
    uint16 public immutable maxIntegratorBps;

    /// @notice Most bins one lock may hold. Bounds the gas of `lock` and of every `collectFees`.
    uint16 public immutable maxBinsPerLock;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @dev Per-bin record of one lock. `principal` never changes; `shares` only falls, in `collectFees`.
    struct BinRecord {
        uint256 shares;
        uint256 principal;
    }

    mapping(uint256 lockId => BinLock) private _locks;

    /// @dev Strictly increasing; stored as a packed `uint24[]` (ten ids per slot).
    mapping(uint256 lockId => uint24[]) private _binIds;

    mapping(uint256 lockId => mapping(uint256 index => BinRecord)) private _bins;

    /// @dev Written on the first lock in a pool. Everything in it is part of the pool id, so it can never
    /// disagree with `BinLock.poolId`.
    mapping(PoolId poolId => PoolKey) private _poolKeys;

    /// @inheritdoc IDeepCoreBinLPLocker
    mapping(uint256 lockId => address) public override pendingCreator;

    mapping(address account => mapping(Currency currency => uint256 amount)) private _claimable;

    /// @inheritdoc IDeepCoreBinLPLocker
    mapping(Currency currency => uint256 amount) public override totalOwed;

    /// @notice Number of locks ever created. Lock ids are `1..lockCount`; 0 is never a lock.
    uint256 public lockCount;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    /// @param positionManager_ The Bin position manager of the shared core on this chain.
    /// @param protocolRecipient_ The protocol's fee address. Must be able to call `claim` (a Safe).
    /// @param minProtocolBps_ Floor on every lock's protocol share.
    /// @param maxProtocolBps_ Ceiling on every lock's protocol share.
    /// @param maxIntegratorBps_ Ceiling on every lock's integrator share.
    /// @param maxBinsPerLock_ Most bins per lock, sized to the chain's gas limit (1..MAX_BINS_HARD_CAP).
    constructor(
        IBinPositionManager positionManager_,
        address protocolRecipient_,
        uint16 minProtocolBps_,
        uint16 maxProtocolBps_,
        uint16 maxIntegratorBps_,
        uint16 maxBinsPerLock_
    ) {
        if (address(positionManager_) == address(0) || protocolRecipient_ == address(0)) revert ZeroAddress();
        if (protocolRecipient_ == address(this)) revert ProtocolRecipientIsLocker();
        if (
            minProtocolBps_ > maxProtocolBps_ || maxProtocolBps_ > BPS_DENOMINATOR
                || maxIntegratorBps_ > BPS_DENOMINATOR
        ) {
            revert InvalidBpsBounds(minProtocolBps_, maxProtocolBps_, maxIntegratorBps_);
        }
        if (maxBinsPerLock_ == 0 || maxBinsPerLock_ > MAX_BINS_HARD_CAP) revert InvalidMaxBinsPerLock(maxBinsPerLock_);

        address vault_ = address(IImmutableState(address(positionManager_)).vault());
        if (vault_ == address(0)) revert PositionManagerHasNoVault();
        IBinPoolManager binPoolManager_ = positionManager_.binPoolManager();
        if (address(binPoolManager_) == address(0)) revert PositionManagerHasNoPoolManager();

        positionManager = positionManager_;
        binPoolManager = binPoolManager_;
        vault = vault_;
        protocolRecipient = protocolRecipient_;
        minProtocolBps = minProtocolBps_;
        maxProtocolBps = maxProtocolBps_;
        maxIntegratorBps = maxIntegratorBps_;
        maxBinsPerLock = maxBinsPerLock_;
    }

    /*//////////////////////////////////////////////////////////////
                                  LOCK
    //////////////////////////////////////////////////////////////*/

    /// @notice The only entrance. Pulls `shares[i]` of bin `binIds[i]` from the CALLER and locks them
    /// forever under the split in `p`.
    /// @dev The caller must have `approveForAll(address(this), true)` on the position manager. That approval
    /// can only ever be exercised here, by the approver: the pull source is `msg.sender`, not a parameter.
    /// Must be called while the Vault is unlocked (`batchTransferFrom` is `onlyIfVaultUnlocked`), i.e. after
    /// the mint's `modifyLiquidities` has returned.
    function lock(PoolKey calldata key, uint24[] calldata binIds, uint256[] calldata shares, LockParams calldata p)
        external
        override
        nonReentrant
        returns (uint256 lockId)
    {
        // ---- validate the declared split, before any external read ----
        _validateSplit(p);

        // ---- validate the pool ----
        if (address(key.poolManager) != address(binPoolManager)) revert PoolManagerMismatch(address(key.poolManager));
        // Every harvest is a burn. Checked on the pool's immutable `parameters` bitmap, which core
        // cross-checks against the hook at initialize. `afterBurnReturnsDelta` requires `afterBurn` in core,
        // and is checked anyway so this line does not depend on that.
        if (
            Hooks.hasOffsetEnabled(key.parameters, HOOKS_BEFORE_BURN_OFFSET)
                || Hooks.hasOffsetEnabled(key.parameters, HOOKS_AFTER_BURN_OFFSET)
                || Hooks.hasOffsetEnabled(key.parameters, HOOKS_AFTER_BURN_RETURNS_DELTA_OFFSET)
        ) {
            revert HookInterceptsRemoval(address(key.hooks));
        }

        // ---- validate the bins ----
        uint256 n = binIds.length;
        if (n != shares.length) revert LengthMismatch(n, shares.length);
        if (n == 0 || n > maxBinsPerLock) revert InvalidBinCount(n, maxBinsPerLock);
        for (uint256 i; i < n; ++i) {
            if (i != 0 && binIds[i] <= binIds[i - 1]) revert BinIdsNotStrictlyIncreasing(i);
            if (shares[i] == 0) revert ZeroShares(binIds[i]);
        }

        PoolId poolId = key.toId();
        uint256[] memory tokenIds = new uint256[](n);
        address[] memory selves = new address[](n);
        for (uint256 i; i < n; ++i) {
            // BinTokenLibrary.toTokenId
            tokenIds[i] = uint256(keccak256(abi.encode(poolId, uint256(binIds[i]))));
            selves[i] = address(this);
        }

        // ---- pull, measured ----
        IBinFungibleToken shareToken = IBinFungibleToken(address(positionManager));
        uint256[] memory before = shareToken.balanceOfBatch(selves, tokenIds);
        shareToken.batchTransferFrom(msg.sender, address(this), tokenIds, shares);
        uint256[] memory afterPull = shareToken.balanceOfBatch(selves, tokenIds);

        // ---- effects ----
        unchecked {
            lockId = ++lockCount;
        }
        uint256[] memory principals = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            uint256 received = afterPull[i] - before[i];
            if (received != shares[i]) revert SharesNotReceived(binIds[i], shares[i], received);

            (,, uint256 binLiquidity, uint256 binShares) = binPoolManager.getBin(poolId, binIds[i]);
            // binShares >= shares[i] > 0 whenever the pull succeeded, so the division is defined. Rounded UP:
            // the principal is the floor a harvest can never cross, so its rounding favours the principal.
            uint256 principal = binShares == 0 ? 0 : FullMath.mulDivRoundingUp(shares[i], binLiquidity, binShares);
            if (principal == 0) revert EmptyBin(binIds[i]);

            principals[i] = principal;
            _bins[lockId][i] = BinRecord({shares: shares[i], principal: principal});
            _binIds[lockId].push(binIds[i]);
        }

        _locks[lockId] = BinLock({
            creator: p.creator,
            creatorBps: p.creatorBps,
            integratorBps: p.integratorBps,
            protocolBps: p.protocolBps,
            lockedAt: uint48(block.timestamp),
            integrator: p.integrator,
            binCount: uint16(n),
            poolId: poolId
        });
        if (_poolKeys[poolId].parameters == bytes32(0)) _poolKeys[poolId] = key;

        emit BinsLocked(
            lockId,
            poolId,
            p.creator,
            p.integrator,
            p.creatorBps,
            p.integratorBps,
            p.protocolBps,
            binIds,
            shares,
            principals,
            msg.sender
        );
    }

    /*//////////////////////////////////////////////////////////////
                                COLLECT
    //////////////////////////////////////////////////////////////*/

    /// @notice Burn the share fraction of every bin that exceeds its principal, take the proceeds into this
    /// contract and credit the three parties.
    /// @dev Permissionless: it can only convert value ABOVE each bin's fixed principal into claimable
    /// balances whose split was fixed at lock time. Reverts `NothingToCollect` when no bin has a fee large
    /// enough to pay out a unit, so a keeper's simulation is a free read.
    ///
    /// Shares are decremented BEFORE the position-manager call; credit follows it, because credit is what
    /// arrived. `nonReentrant` is shared with every other mutating entrypoint.
    function collectFees(uint256 lockId) external override nonReentrant returns (uint256 amount0, uint256 amount1) {
        BinLock memory lk = _locks[lockId];
        if (lk.creator == address(0)) revert NotLocked(lockId);

        uint256 n = lk.binCount;
        uint24[] storage ids = _binIds[lockId];
        uint256[] memory burnIds = new uint256[](n);
        uint256[] memory burnAmounts = new uint256[](n);
        uint256 m;

        for (uint256 i; i < n; ++i) {
            uint24 binId = ids[i];
            BinRecord storage rec = _bins[lockId][i];
            (uint128 rx, uint128 ry, uint256 binLiquidity, uint256 binShares) = binPoolManager.getBin(lk.poolId, binId);
            uint256 burn = harvestableShares(rec.shares, rec.principal, rx, ry, binLiquidity, binShares);
            if (burn == 0) continue;
            // Cannot underflow: harvestableShares returns at most `shares - 1`.
            unchecked {
                rec.shares -= burn;
            }
            burnIds[m] = binId;
            burnAmounts[m] = burn;
            unchecked {
                ++m;
            }
        }
        if (m == 0) revert NothingToCollect(lockId);

        // Trim the arrays to the bins actually burned; core reverts on a zero burn amount.
        assembly ("memory-safe") {
            mstore(burnIds, m)
            mstore(burnAmounts, m)
        }
        emit FeeSharesBurned(lockId, msg.sender, burnIds, burnAmounts);

        PoolKey memory key = _poolKeys[lk.poolId];
        uint256 before0 = key.currency0.balanceOfSelf();
        uint256 before1 = key.currency1.balanceOfSelf();

        Plan memory plan = Planner.init();
        plan.add(
            Actions.BIN_REMOVE_LIQUIDITY,
            abi.encode(
                IBinPositionManager.BinRemoveLiquidityParams({
                    poolKey: key,
                    amount0Min: 0,
                    amount1Min: 0,
                    ids: burnIds,
                    amounts: burnAmounts,
                    from: address(this),
                    hookData: bytes("")
                })
            )
        );
        plan.add(Actions.TAKE_PAIR, abi.encode(key.currency0, key.currency1, address(this)));
        positionManager.modifyLiquidities(plan.encode(), block.timestamp);

        amount0 = _received(key.currency0, before0);
        amount1 = _received(key.currency1, before1);

        _credit(lockId, lk, key.currency0, amount0);
        _credit(lockId, lk, key.currency1, amount1);
    }

    /*//////////////////////////////////////////////////////////////
                                 CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw the caller's entire credited balance of one currency to `to`.
    function claim(Currency currency, address to) external override nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = _claimable[msg.sender][currency];
        if (amount == 0) revert NothingToClaim();

        _claimable[msg.sender][currency] = 0;
        totalOwed[currency] -= amount;

        emit Claimed(msg.sender, currency, to, amount);
        currency.transfer(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                  SKIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Credit any currency balance above `totalOwed` to `protocolRecipient`.
    /// @dev Currencies only. Orphaned bin SHARES are deliberately not skimmable - see the contract notes.
    function skim(Currency currency) external override nonReentrant returns (uint256 surplus) {
        uint256 balance = currency.balanceOfSelf();
        uint256 owed = totalOwed[currency];
        if (balance <= owed) revert NothingToSkim();
        unchecked {
            surplus = balance - owed;
        }
        _claimable[protocolRecipient][currency] += surplus;
        totalOwed[currency] = balance;
        emit Skimmed(currency, msg.sender, surplus);
    }

    /*//////////////////////////////////////////////////////////////
                            CREATOR ROTATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Nominate a new creator for one lock. `address(0)` cancels a pending nomination.
    function transferCreator(uint256 lockId, address newCreator) external override {
        address current = _locks[lockId].creator;
        if (current == address(0)) revert NotLocked(lockId);
        if (msg.sender != current) revert NotCreator(lockId, msg.sender);
        if (newCreator == address(this)) revert InvalidCreator(newCreator);
        pendingCreator[lockId] = newCreator;
        emit CreatorTransferStarted(lockId, current, newCreator);
    }

    /// @notice Accept a nomination. Future collections credit the new creator; balances already credited
    /// stay claimable by the previous creator.
    function acceptCreator(uint256 lockId) external override {
        address pending = pendingCreator[lockId];
        if (pending == address(0) || msg.sender != pending) revert NotPendingCreator(lockId, msg.sender);
        address previous = _locks[lockId].creator;
        _locks[lockId].creator = pending;
        delete pendingCreator[lockId];
        emit CreatorTransferred(lockId, previous, pending);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IDeepCoreBinLPLocker
    function getLock(uint256 lockId) external view override returns (BinLock memory) {
        return _locks[lockId];
    }

    /// @inheritdoc IDeepCoreBinLPLocker
    function getPoolKey(uint256 lockId) external view override returns (PoolKey memory) {
        return _poolKeys[_locks[lockId].poolId];
    }

    /// @inheritdoc IDeepCoreBinLPLocker
    function getLockedBins(uint256 lockId)
        external
        view
        override
        returns (uint24[] memory binIds, uint256[] memory shares, uint256[] memory principals)
    {
        binIds = _binIds[lockId];
        uint256 n = binIds.length;
        shares = new uint256[](n);
        principals = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            BinRecord storage rec = _bins[lockId][i];
            shares[i] = rec.shares;
            principals[i] = rec.principal;
        }
    }

    /// @inheritdoc IDeepCoreBinLPLocker
    function previewCollect(uint256 lockId) external view override returns (uint256[] memory sharesToBurn) {
        BinLock memory lk = _locks[lockId];
        uint256 n = lk.binCount;
        sharesToBurn = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            BinRecord storage rec = _bins[lockId][i];
            (uint128 rx, uint128 ry, uint256 binLiquidity, uint256 binShares) =
                binPoolManager.getBin(lk.poolId, _binIds[lockId][i]);
            sharesToBurn[i] = harvestableShares(rec.shares, rec.principal, rx, ry, binLiquidity, binShares);
        }
    }

    /// @inheritdoc IDeepCoreBinLPLocker
    function isLocked(uint256 lockId) external view override returns (bool) {
        return _locks[lockId].creator != address(0);
    }

    /// @inheritdoc IDeepCoreBinLPLocker
    function claimable(address account, Currency currency) external view override returns (uint256) {
        return _claimable[account][currency];
    }

    /// @notice The exact split `collectFees` applies. Identical to `DeepCoreLPLocker.splitAmount`: creator and
    /// integrator floor, the protocol takes the remainder, the three always sum to `amount`.
    function splitAmount(uint256 amount, uint16 creatorBps, uint16 integratorBps)
        public
        pure
        override
        returns (uint256 creatorShare, uint256 integratorShare, uint256 protocolShare)
    {
        uint256 bps = uint256(creatorBps) + integratorBps;
        if (bps > BPS_DENOMINATOR) revert BpsDoNotSumToDenominator(bps);
        creatorShare = FullMath.mulDiv(amount, creatorBps, BPS_DENOMINATOR);
        integratorShare = FullMath.mulDiv(amount, integratorBps, BPS_DENOMINATOR);
        // Cannot underflow: floor(a*c/D) + floor(a*i/D) <= floor(a*(c+i)/D) <= a when c+i <= D.
        unchecked {
            protocolShare = amount - creatorShare - integratorShare;
        }
    }

    /// @inheritdoc IDeepCoreBinLPLocker
    /// @dev THE PRINCIPAL GUARD. Keeps `ceil(principal * binShares / binLiquidity)` shares, so what remains is
    /// worth at least `principal` at the bin's price before the burn, and core's floored payout only raises
    /// the remaining shares' value. Returns 0 (skip) when the fee would burn no share, or when core would
    /// pay out zero of both currencies (`BinPool__ZeroAmountsOut` would revert the whole harvest).
    function harvestableShares(
        uint256 shares,
        uint256 principal,
        uint128 binReserveX,
        uint128 binReserveY,
        uint256 binLiquidity,
        uint256 binShares
    ) public pure override returns (uint256 burn) {
        if (shares == 0 || binLiquidity == 0 || binShares == 0) return 0;
        // A lock holds `shares` of the bin, so binShares >= shares; defend anyway against a caller of this pure
        // function passing an impossible state.
        if (binShares < shares) return 0;
        uint256 keep = FullMath.mulDivRoundingUp(principal, binShares, binLiquidity);
        if (keep >= shares) return 0;
        // A lock with principal > 0 always keeps at least one share, so a bin is never emptied by a harvest.
        if (keep == 0) keep = 1;
        burn = shares - keep;
        if (burn == 0) return 0;
        if (
            FullMath.mulDiv(burn, binReserveX, binShares) == 0 && FullMath.mulDiv(burn, binReserveY, binShares) == 0
        ) return 0;
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNALS
    //////////////////////////////////////////////////////////////*/

    function _validateSplit(LockParams calldata p) private view {
        if (p.creator == address(0) || p.creator == address(this)) revert InvalidCreator(p.creator);
        if ((p.integrator == address(0)) != (p.integratorBps == 0) || p.integrator == address(this)) {
            revert InvalidIntegrator(p.integrator, p.integratorBps);
        }
        if (p.protocolBps < minProtocolBps || p.protocolBps > maxProtocolBps) {
            revert ProtocolBpsOutOfRange(p.protocolBps, minProtocolBps, maxProtocolBps);
        }
        if (p.integratorBps > maxIntegratorBps) revert IntegratorBpsTooHigh(p.integratorBps, maxIntegratorBps);
        uint256 sum = uint256(p.creatorBps) + p.integratorBps + p.protocolBps;
        if (sum != BPS_DENOMINATOR) revert BpsDoNotSumToDenominator(sum);
    }

    /// @dev Saturating, as in `DeepCoreLPLocker`.
    function _received(Currency currency, uint256 balanceBefore) private view returns (uint256) {
        uint256 balanceAfter = currency.balanceOfSelf();
        unchecked {
            return balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;
        }
    }

    function _credit(uint256 lockId, BinLock memory lk, Currency currency, uint256 amount) private {
        if (amount == 0) return;
        (uint256 creatorShare, uint256 integratorShare, uint256 protocolShare) =
            splitAmount(amount, lk.creatorBps, lk.integratorBps);

        if (creatorShare != 0) _claimable[lk.creator][currency] += creatorShare;
        if (integratorShare != 0) _claimable[lk.integrator][currency] += integratorShare;
        if (protocolShare != 0) _claimable[protocolRecipient][currency] += protocolShare;
        totalOwed[currency] += amount;

        emit FeesCollected(lockId, currency, msg.sender, amount, creatorShare, integratorShare, protocolShare);
    }

    /*//////////////////////////////////////////////////////////////
                                RECEIVE
    //////////////////////////////////////////////////////////////*/

    /// @dev Native proceeds arrive from `Vault.take` during `collectFees`. Anything else is refused.
    receive() external payable {
        if (msg.sender != vault) revert UnexpectedNativeSender(msg.sender);
    }
}
