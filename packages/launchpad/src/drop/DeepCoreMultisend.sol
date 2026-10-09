/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {DeepCoreFeeGate} from "../fees/DeepCoreFeeGate.sol";

/// @title DeepCoreMultisend - send native or an ERC-20 to many addresses in one transaction, for one flat fee
/// @notice Push distribution, the sender pays the gas: every recipient receives in the same transaction. The
/// flat fee (`DeepCoreFeeGate.feeWei`, set by the governance Safe inside an immutable cap; launch price 25% below
/// the classic multisender's per-transaction fee on the same chain) is charged once per call, in native.
///
/// ATOMIC. A call either pays every recipient exactly or reverts whole (a recipient that refuses native, a
/// token that blocks one address). Remove the offending address and send again; nothing is half-sent.
///
/// NO CUSTODY. ERC-20 moves straight from the sender to each recipient (`transferFrom(sender, recipient)`,
/// after the sender approves this contract); native passes through inside the call. Between transactions this
/// contract holds only fees, which leave through the permissionless `flushProtocolFees` (forced native too).
/// An ERC-20 sent here by mistake leaves through the owner's `rescueERC20`.
contract DeepCoreMultisend is DeepCoreFeeGate {
    using SafeERC20 for IERC20;

    event MultisentNative(address indexed sender, uint256 recipients, uint256 total);
    event MultisentToken(address indexed sender, address indexed token, uint256 recipients, uint256 total);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    error LengthMismatch(uint256 recipients, uint256 amounts);
    error NoRecipients();
    error TooManyRecipients(uint256 count);
    error ZeroRecipient(uint256 index);
    error NativeValueTooLow(uint256 required, uint256 sent);
    error NothingToRescue(address token);

    /// @notice A call beyond this would not fit a block on most chains anyway; the bound keeps gas estimates
    /// honest and a mistaken paste from burning a whole block.
    uint256 public constant MAX_RECIPIENTS = 1_000;

    constructor(address owner_, address protocolFeeRecipient_, uint256 initialFeeWei, uint256 maxFeeWei_, uint32 noticeSeconds_)
        DeepCoreFeeGate(owner_, protocolFeeRecipient_, initialFeeWei, maxFeeWei_, noticeSeconds_)
    {}

    /// @notice Send `amounts[i]` of native to `recipients[i]`. `msg.value` = the sum plus at least the fee; the
    /// surplus is refunded last.
    function multisendNative(address[] calldata recipients, uint256[] calldata amounts) external payable nonReentrant {
        uint256 total = _check(recipients, amounts);
        if (msg.value < total) revert NativeValueTooLow(total, msg.value);
        uint256 surplus = _takeFee(msg.value - total);
        emit MultisentNative(msg.sender, recipients.length, total);
        for (uint256 i; i < recipients.length; ++i) {
            _sendNative(recipients[i], amounts[i]);
        }
        if (surplus != 0) _sendNative(msg.sender, surplus);
    }

    /// @notice Send `amounts[i]` of `token` from the caller to `recipients[i]`. Approve this contract for the
    /// sum first. `msg.value` pays the fee; the surplus is refunded last. A fee-on-transfer token delivers what
    /// it delivers; the event reports the amounts asked.
    function multisendToken(address token, address[] calldata recipients, uint256[] calldata amounts) external payable nonReentrant {
        uint256 total = _check(recipients, amounts);
        uint256 surplus = _takeFee(msg.value);
        emit MultisentToken(msg.sender, token, recipients.length, total);
        IERC20 t = IERC20(token);
        for (uint256 i; i < recipients.length; ++i) {
            t.safeTransferFrom(msg.sender, recipients[i], amounts[i]);
        }
        if (surplus != 0) _sendNative(msg.sender, surplus);
    }

    /// @notice An ERC-20 sent here by mistake (the contract never holds one by design).
    function rescueERC20(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToRescue(token);
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    function _check(address[] calldata recipients, uint256[] calldata amounts) private pure returns (uint256 total) {
        uint256 n = recipients.length;
        if (n == 0) revert NoRecipients();
        if (n > MAX_RECIPIENTS) revert TooManyRecipients(n);
        if (amounts.length != n) revert LengthMismatch(n, amounts.length);
        for (uint256 i; i < n; ++i) {
            if (recipients[i] == address(0)) revert ZeroRecipient(i);
            total += amounts[i];
        }
    }
}
