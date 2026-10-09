/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";

/// @dev The split declaration is SHARED with the CL locker on purpose: kit v2 builds one `LockParams`
/// and hands it to whichever locker matches the leg, and both lockers validate it against the same
/// kind of immutable bounds. Imported, not redeclared, so the two cannot drift apart silently.
import {LockParams} from "./IDeepCoreLPLocker.sol";

/// @notice One permanent Bin lock. Written once in `lock`; only `creator` can ever change.
/// @dev Packing: slot 0 = creator|creatorBps|integratorBps|protocolBps|lockedAt (32 bytes),
/// slot 1 = integrator|binCount, slot 2 = poolId. Per-bin records live beside it (`getLockedBins`).
struct BinLock {
    address creator;
    uint16 creatorBps;
    uint16 integratorBps;
    uint16 protocolBps;
    /// @dev `block.timestamp`, never `block.number` (CLAUDE.md section 3b).
    uint48 lockedAt;
    address integrator;
    uint16 binCount;
    PoolId poolId;
}

/// @title IDeepCoreBinLPLocker
/// @notice Events, errors and methods of the permanent Bin-position locker.
/// @dev Event and error names deliberately match `IDeepCoreLPLocker` wherever the meaning matches, so an
/// indexer or a UI that understands one locker understands the other. `tokenId` there is `lockId` here.
interface IDeepCoreBinLPLocker {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @param binIds Strictly increasing.
    /// @param shares Shares pulled into the lock per bin.
    /// @param principals Bin-liquidity each bin's shares were worth at lock time (`L = P*x + y<<128`
    /// units, rounded up). The floor `collectFees` can never burn below.
    /// @param from The account the shares were pulled from, which is also the caller.
    event BinsLocked(
        uint256 indexed lockId,
        PoolId indexed poolId,
        address indexed creator,
        address integrator,
        uint16 creatorBps,
        uint16 integratorBps,
        uint16 protocolBps,
        uint24[] binIds,
        uint256[] shares,
        uint256[] principals,
        address from
    );

    /// @notice The fee-only burn of one `collectFees` call, before the proceeds are credited.
    /// @param binIds Only the bins that were actually burned (skipped bins are omitted).
    /// @param sharesBurned Aligned with `binIds`.
    event FeeSharesBurned(uint256 indexed lockId, address indexed caller, uint256[] binIds, uint256[] sharesBurned);

    /// @dev Identical meaning to `IDeepCoreLPLocker.FeesCollected`; `lockId` in place of `tokenId`.
    event FeesCollected(
        uint256 indexed lockId,
        Currency indexed currency,
        address indexed caller,
        uint256 amount,
        uint256 creatorShare,
        uint256 integratorShare,
        uint256 protocolShare
    );

    event Claimed(address indexed account, Currency indexed currency, address indexed to, uint256 amount);

    /// @notice Balance above everything owed, credited to `protocolRecipient`.
    event Skimmed(Currency indexed currency, address indexed caller, uint256 amount);

    /// @param pending `address(0)` means a pending transfer was cancelled.
    event CreatorTransferStarted(uint256 indexed lockId, address indexed creator, address indexed pending);
    event CreatorTransferred(uint256 indexed lockId, address indexed previousCreator, address indexed newCreator);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error InvalidBpsBounds(uint16 minProtocolBps, uint16 maxProtocolBps, uint16 maxIntegratorBps);
    error InvalidMaxBinsPerLock(uint16 maxBinsPerLock);
    error ProtocolRecipientIsLocker();
    error PositionManagerHasNoVault();
    error PositionManagerHasNoPoolManager();
    error InvalidCreator(address creator);
    /// @notice `integrator` must be non-zero iff `integratorBps` is non-zero, and never the locker.
    error InvalidIntegrator(address integrator, uint16 integratorBps);
    error ProtocolBpsOutOfRange(uint16 protocolBps, uint16 minProtocolBps, uint16 maxProtocolBps);
    error IntegratorBpsTooHigh(uint16 integratorBps, uint16 maxIntegratorBps);
    error BpsDoNotSumToDenominator(uint256 sum);
    /// @notice `key.poolManager` is not the Bin pool manager behind this locker's position manager.
    error PoolManagerMismatch(address poolManager);
    /// @notice The pool's hook registers a burn callback, which runs on every fee collection.
    error HookInterceptsRemoval(address hook);
    error LengthMismatch(uint256 binIds, uint256 shares);
    error InvalidBinCount(uint256 count, uint16 maxBinsPerLock);
    /// @notice Bin ids must be strictly increasing; `index` is the first offender.
    error BinIdsNotStrictlyIncreasing(uint256 index);
    error ZeroShares(uint24 binId);
    /// @notice The locker's balance of a bin did not rise by exactly the declared share count.
    error SharesNotReceived(uint24 binId, uint256 expected, uint256 received);
    /// @notice The bin holds no liquidity, so its shares are worth nothing and could never earn a fee.
    error EmptyBin(uint24 binId);
    error NotLocked(uint256 lockId);
    /// @notice No bin of the lock has a fee large enough to burn at least one unit out.
    error NothingToCollect(uint256 lockId);
    error NothingToClaim();
    error NothingToSkim();
    error NotCreator(uint256 lockId, address caller);
    error NotPendingCreator(uint256 lockId, address caller);
    /// @notice Native currency may only arrive from the Vault, during a collection.
    error UnexpectedNativeSender(address sender);

    /*//////////////////////////////////////////////////////////////
                                METHODS
    //////////////////////////////////////////////////////////////*/

    function lock(PoolKey calldata key, uint24[] calldata binIds, uint256[] calldata shares, LockParams calldata p)
        external
        returns (uint256 lockId);

    function collectFees(uint256 lockId) external returns (uint256 amount0, uint256 amount1);

    function claim(Currency currency, address to) external returns (uint256 amount);

    function skim(Currency currency) external returns (uint256 surplus);

    function transferCreator(uint256 lockId, address newCreator) external;

    function acceptCreator(uint256 lockId) external;

    function getLock(uint256 lockId) external view returns (BinLock memory);

    function getPoolKey(uint256 lockId) external view returns (PoolKey memory);

    function getLockedBins(uint256 lockId)
        external
        view
        returns (uint24[] memory binIds, uint256[] memory shares, uint256[] memory principals);

    /// @notice Shares `collectFees` would burn per bin right now (aligned with `getLockedBins`), zero for
    /// skipped bins. A read, so keepers need not simulate.
    function previewCollect(uint256 lockId) external view returns (uint256[] memory sharesToBurn);

    function isLocked(uint256 lockId) external view returns (bool);

    function claimable(address account, Currency currency) external view returns (uint256);

    function pendingCreator(uint256 lockId) external view returns (address);

    function totalOwed(Currency currency) external view returns (uint256);

    function splitAmount(uint256 amount, uint16 creatorBps, uint16 integratorBps)
        external
        pure
        returns (uint256 creatorShare, uint256 integratorShare, uint256 protocolShare);

    /// @notice The fee-only burn rule for one bin, exposed for audit and fuzzing.
    /// @return burn `shares - ceil(principal * binShares / binLiquidity)` when positive and at least one
    /// currency would pay out a non-zero amount; otherwise 0.
    function harvestableShares(
        uint256 shares,
        uint256 principal,
        uint128 binReserveX,
        uint128 binReserveY,
        uint256 binLiquidity,
        uint256 binShares
    ) external pure returns (uint256 burn);
}
