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
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {DeepCoreFeeGate} from "deepcore-launchpad/src/fees/DeepCoreFeeGate.sol";

import {DeepCoreManagedVault} from "./DeepCoreManagedVault.sol";

/// @title DeepCoreVaultFactory - creates managed-liquidity vaults (EIP-1167 clones) and holds the two fees
/// the Safe governs
/// @notice Design of record: docs/products/managed-vaults.md.
///
/// FEES (owner decisions of record, 2026-10-12), both in the house pattern: the owner (the governance Safe;
/// `Ownable2Step`, `renounceOwnership` reverts) moves them only inside immutable caps; an increase applies
/// by itself `feeNoticeSeconds` later, a decrease at once; nothing is retroactive.
///   * the flat creation fee in native, through `DeepCoreFeeGate` (default 0.075 ETH-equivalent, cap 10x),
///     paid to the immutable `protocolFeeRecipient` by the permissionless `flushProtocolFees`;
///   * the protocol performance fee on harvested LP fees (default 10%, immutable cap at most 20%), which each
///     vault FREEZES at creation. Changing it here never touches an existing vault.
///
/// WHAT THE OWNER CANNOT DO. Gate who creates a vault (no allowlist, no pause; the owner pays like anyone),
/// touch a vault, its parameters, its fees or its funds, or change where fees go.
///
/// ADDRESSES. A vault's address binds its creator: the clone salt is `keccak256(creator, salt)`, so nobody
/// can take a creator's address on another chain where the factory sits at the same address.
contract DeepCoreVaultFactory is DeepCoreFeeGate {
    using SafeERC20 for IERC20;

    event VaultCreated(
        address indexed vault, PoolId indexed poolId, address indexed curator, uint16 performanceFeeBps, uint256 feePaid
    );
    event PerformanceFeeChanged(uint16 previousBps, uint16 newBps);
    event PerformanceFeeIncreaseScheduled(uint16 currentBps, uint16 newBps, uint64 effectiveAt);
    event PendingPerformanceFeeCancelled(uint16 cancelledBps, uint64 effectiveAt);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    error ImplementationMismatch();
    error PerformanceFeeAboveCap(uint256 bps, uint256 cap);
    error NoPendingPerformanceFee();
    error RescueToZero();
    error NothingToRescue(address token);

    /// @notice Compile-time ceiling: the vault refuses anything above it as well.
    uint16 public constant ABSOLUTE_MAX_PERFORMANCE_FEE_BPS = 2_000;

    /// @notice The vault implementation every clone delegates to (immutable; no upgrade path).
    address public immutable implementation;
    /// @notice The owner can never set a performance fee above this.
    uint16 public immutable maxPerformanceFeeBps;

    uint16 private _perfBps;
    uint16 private _pendingPerfBps;
    uint64 private _pendingPerfAt;

    address[] private _vaults;
    mapping(address => bool) public isVault;
    mapping(PoolId => address[]) private _vaultsOfPool;

    /// @param implementation_ A `DeepCoreManagedVault` built with `factory == address(this)`.
    constructor(
        address implementation_,
        address owner_,
        address protocolFeeRecipient_,
        uint256 initialFeeWei,
        uint256 maxFeeWei_,
        uint32 noticeSeconds_,
        uint16 initialPerformanceFeeBps,
        uint16 maxPerformanceFeeBps_
    ) DeepCoreFeeGate(owner_, protocolFeeRecipient_, initialFeeWei, maxFeeWei_, noticeSeconds_) {
        if (implementation_ == address(0)) revert ZeroAddress();
        if (DeepCoreManagedVault(payable(implementation_)).FACTORY() != address(this)) revert ImplementationMismatch();
        if (maxPerformanceFeeBps_ > ABSOLUTE_MAX_PERFORMANCE_FEE_BPS) {
            revert PerformanceFeeAboveCap(maxPerformanceFeeBps_, ABSOLUTE_MAX_PERFORMANCE_FEE_BPS);
        }
        if (initialPerformanceFeeBps > maxPerformanceFeeBps_) {
            revert PerformanceFeeAboveCap(initialPerformanceFeeBps, maxPerformanceFeeBps_);
        }
        implementation = implementation_;
        maxPerformanceFeeBps = maxPerformanceFeeBps_;
        _perfBps = initialPerformanceFeeBps;
        emit PerformanceFeeChanged(0, initialPerformanceFeeBps);
    }

    /*//////////////////////////////////////////////////////////////
                                 CREATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Create and initialize a vault in one transaction. Pays `feeWei()` in native; the surplus is
    /// refunded. The caller becomes the curator. Every parameter is validated by the vault and frozen.
    function createVault(DeepCoreManagedVault.VaultParams calldata p, bytes32 salt)
        external
        payable
        nonReentrant
        returns (address vault)
    {
        uint256 surplus = _takeFee(msg.value);
        uint16 perf = performanceFeeBps();
        vault = Clones.cloneDeterministic(implementation, _salt(msg.sender, salt));
        DeepCoreManagedVault(payable(vault)).initialize(p, msg.sender, protocolFeeRecipient, perf);
        isVault[vault] = true;
        _vaults.push(vault);
        PoolId id = DeepCoreManagedVault(payable(vault)).poolId();
        _vaultsOfPool[id].push(vault);
        emit VaultCreated(vault, id, msg.sender, perf, msg.value - surplus);
        if (surplus != 0) _sendNative(msg.sender, surplus);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function predictVault(address creator, bytes32 salt) external view returns (address) {
        return Clones.predictDeterministicAddress(implementation, _salt(creator, salt), address(this));
    }

    function vaultCount() external view returns (uint256) {
        return _vaults.length;
    }

    function vaultAt(uint256 i) external view returns (address) {
        return _vaults[i];
    }

    /// @notice A page of vaults, `[start, start + count)` clamped to the list.
    function vaults(uint256 start, uint256 count) external view returns (address[] memory page) {
        uint256 n = _vaults.length;
        if (start >= n) return new address[](0);
        uint256 end = start + count > n ? n : start + count;
        page = new address[](end - start);
        for (uint256 i = start; i < end; ++i) {
            page[i - start] = _vaults[i];
        }
    }

    function vaultsOfPool(PoolId id) external view returns (address[] memory) {
        return _vaultsOfPool[id];
    }

    /// @notice The performance fee a vault created in THIS block freezes into itself.
    function performanceFeeBps() public view returns (uint16) {
        uint64 at = _pendingPerfAt;
        if (at != 0 && block.timestamp >= at) return _pendingPerfBps;
        return _perfBps;
    }

    /// @notice An announced increase not yet in force; `(0, 0)` when there is none.
    function pendingPerformanceFee() external view returns (uint16 newBps, uint64 effectiveAt) {
        effectiveAt = _pendingPerfAt;
        if (effectiveAt == 0 || block.timestamp >= effectiveAt) return (0, 0);
        newBps = _pendingPerfBps;
    }

    /*//////////////////////////////////////////////////////////////
                                 OWNER
    //////////////////////////////////////////////////////////////*/

    /// @notice `<=` the fee in force applies now and cancels a pending increase; `>` applies
    /// `feeNoticeSeconds` later by itself. New vaults only.
    function setPerformanceFee(uint16 newBps) external onlyOwner {
        if (newBps > maxPerformanceFeeBps) revert PerformanceFeeAboveCap(newBps, maxPerformanceFeeBps);
        _materialisePerf();
        uint16 current = _perfBps;
        if (newBps <= current) {
            _clearPendingPerf();
            _perfBps = newBps;
            emit PerformanceFeeChanged(current, newBps);
        } else {
            uint64 at = uint64(block.timestamp) + feeNoticeSeconds;
            _pendingPerfBps = newBps;
            _pendingPerfAt = at;
            emit PerformanceFeeIncreaseScheduled(current, newBps, at);
        }
    }

    function cancelPendingPerformanceFee() external onlyOwner {
        _materialisePerf();
        if (_pendingPerfAt == 0) revert NoPendingPerformanceFee();
        _clearPendingPerf();
    }

    /// @notice Misdirected ERC-20 only. The factory never holds a token for anyone.
    function rescueERC20(address token, address to) external onlyOwner nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert RescueToZero();
        amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToRescue(token);
        emit ERC20Rescued(token, to, amount);
        IERC20(token).safeTransfer(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _salt(address creator, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(creator, salt));
    }

    function _materialisePerf() private {
        uint64 at = _pendingPerfAt;
        if (at != 0 && block.timestamp >= at) {
            uint16 next = _pendingPerfBps;
            emit PerformanceFeeChanged(_perfBps, next);
            _perfBps = next;
            _pendingPerfBps = 0;
            _pendingPerfAt = 0;
        }
    }

    function _clearPendingPerf() private {
        uint64 at = _pendingPerfAt;
        if (at == 0) return;
        emit PendingPerformanceFeeCancelled(_pendingPerfBps, at);
        _pendingPerfBps = 0;
        _pendingPerfAt = 0;
    }
}
