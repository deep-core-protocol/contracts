/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";

import {DeepCoreFeeGate} from "../fees/DeepCoreFeeGate.sol";
import {DeepCoreMerkleDrop} from "./DeepCoreMerkleDrop.sol";

/// @title DeepCoreDropFactory - create and fund a Merkle airdrop in one transaction, for one flat fee
/// @notice Clones a `DeepCoreMerkleDrop`, initializes it and moves the drop's funds into it, all in `createDrop`.
/// The flat fee (`DeepCoreFeeGate.feeWei`, set by the governance Safe inside an immutable cap; launch price 25%
/// below the classic multisender's per-transaction fee on the same chain) is charged once per drop, in native.
///
/// FUNDING. Native: `msg.value` = `amount` + at least the fee; the amount is forwarded to the clone, the surplus
/// refunded. ERC-20: approve this factory for `amount`; it is moved from the creator STRAIGHT to the clone, and
/// the drop records what the clone actually received (a fee-on-transfer token funds its net amount - build the
/// Merkle tree for that). The factory never holds a drop's funds.
///
/// NO CUSTODY, NO BACKDOOR. The owner (the Safe) controls the fee and can rescue an ERC-20 sent to the factory by
/// mistake; it cannot reach a drop (a drop has no owner; its creator can only sweep after expiry). Native here is
/// fee only and leaves through the permissionless `flushProtocolFees`.
contract DeepCoreDropFactory is DeepCoreFeeGate {
    using SafeERC20 for IERC20;
    using CurrencyLibrary for Currency;

    event DropCreated(
        address indexed drop,
        address indexed creator,
        Currency indexed currency,
        uint256 amount,
        bytes32 merkleRoot,
        uint64 expiresAt,
        string metadataURI
    );
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    error ZeroAmount();
    error ZeroRoot();
    error InvalidExpiry(uint64 expiresAt);
    error NativeValueTooLow(uint256 required, uint256 sent);
    error MetadataTooLong(uint256 length);
    error NothingToRescue(address token);

    /// @notice A drop must stay claimable at least this long, and at most `MAX_DURATION`.
    uint64 public constant MIN_DURATION = 1 days;
    uint64 public constant MAX_DURATION = 5 * 365 days;
    uint256 public constant MAX_METADATA_BYTES = 2048;

    DeepCoreMerkleDrop public immutable IMPLEMENTATION;

    address[] private _drops;
    mapping(address => address[]) private _dropsByCreator;
    mapping(address => bool) public isDrop;

    constructor(address owner_, address protocolFeeRecipient_, uint256 initialFeeWei, uint256 maxFeeWei_, uint32 noticeSeconds_)
        DeepCoreFeeGate(owner_, protocolFeeRecipient_, initialFeeWei, maxFeeWei_, noticeSeconds_)
    {
        IMPLEMENTATION = new DeepCoreMerkleDrop(address(this));
    }

    /// @notice Create, fund and list a drop. See the contract notes for funding.
    function createDrop(Currency currency, uint256 amount, bytes32 merkleRoot, uint64 expiresAt, string calldata metadataURI)
        external
        payable
        nonReentrant
        returns (address drop)
    {
        if (amount == 0) revert ZeroAmount();
        if (merkleRoot == bytes32(0)) revert ZeroRoot();
        if (expiresAt < block.timestamp + MIN_DURATION || expiresAt > block.timestamp + MAX_DURATION) revert InvalidExpiry(expiresAt);
        if (bytes(metadataURI).length > MAX_METADATA_BYTES) revert MetadataTooLong(bytes(metadataURI).length);

        uint256 feeValue = msg.value;
        if (currency.isNative()) {
            if (msg.value < amount) revert NativeValueTooLow(amount, msg.value);
            feeValue = msg.value - amount;
        }
        uint256 surplus = _takeFee(feeValue);

        drop = Clones.clone(address(IMPLEMENTATION));
        uint256 funded = amount;
        if (currency.isNative()) {
            _sendNative(drop, amount);
        } else {
            uint256 before = currency.balanceOf(drop);
            IERC20(Currency.unwrap(currency)).safeTransferFrom(msg.sender, drop, amount);
            funded = currency.balanceOf(drop) - before;
            if (funded == 0) revert ZeroAmount();
        }
        DeepCoreMerkleDrop(payable(drop)).initialize(msg.sender, currency, funded, merkleRoot, expiresAt, metadataURI);
        _drops.push(drop);
        _dropsByCreator[msg.sender].push(drop);
        isDrop[drop] = true;
        emit DropCreated(drop, msg.sender, currency, funded, merkleRoot, expiresAt, metadataURI);

        if (surplus != 0) _sendNative(msg.sender, surplus);
    }

    /// @notice An ERC-20 sent to the factory by mistake. The factory never holds one by design.
    function rescueERC20(address token, address to) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToRescue(token);
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    function dropCount() external view returns (uint256) {
        return _drops.length;
    }

    function drops(uint256 start, uint256 end) external view returns (address[] memory) {
        return _page(_drops, start, end);
    }

    function dropsOf(address creator, uint256 start, uint256 end) external view returns (address[] memory) {
        return _page(_dropsByCreator[creator], start, end);
    }

    function _page(address[] storage list, uint256 start, uint256 end) private view returns (address[] memory page) {
        uint256 length = list.length;
        if (end > length) end = length;
        if (start >= end) return page;
        page = new address[](end - start);
        for (uint256 i = start; i < end; ++i) {
            page[i - start] = list[i];
        }
    }
}
