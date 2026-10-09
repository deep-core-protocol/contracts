/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {DeepCoreSplit} from "./DeepCoreSplit.sol";

/// @title DeepCoreSplitFactory - "Team splits": one transaction, a split fixed forever
/// @notice Clones a `DeepCoreSplit` (EIP-1167) for anyone. The implementation is deployed here and bound to this
/// factory and to one protocol recipient forever.
///
/// TWO REVENUE LEVERS (owner decision 2026-09-19: "can we monetize this"), both on the launchpad factory's
/// rules, copied rather than re-invented so an operator who understands one understands all three:
///   * A flat CREATION FEE in native (`splitFeeWei`), pull-credited and flushed to the immutable
///     `protocolFeeRecipient` by anyone; the excess of `msg.value` is refunded in the same call.
///   * A PROTOCOL SHARE (`protocolShareBps`) of everything that later flows through a split, paid by the split
///     itself to the same recipient. The value in force at creation is written into the split and can never
///     change for that split - nothing is retroactive.
///   Both are set by the owner (the Safe; `Ownable2Step`, renounce reverts) inside immutable caps. A decrease
///   applies at once; an increase is announced and takes effect by itself `noticeSeconds` later; a new increase
///   restarts the notice; each can be cancelled.
///
/// WHAT THE OWNER CANNOT DO. There is no allowlist, pause or per-creator anything; `createSplit` has no owner
/// branch. The owner cannot reach a split (a split has no owner at all), change a split's payees, weights or
/// protocol share, or take anything but the credited creation fees - and even those only ever go to the
/// immutable recipient. Its powers are exactly: `setSplitFee` / `cancelPendingSplitFee` and
/// `setProtocolShare` / `cancelPendingProtocolShare` inside the caps, `rescueERC20` (misdirected tokens; the
/// factory never holds one by design) and `transferOwnership`.
///
/// FUNDS CAN NEVER BE STUCK. Native reaches the factory only as `createSplit`'s `msg.value` (no `receive`, no
/// `fallback`) or by `selfdestruct`; every wei is either credited or refunded in the same call, and
/// `flushProtocolFees` sends the WHOLE balance to the recipient, forced native included. A misdirected ERC-20
/// leaves through `rescueERC20`. The factory holds nothing else: a split's money is in the split.
contract DeepCoreSplitFactory is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event SplitCreated(address indexed split, address indexed creator, string name, uint16 protocolShareBps);
    /// @notice Not emitted when the fee in force was zero.
    event SplitFeePaid(address indexed split, address indexed payer, uint256 feeWei);
    event SplitFeeChanged(uint256 previousWei, uint256 newWei);
    event SplitFeeIncreaseScheduled(uint256 currentWei, uint256 newWei, uint64 effectiveAt);
    event PendingSplitFeeCancelled(uint256 cancelledWei, uint64 effectiveAt);
    event ProtocolShareChanged(uint16 previousBps, uint16 newBps);
    event ProtocolShareIncreaseScheduled(uint16 currentBps, uint16 newBps, uint64 effectiveAt);
    event PendingProtocolShareCancelled(uint16 cancelledBps, uint64 effectiveAt);
    event ProtocolFeesFlushed(address indexed to, uint256 amount, uint256 owed);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error InvalidNotice(uint32 noticeSeconds);
    error SplitFeeAboveCap(uint256 feeWei, uint256 capWei);
    error ProtocolShareAboveCap(uint16 bps, uint16 capBps);
    error InsufficientSplitFee(uint256 required, uint256 sent);
    error ProtocolShareAboveLimit(uint16 inForceBps, uint16 limitBps);
    error NoPendingChange();
    error NothingToFlush();
    error NativeTransferFailed(address to, uint256 amount);
    error RenounceDisabled();
    error NothingToRescue(address token);

    /*//////////////////////////////////////////////////////////////
                           CONSTANTS / IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    uint32 public constant MIN_FEE_NOTICE_SECONDS = 1 days;
    uint32 public constant MAX_FEE_NOTICE_SECONDS = 30 days;

    DeepCoreSplit public immutable IMPLEMENTATION;
    /// @notice The governance Safe: the only address creation fees and protocol shares are ever paid to.
    address public immutable protocolFeeRecipient;
    uint256 public immutable maxSplitFeeWei;
    /// @notice At most `DeepCoreSplit.MAX_PROTOCOL_SHARE_BPS` (5%).
    uint16 public immutable maxProtocolShareBps;
    uint32 public immutable noticeSeconds;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    // slot 0 `_owner`, slot 1 `_pendingOwner`, slot 2 `_status`
    uint256 private _splitFeeWei;
    uint256 private _pendingSplitFeeWei;
    uint64 private _pendingSplitFeeAt;
    uint16 private _protocolShareBps;
    uint16 private _pendingProtocolShareBps;
    uint64 private _pendingProtocolShareAt;
    /// @notice Creation fees credited and not yet flushed. Never more than the balance.
    uint256 public protocolFeesOwed;

    address[] private _splits;
    mapping(address => bool) public isSplit;

    /// @param owner_ The governance Safe. Fees only.
    /// @param protocolFeeRecipient_ The Safe. Immutable, here and in every split.
    /// @param initialSplitFeeWei In force from birth, `<= maxSplitFeeWei_` (zero allowed).
    /// @param maxSplitFeeWei_ Immutable cap on the creation fee.
    /// @param initialProtocolShareBps In force from birth, `<= maxProtocolShareBps_` (zero allowed).
    /// @param maxProtocolShareBps_ Immutable cap, `<= 500`.
    /// @param noticeSeconds_ Notice on increases of either, 1 to 30 days.
    constructor(
        address owner_,
        address protocolFeeRecipient_,
        uint256 initialSplitFeeWei,
        uint256 maxSplitFeeWei_,
        uint16 initialProtocolShareBps,
        uint16 maxProtocolShareBps_,
        uint32 noticeSeconds_
    ) Ownable(owner_) {
        if (protocolFeeRecipient_ == address(0)) revert ZeroAddress();
        if (noticeSeconds_ < MIN_FEE_NOTICE_SECONDS || noticeSeconds_ > MAX_FEE_NOTICE_SECONDS) {
            revert InvalidNotice(noticeSeconds_);
        }
        if (initialSplitFeeWei > maxSplitFeeWei_) revert SplitFeeAboveCap(initialSplitFeeWei, maxSplitFeeWei_);
        uint16 hardCap = 500;
        if (maxProtocolShareBps_ > hardCap) revert ProtocolShareAboveCap(maxProtocolShareBps_, hardCap);
        if (initialProtocolShareBps > maxProtocolShareBps_) {
            revert ProtocolShareAboveCap(initialProtocolShareBps, maxProtocolShareBps_);
        }
        IMPLEMENTATION = new DeepCoreSplit(address(this), protocolFeeRecipient_);
        protocolFeeRecipient = protocolFeeRecipient_;
        maxSplitFeeWei = maxSplitFeeWei_;
        maxProtocolShareBps = maxProtocolShareBps_;
        noticeSeconds = noticeSeconds_;
        _splitFeeWei = initialSplitFeeWei;
        _protocolShareBps = initialProtocolShareBps;
        emit SplitFeeChanged(0, initialSplitFeeWei);
        emit ProtocolShareChanged(0, initialProtocolShareBps);
    }

    /*//////////////////////////////////////////////////////////////
                                 CREATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Creates a split. Pays the creation fee; writes the protocol share in force into the split forever.
    /// @param name_ 1 to 64 bytes.
    /// @param payees 1 to 100 distinct, non-zero addresses.
    /// @param weights Positive, any scale (the UI uses basis points).
    /// @param labels Display names, at most 32 bytes each, emitted and not stored. Empty strings are fine.
    /// @param maxProtocolShareBps_ The highest protocol share the creator accepts. The share is frozen into the
    /// split forever, and an announced increase can take effect between a preview and the block this lands in,
    /// so the creator bounds it here, as a trader bounds slippage. (The fee needs no bound: the surplus of
    /// `msg.value` is refunded, so a creator never pays more than it sent.)
    function createSplit(
        string calldata name_,
        address[] calldata payees,
        uint96[] calldata weights,
        string[] calldata labels,
        uint16 maxProtocolShareBps_
    ) external payable nonReentrant returns (address split) {
        uint256 fee = splitFeeWei();
        if (msg.value < fee) revert InsufficientSplitFee(fee, msg.value);
        uint16 share = protocolShareBps();
        if (share > maxProtocolShareBps_) revert ProtocolShareAboveLimit(share, maxProtocolShareBps_);

        split = Clones.clone(address(IMPLEMENTATION));
        DeepCoreSplit(payable(split)).initialize(msg.sender, name_, payees, weights, labels, share);
        _splits.push(split);
        isSplit[split] = true;
        emit SplitCreated(split, msg.sender, name_, share);

        if (fee != 0) {
            protocolFeesOwed += fee;
            emit SplitFeePaid(split, msg.sender, fee);
        }
        if (msg.value > fee) _sendNative(msg.sender, msg.value - fee);
    }

    /*//////////////////////////////////////////////////////////////
                                  VIEWS
    //////////////////////////////////////////////////////////////*/

    function splitCount() external view returns (uint256) {
        return _splits.length;
    }

    function splitAt(uint256 index) external view returns (address) {
        return _splits[index];
    }

    /// @notice A page of splits, creation order. `end` is exclusive and clamped.
    function splits(uint256 start, uint256 end) external view returns (address[] memory page) {
        uint256 length = _splits.length;
        if (end > length) end = length;
        if (start >= end) return page;
        page = new address[](end - start);
        for (uint256 i = start; i < end; ++i) {
            page[i - start] = _splits[i];
        }
    }

    /// @notice The creation fee a `createSplit` in THIS block pays.
    function splitFeeWei() public view returns (uint256) {
        uint64 at = _pendingSplitFeeAt;
        if (at != 0 && block.timestamp >= at) return _pendingSplitFeeWei;
        return _splitFeeWei;
    }

    /// @notice The protocol share a split created in THIS block is born with.
    function protocolShareBps() public view returns (uint16) {
        uint64 at = _pendingProtocolShareAt;
        if (at != 0 && block.timestamp >= at) return _pendingProtocolShareBps;
        return _protocolShareBps;
    }

    /// @notice An announced fee increase not yet in force. `(0, 0)` when there is none.
    function pendingSplitFee() external view returns (uint256 feeWei, uint64 effectiveAt) {
        effectiveAt = _pendingSplitFeeAt;
        if (effectiveAt == 0 || block.timestamp >= effectiveAt) return (0, 0);
        feeWei = _pendingSplitFeeWei;
    }

    /// @notice An announced protocol-share increase not yet in force. `(0, 0)` when there is none.
    function pendingProtocolShare() external view returns (uint16 bps, uint64 effectiveAt) {
        effectiveAt = _pendingProtocolShareAt;
        if (effectiveAt == 0 || block.timestamp >= effectiveAt) return (0, 0);
        bps = _pendingProtocolShareBps;
    }

    /*//////////////////////////////////////////////////////////////
                                  OWNER
    //////////////////////////////////////////////////////////////*/

    /// @notice `<=` the fee in force applies now and cancels a pending increase; `>` is announced and applies
    /// `noticeSeconds` later by itself. A new increase replaces a pending one and restarts the notice.
    function setSplitFee(uint256 newFeeWei) external onlyOwner {
        if (newFeeWei > maxSplitFeeWei) revert SplitFeeAboveCap(newFeeWei, maxSplitFeeWei);
        _materialiseFee();
        uint256 current = _splitFeeWei;
        if (newFeeWei <= current) {
            _clearPendingFee();
            _splitFeeWei = newFeeWei;
            emit SplitFeeChanged(current, newFeeWei);
        } else {
            uint64 at = uint64(block.timestamp) + noticeSeconds;
            _pendingSplitFeeWei = newFeeWei;
            _pendingSplitFeeAt = at;
            emit SplitFeeIncreaseScheduled(current, newFeeWei, at);
        }
    }

    function cancelPendingSplitFee() external onlyOwner {
        _materialiseFee();
        if (_pendingSplitFeeAt == 0) revert NoPendingChange();
        _clearPendingFee();
    }

    /// @notice Same rules as `setSplitFee`. Affects splits created afterwards only.
    function setProtocolShare(uint16 newBps) external onlyOwner {
        if (newBps > maxProtocolShareBps) revert ProtocolShareAboveCap(newBps, maxProtocolShareBps);
        _materialiseShare();
        uint16 current = _protocolShareBps;
        if (newBps <= current) {
            _clearPendingShare();
            _protocolShareBps = newBps;
            emit ProtocolShareChanged(current, newBps);
        } else {
            uint64 at = uint64(block.timestamp) + noticeSeconds;
            _pendingProtocolShareBps = newBps;
            _pendingProtocolShareAt = at;
            emit ProtocolShareIncreaseScheduled(current, newBps, at);
        }
    }

    function cancelPendingProtocolShare() external onlyOwner {
        _materialiseShare();
        if (_pendingProtocolShareAt == 0) revert NoPendingChange();
        _clearPendingShare();
    }

    /// @notice Disabled. An owner that could renounce would freeze both levers where they stand forever.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Move an ERC-20 sent to the factory by mistake. The factory never holds a token by design.
    function rescueERC20(address token, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToRescue(token);
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    /// @notice Permissionless: the factory's whole native balance to the immutable recipient.
    function flushProtocolFees() external nonReentrant returns (uint256 amount) {
        amount = address(this).balance;
        if (amount == 0) revert NothingToFlush();
        uint256 owed = protocolFeesOwed;
        protocolFeesOwed = 0;
        emit ProtocolFeesFlushed(protocolFeeRecipient, amount, owed);
        _sendNative(protocolFeeRecipient, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _materialiseFee() private {
        uint64 at = _pendingSplitFeeAt;
        if (at != 0 && block.timestamp >= at) {
            uint256 next = _pendingSplitFeeWei;
            emit SplitFeeChanged(_splitFeeWei, next);
            _splitFeeWei = next;
            _pendingSplitFeeWei = 0;
            _pendingSplitFeeAt = 0;
        }
    }

    function _clearPendingFee() private {
        uint64 at = _pendingSplitFeeAt;
        if (at == 0) return;
        emit PendingSplitFeeCancelled(_pendingSplitFeeWei, at);
        _pendingSplitFeeWei = 0;
        _pendingSplitFeeAt = 0;
    }

    function _materialiseShare() private {
        uint64 at = _pendingProtocolShareAt;
        if (at != 0 && block.timestamp >= at) {
            uint16 next = _pendingProtocolShareBps;
            emit ProtocolShareChanged(_protocolShareBps, next);
            _protocolShareBps = next;
            _pendingProtocolShareBps = 0;
            _pendingProtocolShareAt = 0;
        }
    }

    function _clearPendingShare() private {
        uint64 at = _pendingProtocolShareAt;
        if (at == 0) return;
        emit PendingProtocolShareCancelled(_pendingProtocolShareBps, at);
        _pendingProtocolShareBps = 0;
        _pendingProtocolShareAt = 0;
    }

    function _sendNative(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed(to, amount);
    }
}
