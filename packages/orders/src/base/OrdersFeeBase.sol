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
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";

/// @title OrdersFeeBase - the bps protocol fee, the integrator credit and the solvency ledger shared by
/// `DeepCoreRangeOrders` and `DeepCoreDCA`
/// @notice House fee pattern (CLAUDE.md, "Kit fees"):
///   * `protocolFeeBps()` is the fee a NEW order or plan freezes into itself. Nothing already placed
///     is ever re-priced.
///   * The owner (the governance Safe; `Ownable2Step`, `renounceOwnership` reverts) sets it inside the
///     immutable `maxProtocolFeeBps`, which is itself at most `ABSOLUTE_MAX_PROTOCOL_FEE_BPS`. A decrease
///     applies at once; an increase is announced and applies by itself `feeNoticeSeconds` later.
///   * Fees are credited per currency and paid ONLY to the immutable `protocolFeeRecipient` through the
///     permissionless `flushProtocolFees`.
///   * An integrator (the hosted site that created an order) earns its own bps, at most
///     `MAX_INTEGRATOR_BPS`, chosen per order and frozen with it. It is credited and pulled by the
///     integrator itself.
///   * `totalOwed[currency]` is every unit this contract holds for somebody. `rescueSurplus` (owner) can
///     reach only `balance - totalOwed`: misdirected tokens and forced native, never user value.
abstract contract OrdersFeeBase is Ownable2Step, ReentrancyGuard {
    using CurrencyLibrary for Currency;

    event ProtocolFeeChanged(uint16 previousBps, uint16 newBps);
    event ProtocolFeeIncreaseScheduled(uint16 currentBps, uint16 newBps, uint64 effectiveAt);
    event PendingProtocolFeeCancelled(uint16 cancelledBps, uint64 effectiveAt);
    event ProtocolFeesFlushed(Currency indexed currency, address indexed to, uint256 amount);
    event IntegratorFeesClaimed(address indexed integrator, Currency indexed currency, address to, uint256 amount);
    event SurplusRescued(Currency indexed currency, address indexed to, uint256 amount);

    error ZeroAddress();
    error InvalidNotice(uint32 noticeSeconds);
    error FeeAboveCap(uint256 feeBps, uint256 capBps);
    error NoPendingFee();
    error NothingToFlush();
    error NothingToClaim();
    error NothingToRescue();
    error IntegratorBpsAboveCap(uint16 bps);
    error IntegratorMissing();
    error RenounceDisabled();

    uint16 internal constant BPS = 10_000;
    /// @notice Compile-time ceiling above the immutable cap.
    uint16 public constant ABSOLUTE_MAX_PROTOCOL_FEE_BPS = 50;
    /// @notice An integrator's own share, on top of the protocol fee, frozen per order.
    uint16 public constant MAX_INTEGRATOR_BPS = 10;
    /// @notice Floor on the notice an increase sits behind. Measured on `block.timestamp`; a sequencer may
    /// run it slightly ahead (CLAUDE.md, L-2). Only the owner can schedule, inside the immutable cap.
    uint32 public constant MIN_FEE_NOTICE_SECONDS = 1 days;
    uint32 public constant MAX_FEE_NOTICE_SECONDS = 30 days;

    /// @notice The governance Safe. The only address protocol fees are ever paid to.
    address public immutable protocolFeeRecipient;
    uint16 public immutable maxProtocolFeeBps;
    uint32 public immutable feeNoticeSeconds;

    uint16 private _feeBps;
    uint16 private _pendingFeeBps;
    uint64 private _pendingFeeAt;

    /// @notice Every unit held for somebody, per currency: user escrow, proceeds, integrator and protocol credit.
    mapping(Currency => uint256) public totalOwed;
    /// @notice Protocol fees credited and not yet flushed.
    mapping(Currency => uint256) public protocolOwed;
    /// @notice Integrator credit, pulled by the integrator.
    mapping(address => mapping(Currency => uint256)) public integratorOwed;

    constructor(address owner_, address recipient_, uint16 initialFeeBps, uint16 maxFeeBps_, uint32 noticeSeconds_)
        Ownable(owner_)
    {
        if (recipient_ == address(0)) revert ZeroAddress();
        if (noticeSeconds_ < MIN_FEE_NOTICE_SECONDS || noticeSeconds_ > MAX_FEE_NOTICE_SECONDS) {
            revert InvalidNotice(noticeSeconds_);
        }
        if (maxFeeBps_ > ABSOLUTE_MAX_PROTOCOL_FEE_BPS) revert FeeAboveCap(maxFeeBps_, ABSOLUTE_MAX_PROTOCOL_FEE_BPS);
        if (initialFeeBps > maxFeeBps_) revert FeeAboveCap(initialFeeBps, maxFeeBps_);
        protocolFeeRecipient = recipient_;
        maxProtocolFeeBps = maxFeeBps_;
        feeNoticeSeconds = noticeSeconds_;
        _feeBps = initialFeeBps;
        emit ProtocolFeeChanged(0, initialFeeBps);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice The fee an order or plan created in THIS block freezes into itself.
    function protocolFeeBps() public view returns (uint16) {
        uint64 at = _pendingFeeAt;
        if (at != 0 && block.timestamp >= at) return _pendingFeeBps;
        return _feeBps;
    }

    /// @notice An announced increase not yet in force; `(0, 0)` when there is none.
    function pendingProtocolFee() external view returns (uint16 newFeeBps, uint64 effectiveAt) {
        effectiveAt = _pendingFeeAt;
        if (effectiveAt == 0 || block.timestamp >= effectiveAt) return (0, 0);
        newFeeBps = _pendingFeeBps;
    }

    /*//////////////////////////////////////////////////////////////
                                 OWNER
    //////////////////////////////////////////////////////////////*/

    /// @notice `<=` the fee in force applies now and cancels a pending increase; `>` applies
    /// `feeNoticeSeconds` later by itself. A new increase replaces a pending one and restarts the notice.
    function setProtocolFee(uint16 newFeeBps) external onlyOwner {
        if (newFeeBps > maxProtocolFeeBps) revert FeeAboveCap(newFeeBps, maxProtocolFeeBps);
        _materialise();
        uint16 current = _feeBps;
        if (newFeeBps <= current) {
            _clearPending();
            _feeBps = newFeeBps;
            emit ProtocolFeeChanged(current, newFeeBps);
        } else {
            uint64 at = uint64(block.timestamp) + feeNoticeSeconds;
            _pendingFeeBps = newFeeBps;
            _pendingFeeAt = at;
            emit ProtocolFeeIncreaseScheduled(current, newFeeBps, at);
        }
    }

    function cancelPendingProtocolFee() external onlyOwner {
        _materialise();
        if (_pendingFeeAt == 0) revert NoPendingFee();
        _clearPending();
    }

    /// @notice Disabled: an owner that could renounce would freeze the fee where it stands forever.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Misdirected value only: anything above `totalOwed`. Never an order, a plan or a credit.
    function rescueSurplus(Currency currency, address to) external onlyOwner nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        uint256 bal = currency.balanceOfSelf();
        uint256 owed = totalOwed[currency];
        amount = bal > owed ? bal - owed : 0;
        if (amount == 0) revert NothingToRescue();
        emit SurplusRescued(currency, to, amount);
        currency.transfer(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                              PERMISSIONLESS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pays the protocol's credit in `currency` to the immutable recipient. Anyone may call.
    function flushProtocolFees(Currency currency) external nonReentrant returns (uint256 amount) {
        amount = protocolOwed[currency];
        if (amount == 0) revert NothingToFlush();
        protocolOwed[currency] = 0;
        totalOwed[currency] -= amount;
        emit ProtocolFeesFlushed(currency, protocolFeeRecipient, amount);
        currency.transfer(protocolFeeRecipient, amount);
    }

    /// @notice An integrator pulls its own credit to `to`.
    function claimIntegratorFees(Currency currency, address to) external nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = integratorOwed[msg.sender][currency];
        if (amount == 0) revert NothingToClaim();
        integratorOwed[msg.sender][currency] = 0;
        totalOwed[currency] -= amount;
        emit IntegratorFeesClaimed(msg.sender, currency, to, amount);
        currency.transfer(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _checkIntegrator(address integrator, uint16 integratorBps) internal pure {
        if (integratorBps > MAX_INTEGRATOR_BPS) revert IntegratorBpsAboveCap(integratorBps);
        if (integratorBps != 0 && integrator == address(0)) revert IntegratorMissing();
    }

    /// @dev Splits `amount` (output just received, already counted in `totalOwed` by the caller or not at all)
    /// into the protocol and integrator credits, returning what is left for the user. The two credits are
    /// added to `totalOwed`; the caller accounts for the remainder.
    function _chargeFees(Currency currency, uint256 amount, uint16 feeBps, address integrator, uint16 integratorBps)
        internal
        returns (uint256 protocolFee, uint256 integratorFee, uint256 net)
    {
        protocolFee = amount * feeBps / BPS;
        integratorFee = amount * integratorBps / BPS;
        net = amount - protocolFee - integratorFee;
        if (protocolFee != 0) {
            protocolOwed[currency] += protocolFee;
            totalOwed[currency] += protocolFee;
        }
        if (integratorFee != 0) {
            integratorOwed[integrator][currency] += integratorFee;
            totalOwed[currency] += integratorFee;
        }
    }

    function _materialise() private {
        uint64 at = _pendingFeeAt;
        if (at != 0 && block.timestamp >= at) {
            uint16 next = _pendingFeeBps;
            emit ProtocolFeeChanged(_feeBps, next);
            _feeBps = next;
            _pendingFeeBps = 0;
            _pendingFeeAt = 0;
        }
    }

    function _clearPending() private {
        uint64 at = _pendingFeeAt;
        if (at == 0) return;
        emit PendingProtocolFeeCancelled(_pendingFeeBps, at);
        _pendingFeeBps = 0;
        _pendingFeeAt = 0;
    }
}
