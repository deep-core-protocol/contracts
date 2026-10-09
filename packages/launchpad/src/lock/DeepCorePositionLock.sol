/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";

import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";

import {DeepCoreFeeGate} from "../fees/DeepCoreFeeGate.sol";

/// @title DeepCorePositionLock - time-lock any DeepCore CL liquidity position, keep earning its fees
/// @notice The trust badge for a DeepCore launchpad or DEX: "this liquidity cannot be pulled before <date>".
/// Anyone locks a `CLPositionManager` position NFT they own until a date they choose; until then nobody - not
/// the lock owner, not the Safe, not this contract - can remove a unit of its liquidity or move the NFT. The
/// lock owner keeps every swap fee: `collectFees` sends them straight to the lock owner. After the date the
/// lock owner withdraws the NFT, whole. A lock can be extended, never shortened.
///
/// THE NO-EARLY-WITHDRAW GUARANTEE is structural, on the same `CLPositionManager` facts `DeepCoreLPLocker`
/// documents: only the NFT's owner or an approved spender can decrease, burn, transfer or subscribe it, and
/// this contract (the owner while locked) makes exactly two calls to the position manager:
///   1. `modifyLiquidities` with a plan built from literals: `CL_DECREASE_LIQUIDITY(id, 0, 0, 0, "")` then
///      `TAKE_PAIR(c0, c1, lockOwner)`. A zero-liquidity decrease only realises accrued fees.
///   2. `transferFrom(this, to, id)` inside `withdraw`, only after `unlockAt`, only for the lock owner.
/// It never calls `approve`, `setApprovalForAll`, `burn` or `subscribe`, has no generic call path and does not
/// implement ERC-1271, so no `permit` signature can ever be valid for it.
///
/// OWNERSHIP AND FEES. The contract owner (the governance Safe) controls the flat lock fee (`DeepCoreFeeGate`)
/// and can rescue what was sent here WITHOUT a lock (a plain ERC-721 `transferFrom`, an ERC-20); it cannot
/// touch a locked position, shorten a lock or change a lock owner. The lock owner rotates two-step.
///
/// FUNDS CAN NEVER BE STUCK. Value in: a position NFT through `lock` (leaves through `withdraw`), the fee in
/// native (leaves through the permissionless `flushProtocolFees`, forced native too). A position sent with a
/// plain `transferFrom` has no lock record and leaves through the owner's `rescuePosition`; `safeTransferFrom`
/// reverts (no receiver hook). Fees never rest here: TAKE_PAIR pays the lock owner. An ERC-20 sent by mistake
/// leaves through `rescueERC20`.
///
/// NOT COVERED. CL positions only (Bin shares have no NFT and are a separate contract). A pool whose hook runs
/// on liquidity removal can block or skim fee collection; that affects fees, never the principal's lock.
contract DeepCorePositionLock is DeepCoreFeeGate {
    using PoolIdLibrary for PoolKey;
    using SafeERC20 for IERC20;

    struct PositionLock {
        address owner;
        uint48 lockedAt;
        uint48 unlockAt;
        address pendingOwner;
        PoolId poolId;
        Currency currency0;
        Currency currency1;
        bool withdrawn;
    }

    event PositionLocked(
        uint256 indexed tokenId, PoolId indexed poolId, address indexed owner, uint48 unlockAt, uint128 liquidity, address locker
    );
    event LockExtended(uint256 indexed tokenId, uint48 previousUnlockAt, uint48 newUnlockAt);
    event FeesCollected(uint256 indexed tokenId, address indexed to);
    event PositionWithdrawn(uint256 indexed tokenId, address indexed to);
    event LockOwnerTransferStarted(uint256 indexed tokenId, address indexed owner, address indexed newOwner);
    event LockOwnerTransferred(uint256 indexed tokenId, address indexed previousOwner, address indexed newOwner);
    event PositionRescued(uint256 indexed tokenId, address indexed to);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    error NotPositionOwner(uint256 tokenId, address caller);
    error InvalidUnlock(uint48 unlockAt);
    error InvalidOwner(address owner);
    error EmptyPosition(uint256 tokenId);
    error AlreadyLocked(uint256 tokenId);
    error NotLocked(uint256 tokenId);
    error NotLockOwner(uint256 tokenId, address caller);
    error NotPendingOwner(uint256 tokenId, address caller);
    error StillLocked(uint256 tokenId, uint48 unlockAt);
    error NotLater(uint48 current, uint48 proposed);
    error PositionIsLocked(uint256 tokenId);
    error NothingToRescue(address token);

    /// @notice The longest lock accepted, from now. A guard against a typo locking a position for ever.
    uint256 public constant MAX_LOCK_SECONDS = 100 * 365 days;

    ICLPositionManager public immutable positionManager;

    mapping(uint256 => PositionLock) private _locks;
    uint256[] private _lockIds;
    mapping(PoolId => uint256[]) private _lockIdsByPool;

    constructor(
        ICLPositionManager positionManager_,
        address owner_,
        address protocolFeeRecipient_,
        uint256 initialFeeWei,
        uint256 maxFeeWei_,
        uint32 noticeSeconds_
    ) DeepCoreFeeGate(owner_, protocolFeeRecipient_, initialFeeWei, maxFeeWei_, noticeSeconds_) {
        if (address(positionManager_) == address(0)) revert ZeroAddress();
        positionManager = positionManager_;
    }

    /*//////////////////////////////////////////////////////////////
                                  LOCK
    //////////////////////////////////////////////////////////////*/

    /// @notice Lock a position the caller owns until `unlockAt`, for `owner` (who collects fees and later
    /// withdraws). Pays the flat fee; the surplus of `msg.value` is refunded. The caller must first
    /// `approve` this contract for the NFT (or `setApprovalForAll`).
    function lock(uint256 tokenId, uint48 unlockAt, address owner) external payable nonReentrant {
        if (owner == address(0) || owner == address(this)) revert InvalidOwner(owner);
        if (unlockAt <= block.timestamp || unlockAt > block.timestamp + MAX_LOCK_SECONDS) revert InvalidUnlock(unlockAt);
        if (IERC721(address(positionManager)).ownerOf(tokenId) != msg.sender) revert NotPositionOwner(tokenId, msg.sender);
        PositionLock storage existing = _locks[tokenId];
        if (existing.owner != address(0) && !existing.withdrawn) revert AlreadyLocked(tokenId);

        (PoolKey memory key,,, uint128 liquidity,,,) = positionManager.positions(tokenId);
        if (liquidity == 0) revert EmptyPosition(tokenId);
        PoolId poolId = key.toId();

        uint256 surplus = _takeFee(msg.value);

        bool first = existing.owner == address(0);
        _locks[tokenId] = PositionLock({
            owner: owner,
            lockedAt: uint48(block.timestamp),
            unlockAt: unlockAt,
            pendingOwner: address(0),
            poolId: poolId,
            currency0: key.currency0,
            currency1: key.currency1,
            withdrawn: false
        });
        if (first) {
            _lockIds.push(tokenId);
            _lockIdsByPool[poolId].push(tokenId);
        }
        emit PositionLocked(tokenId, poolId, owner, unlockAt, liquidity, msg.sender);

        // Plain transferFrom: no receiver callback, and it clears any approval and subscriber on the way in.
        IERC721(address(positionManager)).transferFrom(msg.sender, address(this), tokenId);
        if (surplus != 0) _sendNative(msg.sender, surplus);
    }

    /// @notice Move `unlockAt` later. Never earlier.
    function extend(uint256 tokenId, uint48 newUnlockAt) external nonReentrant {
        PositionLock storage l = _live(tokenId);
        if (msg.sender != l.owner) revert NotLockOwner(tokenId, msg.sender);
        if (newUnlockAt <= l.unlockAt) revert NotLater(l.unlockAt, newUnlockAt);
        if (newUnlockAt > block.timestamp + MAX_LOCK_SECONDS) revert InvalidUnlock(newUnlockAt);
        emit LockExtended(tokenId, l.unlockAt, newUnlockAt);
        l.unlockAt = newUnlockAt;
    }

    /// @notice Realise a locked position's accrued fees and send them to its lock owner. Permissionless: the
    /// money can only go to the lock owner.
    function collectFees(uint256 tokenId) external nonReentrant {
        PositionLock storage l = _live(tokenId);
        address to = l.owner;
        Plan memory plan = Planner.init();
        // The liquidity argument is the literal 0: this line is the whole of the fee path.
        plan.add(Actions.CL_DECREASE_LIQUIDITY, abi.encode(tokenId, uint256(0), uint128(0), uint128(0), bytes("")));
        plan.add(Actions.TAKE_PAIR, abi.encode(l.currency0, l.currency1, to));
        emit FeesCollected(tokenId, to);
        positionManager.modifyLiquidities(plan.encode(), block.timestamp);
    }

    /// @notice After `unlockAt`, the lock owner takes the position back, to `to`.
    function withdraw(uint256 tokenId, address to) external nonReentrant {
        PositionLock storage l = _live(tokenId);
        if (msg.sender != l.owner) revert NotLockOwner(tokenId, msg.sender);
        if (block.timestamp < l.unlockAt) revert StillLocked(tokenId, l.unlockAt);
        if (to == address(0)) revert ZeroAddress();
        l.withdrawn = true;
        l.pendingOwner = address(0);
        emit PositionWithdrawn(tokenId, to);
        IERC721(address(positionManager)).transferFrom(address(this), to, tokenId);
    }

    /// @notice Offer the lock (fees and the eventual withdrawal) to `newOwner`, who must accept. Zero withdraws.
    function transferLockOwner(uint256 tokenId, address newOwner) external nonReentrant {
        PositionLock storage l = _live(tokenId);
        if (msg.sender != l.owner) revert NotLockOwner(tokenId, msg.sender);
        if (newOwner == address(this)) revert InvalidOwner(newOwner);
        l.pendingOwner = newOwner;
        emit LockOwnerTransferStarted(tokenId, msg.sender, newOwner);
    }

    function acceptLockOwner(uint256 tokenId) external nonReentrant {
        PositionLock storage l = _live(tokenId);
        if (msg.sender == address(0) || msg.sender != l.pendingOwner) revert NotPendingOwner(tokenId, msg.sender);
        emit LockOwnerTransferred(tokenId, l.owner, msg.sender);
        l.owner = msg.sender;
        l.pendingOwner = address(0);
    }

    /*//////////////////////////////////////////////////////////////
                          OWNER (THE SAFE) - RESCUE
    //////////////////////////////////////////////////////////////*/

    /// @notice A position NFT sent here with a plain `transferFrom` (no lock) goes back out. Refuses any
    /// position with a live lock.
    function rescuePosition(uint256 tokenId, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        PositionLock storage l = _locks[tokenId];
        if (l.owner != address(0) && !l.withdrawn) revert PositionIsLocked(tokenId);
        emit PositionRescued(tokenId, to);
        IERC721(address(positionManager)).transferFrom(address(this), to, tokenId);
    }

    /// @notice An ERC-20 sent here by mistake. The contract never holds one by design (fees are paid out).
    function rescueERC20(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToRescue(token);
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function getLock(uint256 tokenId) external view returns (PositionLock memory) {
        return _locks[tokenId];
    }

    /// @notice Locked right now: recorded, not withdrawn, and still held (a withdrawn lock reads false).
    function isLocked(uint256 tokenId) external view returns (bool) {
        PositionLock storage l = _locks[tokenId];
        return l.owner != address(0) && !l.withdrawn && block.timestamp < l.unlockAt;
    }

    function lockCount() external view returns (uint256) {
        return _lockIds.length;
    }

    /// @notice Every position ever locked here, in lock order. `end` is exclusive and clamped.
    function lockIds(uint256 start, uint256 end) external view returns (uint256[] memory page) {
        return _page(_lockIds, start, end);
    }

    function poolLockCount(PoolId poolId) external view returns (uint256) {
        return _lockIdsByPool[poolId].length;
    }

    /// @notice Every position ever locked in `poolId`. The explorer's per-pool list.
    function poolLockIds(PoolId poolId, uint256 start, uint256 end) external view returns (uint256[] memory page) {
        return _page(_lockIdsByPool[poolId], start, end);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _live(uint256 tokenId) private view returns (PositionLock storage l) {
        l = _locks[tokenId];
        if (l.owner == address(0) || l.withdrawn) revert NotLocked(tokenId);
    }

    function _page(uint256[] storage list, uint256 start, uint256 end) private view returns (uint256[] memory page) {
        uint256 length = list.length;
        if (end > length) end = length;
        if (start >= end) return page;
        page = new uint256[](end - start);
        for (uint256 i = start; i < end; ++i) {
            page[i - start] = list[i];
        }
    }
}
