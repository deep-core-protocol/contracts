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
import {Currency} from "infinity-core/src/types/Currency.sol";

/// @notice What the sender of a position declares when it hands the position to the locker.
/// @dev Travels as `abi.encode(LockParams)` in the `data` argument of
/// `CLPositionManager.safeTransferFrom(from, locker, tokenId, data)`. That is the ONLY way a lock is
/// created, so the only party who can choose these values is the account that owned (or was approved
/// for) the position a moment earlier.
struct LockParams {
    /// @dev Receives `creatorBps` of every collection. Non-zero. Rotatable, two-step, by itself only.
    address creator;
    uint16 creatorBps;
    /// @dev The tenant's fee wallet, or `address(0)` when `integratorBps == 0`. Fixed for the life of
    /// the lock: point it at a Safe, whose signers can rotate without the address changing.
    address integrator;
    /// @dev At most the deployment's immutable `maxIntegratorBps`.
    uint16 integratorBps;
    /// @dev Share for the locker's immutable `protocolRecipient`. Must lie inside the deployment's
    /// immutable [`minProtocolBps`, `maxProtocolBps`].
    uint16 protocolBps;
}

/// @notice One permanent lock. Written once in `onERC721Received`; only `creator` can ever change.
/// @dev Packing: slot 0 = creator|creatorBps|integratorBps|protocolBps|lockedAt (32 bytes),
/// slot 1 = integrator, slot 2 = currency0, slot 3 = currency1, slot 4 = poolId.
struct Lock {
    address creator;
    uint16 creatorBps;
    uint16 integratorBps;
    uint16 protocolBps;
    /// @dev `block.timestamp`, never `block.number`: on Arbitrum Nitro chains such as Robinhood (4663)
    /// the EVM's `block.number` is Ethereum L1's, so a block-stamped record means nothing locally.
    uint48 lockedAt;
    address integrator;
    Currency currency0;
    Currency currency1;
    PoolId poolId;
}

/// @title IDeepCoreLPLocker
/// @notice Events, errors and methods of the permanent CL-position locker.
interface IDeepCoreLPLocker {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @param from The previous owner of the position (the account the NFT was transferred from).
    /// @param operator The account that called `safeTransferFrom` (the owner or an approved operator).
    event PositionLocked(
        uint256 indexed tokenId,
        PoolId indexed poolId,
        address indexed creator,
        address integrator,
        uint16 creatorBps,
        uint16 integratorBps,
        uint16 protocolBps,
        uint128 liquidity,
        address from,
        address operator
    );

    /// @notice One currency's worth of fees pulled out of a locked position and credited.
    /// @dev `amount` is the balance the locker actually GAINED, not what the position manager was
    /// asked to send. `creatorShare + integratorShare + protocolShare == amount` exactly; rounding
    /// dust is inside `protocolShare`.
    event FeesCollected(
        uint256 indexed tokenId,
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
    event CreatorTransferStarted(uint256 indexed tokenId, address indexed creator, address indexed pending);
    event CreatorTransferred(uint256 indexed tokenId, address indexed previousCreator, address indexed newCreator);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error InvalidBpsBounds(uint16 minProtocolBps, uint16 maxProtocolBps, uint16 maxIntegratorBps);
    error ProtocolRecipientIsLocker();
    error PositionManagerHasNoVault();
    /// @notice `onERC721Received` was called by something other than the position manager.
    error NotPositionManager(address caller);
    /// @notice The `data` sent with the position is not exactly one ABI-encoded `LockParams`.
    error InvalidLockData(uint256 length);
    error InvalidCreator(address creator);
    /// @notice `integrator` must be non-zero iff `integratorBps` is non-zero, and never the locker.
    error InvalidIntegrator(address integrator, uint16 integratorBps);
    error ProtocolBpsOutOfRange(uint16 protocolBps, uint16 minProtocolBps, uint16 maxProtocolBps);
    error IntegratorBpsTooHigh(uint16 integratorBps, uint16 maxIntegratorBps);
    error BpsDoNotSumToDenominator(uint256 sum);
    /// @notice A position with zero liquidity earns nothing and cannot even be poked for fees.
    error EmptyPosition(uint256 tokenId);
    error AlreadyLocked(uint256 tokenId);
    /// @notice The locker does not own the position it is being asked to record. Unreachable through
    /// the real position manager; kept as a defence against a non-standard one.
    error NotOwnedByLocker(uint256 tokenId);
    error SubscriberAttached(uint256 tokenId, address subscriber);
    /// @notice The pool's hook registers a remove-liquidity callback, which runs on every fee collection.
    error HookInterceptsRemoval(uint256 tokenId, address hook);
    error NotLocked(uint256 tokenId);
    error NothingToClaim();
    error NothingToSkim();
    error NotCreator(uint256 tokenId, address caller);
    error NotPendingCreator(uint256 tokenId, address caller);
    /// @notice Native currency may only arrive from the Vault, during a collection.
    error UnexpectedNativeSender(address sender);

    /*//////////////////////////////////////////////////////////////
                                METHODS
    //////////////////////////////////////////////////////////////*/

    function collectFees(uint256 tokenId) external returns (uint256 amount0, uint256 amount1);

    function claim(Currency currency, address to) external returns (uint256 amount);

    function skim(Currency currency) external returns (uint256 surplus);

    function transferCreator(uint256 tokenId, address newCreator) external;

    function acceptCreator(uint256 tokenId) external;

    function getLock(uint256 tokenId) external view returns (Lock memory);

    function isLocked(uint256 tokenId) external view returns (bool);

    function claimable(address account, Currency currency) external view returns (uint256);

    function pendingCreator(uint256 tokenId) external view returns (address);

    function totalOwed(Currency currency) external view returns (uint256);

    function splitAmount(uint256 amount, uint16 creatorBps, uint16 integratorBps)
        external
        pure
        returns (uint256 creatorShare, uint256 integratorShare, uint256 protocolShare);
}
