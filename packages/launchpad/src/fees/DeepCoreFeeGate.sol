/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @title DeepCoreFeeGate - the flat protocol fee every DeepCore utility charges, in one place
/// @notice The launchpad factory's site-fee mechanism, extracted so every utility that charges it (the
/// lockers, the multisend, the Merkle drop factory) behaves identically and an operator who understands one
/// understands all of them:
///   * `feeWei()` is what an action in THIS block pays, in native. `_takeFee(msg.value)` reverts below it,
///     credits the fee to `protocolFeesOwed` and returns the SURPLUS for the caller to refund last.
///   * The owner (the governance Safe; `Ownable2Step`, `renounceOwnership` reverts) may set it inside the
///     immutable `maxFeeWei`. A decrease applies at once; an increase is announced and takes effect by itself
///     `feeNoticeSeconds` later; a new increase restarts the notice; `cancelPendingFee` withdraws it. Nothing
///     is retroactive.
///   * `flushProtocolFees` is permissionless and pays the WHOLE native balance above `_nativeHeldForUsers()` to
///     the immutable `protocolFeeRecipient` (a child that custodies native for users says how much of its
///     balance is theirs; everything else, forced native included, is fee).
///   * The contract stores wei. A dollar figure is converted off chain when the Safe sets it.
///
/// Why a contract and not the SDK: revenue is enforced where the value moves (CLAUDE.md, "Kit fees"). A
/// developer who calls these contracts through the MIT SDK, their own code or a block explorer pays the same
/// fee; only a fork that deploys its own contracts pays nothing, which the GPL permits.
abstract contract DeepCoreFeeGate is Ownable2Step, ReentrancyGuard {
    event FeeChanged(uint256 previousWei, uint256 newWei);
    event FeeIncreaseScheduled(uint256 currentWei, uint256 newWei, uint64 effectiveAt);
    event PendingFeeCancelled(uint256 cancelledWei, uint64 effectiveAt);
    event FeePaid(address indexed payer, uint256 feeWei);
    event ProtocolFeesFlushed(address indexed to, uint256 amount, uint256 owed);

    error ZeroAddress();
    error InvalidNotice(uint32 noticeSeconds);
    error FeeAboveCap(uint256 feeWei, uint256 capWei);
    error InsufficientFee(uint256 required, uint256 sent);
    error NoPendingFee();
    error NothingToFlush();
    error NativeTransferFailed(address to, uint256 amount);
    error RenounceDisabled();

    /// @notice Floor on the public notice an INCREASE must sit behind. Decreases are immediate,
    /// because delay never sits on a reduction of the owner's power.
    ///
    /// CLOCK. This is measured on `block.timestamp`, which on an Arbitrum Nitro chain the sequencer
    /// may set up to roughly 1 hour ahead of real time. So a scheduled increase can become
    /// applicable about an hour early — ~4% of this one-day floor. It is recorded rather than
    /// defended against: only the owner (the governance Safe) can schedule an increase at all, the
    /// amount is still bounded by the immutable cap, and nothing retroactive follows from it. The
    /// launch guards carry the same note; it was missing here, which is finding L-2 of the
    /// 2026-09-18 review.
    uint32 public constant MIN_FEE_NOTICE_SECONDS = 1 days;
    uint32 public constant MAX_FEE_NOTICE_SECONDS = 30 days;

    /// @notice The governance Safe. The only address fees are ever paid to.
    address public immutable protocolFeeRecipient;
    /// @notice The owner can never set a fee above this.
    uint256 public immutable maxFeeWei;
    /// @notice How long an announced increase waits before it is the fee.
    uint32 public immutable feeNoticeSeconds;

    uint256 private _feeWei;
    uint256 private _pendingFeeWei;
    uint64 private _pendingFeeAt;
    /// @notice Fees credited and not yet flushed.
    uint256 public protocolFeesOwed;

    constructor(address owner_, address protocolFeeRecipient_, uint256 initialFeeWei, uint256 maxFeeWei_, uint32 noticeSeconds_)
        Ownable(owner_)
    {
        if (protocolFeeRecipient_ == address(0)) revert ZeroAddress();
        if (noticeSeconds_ < MIN_FEE_NOTICE_SECONDS || noticeSeconds_ > MAX_FEE_NOTICE_SECONDS) {
            revert InvalidNotice(noticeSeconds_);
        }
        if (initialFeeWei > maxFeeWei_) revert FeeAboveCap(initialFeeWei, maxFeeWei_);
        protocolFeeRecipient = protocolFeeRecipient_;
        maxFeeWei = maxFeeWei_;
        feeNoticeSeconds = noticeSeconds_;
        _feeWei = initialFeeWei;
        emit FeeChanged(0, initialFeeWei);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The fee an action in THIS block pays.
    function feeWei() public view returns (uint256) {
        uint64 at = _pendingFeeAt;
        if (at != 0 && block.timestamp >= at) return _pendingFeeWei;
        return _feeWei;
    }

    /// @notice An announced increase not yet in force. `(0, 0)` when there is none.
    function pendingFee() external view returns (uint256 newFeeWei, uint64 effectiveAt) {
        effectiveAt = _pendingFeeAt;
        if (effectiveAt == 0 || block.timestamp >= effectiveAt) return (0, 0);
        newFeeWei = _pendingFeeWei;
    }

    /*//////////////////////////////////////////////////////////////
                                 OWNER
    //////////////////////////////////////////////////////////////*/

    /// @notice `<=` the fee in force applies now and cancels a pending increase; `>` is announced and applies
    /// `feeNoticeSeconds` later by itself. A new increase replaces a pending one and restarts the notice.
    function setFee(uint256 newFeeWei) external onlyOwner {
        if (newFeeWei > maxFeeWei) revert FeeAboveCap(newFeeWei, maxFeeWei);
        _materialise();
        uint256 current = _feeWei;
        if (newFeeWei <= current) {
            _clearPending();
            _feeWei = newFeeWei;
            emit FeeChanged(current, newFeeWei);
        } else {
            uint64 at = uint64(block.timestamp) + feeNoticeSeconds;
            _pendingFeeWei = newFeeWei;
            _pendingFeeAt = at;
            emit FeeIncreaseScheduled(current, newFeeWei, at);
        }
    }

    function cancelPendingFee() external onlyOwner {
        _materialise();
        if (_pendingFeeAt == 0) revert NoPendingFee();
        _clearPending();
    }

    /// @notice Disabled. An owner that could renounce would freeze the fee where it stands forever.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /*//////////////////////////////////////////////////////////////
                                 FLUSH
    //////////////////////////////////////////////////////////////*/

    /// @notice Permissionless: every native unit that is not held for users goes to the immutable recipient.
    /// Shares the child's `nonReentrant` guard: a recipient cannot re-enter any guarded function.
    function flushProtocolFees() external nonReentrant returns (uint256 amount) {
        uint256 balance = address(this).balance;
        uint256 held = _nativeHeldForUsers();
        amount = balance > held ? balance - held : 0;
        if (amount == 0) revert NothingToFlush();
        uint256 owed = protocolFeesOwed;
        protocolFeesOwed = 0;
        emit ProtocolFeesFlushed(protocolFeeRecipient, amount, owed);
        _sendNative(protocolFeeRecipient, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    /// @dev Charges the fee in force out of `value` (the caller's `msg.value` share meant for the fee) and
    /// returns the surplus, which the caller refunds LAST, after its own effects and interactions.
    function _takeFee(uint256 value) internal returns (uint256 surplus) {
        uint256 fee = feeWei();
        if (value < fee) revert InsufficientFee(fee, value);
        if (fee != 0) {
            protocolFeesOwed += fee;
            emit FeePaid(msg.sender, fee);
        }
        return value - fee;
    }

    /// @dev The part of this contract's native balance that belongs to users (e.g. native in a lock or a
    /// drop). The default is none. Must never exceed the balance.
    function _nativeHeldForUsers() internal view virtual returns (uint256) {
        return 0;
    }

    function _sendNative(address to, uint256 amount) internal {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed(to, amount);
    }

    function _materialise() private {
        uint64 at = _pendingFeeAt;
        if (at != 0 && block.timestamp >= at) {
            uint256 next = _pendingFeeWei;
            emit FeeChanged(_feeWei, next);
            _feeWei = next;
            _pendingFeeWei = 0;
            _pendingFeeAt = 0;
        }
    }

    function _clearPending() private {
        uint64 at = _pendingFeeAt;
        if (at == 0) return;
        emit PendingFeeCancelled(_pendingFeeWei, at);
        _pendingFeeWei = 0;
        _pendingFeeAt = 0;
    }
}
