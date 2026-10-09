/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";

/// @title DeepCoreMerkleDrop - one airdrop: a Merkle root of (index, account, amount), claimable until expiry
/// @notice One EIP-1167 clone per drop, made and funded in the same transaction by `DeepCoreDropFactory`. Anyone
/// with a leaf claims it (the recipient pays the gas, unlike a multisend); after `expiresAt` the creator takes
/// back whatever was not claimed.
///
/// LEAF = keccak256(bytes.concat(keccak256(abi.encode(index, account, amount)))) - OpenZeppelin's standard,
/// double-hashed so a leaf can never be read as an inner node. Proofs are verified with `MerkleProof.verify`
/// (sorted pairs). The SDK builds the tree and proofs.
///
/// WHO RECEIVES. A claim always pays `account`, never the caller. A stranger may submit the claim of an account
/// with no code (gas-sponsored claims); an account WITH code must claim for itself - the rule the epoch
/// distributors adopted (CLAUDE.md, 2026-09-14) so a stranger cannot push a share into a contract that cannot
/// use it. Each index is claimed at most once.
///
/// FUNDS CAN NEVER BE STUCK. The drop's balance enters in `initialize`'s transaction (the factory transfers
/// it) and leaves through `claim` or, after `expiresAt`, the creator's `sweep`, which takes the WHOLE remaining
/// balance (anything forced in included). No owner, no admin, no way to change the root, the currency or the
/// expiry, and the creator cannot withdraw before expiry. A DIFFERENT ERC-20 sent here by mistake is nobody's
/// drop and leaves at any time through the creator's `rescueOtherToken`, which refuses the drop currency.
contract DeepCoreMerkleDrop is ReentrancyGuard {
    using CurrencyLibrary for Currency;
    using SafeERC20 for IERC20;

    event Claimed(uint256 indexed index, address indexed account, uint256 amount, address caller);
    event Swept(address indexed to, uint256 amount);
    event OtherTokenRescued(address indexed token, address indexed to, uint256 amount);

    error OnlyFactory();
    error AlreadyInitialized();
    error AlreadyClaimed(uint256 index);
    error InvalidProof();
    error Expired(uint64 expiresAt);
    error NotExpired(uint64 expiresAt);
    error NotCreator(address caller);
    error ContractAccountMustClaimItself(address account, address caller);
    error NothingToSweep();
    error ZeroAddress();
    error IsDropCurrency();

    address public immutable FACTORY;

    bool private _initialized;
    Currency public currency;
    bytes32 public merkleRoot;
    uint64 public expiresAt;
    address public creator;
    uint256 public totalAmount;
    uint256 public claimedAmount;
    string public metadataURI;
    mapping(uint256 => uint256) private _claimedBitmap;

    constructor(address factory) {
        if (factory == address(0)) revert ZeroAddress();
        FACTORY = factory;
        _initialized = true;
    }

    /// @notice Called once by the factory, which funds the clone in the same transaction.
    function initialize(
        address creator_,
        Currency currency_,
        uint256 totalAmount_,
        bytes32 merkleRoot_,
        uint64 expiresAt_,
        string calldata metadataURI_
    ) external {
        if (msg.sender != FACTORY) revert OnlyFactory();
        if (_initialized) revert AlreadyInitialized();
        _initialized = true;
        creator = creator_;
        currency = currency_;
        totalAmount = totalAmount_;
        merkleRoot = merkleRoot_;
        expiresAt = expiresAt_;
        metadataURI = metadataURI_;
    }

    /// @notice Native funding arrives from the factory only; anything else forced in is swept at expiry.
    receive() external payable {
        if (msg.sender != FACTORY) revert OnlyFactory();
    }

    function isClaimed(uint256 index) public view returns (bool) {
        return (_claimedBitmap[index >> 8] >> (index & 255)) & 1 == 1;
    }

    /// @notice Claim leaf `index` for `account`. Pays `account`.
    function claim(uint256 index, address account, uint256 amount, bytes32[] calldata proof) external nonReentrant {
        if (block.timestamp >= expiresAt) revert Expired(expiresAt);
        if (isClaimed(index)) revert AlreadyClaimed(index);
        if (account.code.length != 0 && msg.sender != account) revert ContractAccountMustClaimItself(account, msg.sender);
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
        if (!MerkleProof.verify(proof, merkleRoot, leaf)) revert InvalidProof();
        _claimedBitmap[index >> 8] |= (1 << (index & 255));
        claimedAmount += amount;
        emit Claimed(index, account, amount, msg.sender);
        currency.transfer(account, amount);
    }

    /// @notice After expiry the creator takes back everything left, to `to`.
    function sweep(address to) external nonReentrant returns (uint256 amount) {
        if (msg.sender != creator) revert NotCreator(msg.sender);
        if (block.timestamp < expiresAt) revert NotExpired(expiresAt);
        if (to == address(0)) revert ZeroAddress();
        amount = currency.balanceOfSelf();
        if (amount == 0) revert NothingToSweep();
        emit Swept(to, amount);
        currency.transfer(to, amount);
    }

    /// @notice An ERC-20 that is not this drop's currency, sent here by mistake, to `to`. Creator only, any time.
    function rescueOtherToken(address token, address to) external nonReentrant returns (uint256 amount) {
        if (msg.sender != creator) revert NotCreator(msg.sender);
        if (to == address(0)) revert ZeroAddress();
        if (token == Currency.unwrap(currency)) revert IsDropCurrency();
        amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToSweep();
        emit OtherTokenRescued(token, to, amount);
        IERC20(token).safeTransfer(to, amount);
    }
}
