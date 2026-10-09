/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";

/// @title DeepCoreProtocolFeeController
/// @notice Decides the protocol fee for every DeepCoreProtocol pool.
///
/// @dev ##################### WHY THIS CONTRACT IS SHAPED THIS WAY #####################
///
/// ProtocolFees._fetchProtocolFee calls protocolFeeForPool via staticcall while a pool is being
/// INITIALIZED, forwarding all remaining gas and requiring exactly 32 bytes of return data.
/// If this function reverts, returns the wrong size, or burns excessive gas, POOL CREATION FAILS.
/// A broken controller therefore bricks the protocol for new pools until it is replaced.
///
/// Consequences, all deliberate:
///   - protocolFeeForPool MUST NOT revert on any input. Every branch returns a value.
///   - It performs at most two SLOADs. All validation happens in the owner-only setters instead,
///     so a bad value can never enter storage and never has to be checked on the hot path.
///   - Values are clamped on write, not on read.
///
/// FEE SEMANTICS (verified in ProtocolFeeLibrary): the protocol fee is taken from the swap INPUT
/// first, and the LP fee is then taken from the remainder. It is therefore ADDITIVE to what a
/// swapper pays and does NOT come out of LP earnings:
///
///     totalSwapCost = protocolFee + lpFee - (protocolFee * lpFee / 1_000_000)
///
/// This matters commercially. The default 0.1% (1000 pips) roughly TRIPLES the cost of a 0.05%
/// pool and is about 11x the fee of a 0.01% stable pool, which makes tight pools uncompetitive
/// against any venue charging less. Use setTierFee to run a lower protocol fee on low-fee tiers
/// rather than applying the flat default everywhere.
///
/// OWNERSHIP: this contract sets protocol revenue and must be owned by the same multisig+timelock
/// that governs Vault.registerApp. Ownable2Step is used so ownership cannot be handed to an
/// address that has not accepted it.
/// ###############################################################################
contract DeepCoreProtocolFeeController is IProtocolFeeController, Ownable2Step {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    /// @notice Hard cap enforced by core (ProtocolFeeLibrary.MAX_PROTOCOL_FEE): 0.4%
    uint16 public constant MAX_PROTOCOL_FEE = 4000;

    /// @notice Launch default: 0.1% == 1000 pips of PIPS_DENOMINATOR (1_000_000), both directions
    uint16 public constant DEFAULT_FEE_PIPS = 1000;

    /// @dev One storage slot: 1 + 2 + 2 = 5 bytes. Read with a single SLOAD.
    struct FeeConfig {
        bool isSet;
        uint16 zeroForOne;
        uint16 oneForZero;
    }

    /// @notice Fee applied when no pool or tier override matches
    FeeConfig private _defaultFee;

    /// @notice Per-pool override. Highest precedence.
    mapping(PoolId poolId => FeeConfig) private _poolFee;

    /// @notice Per-LP-fee-tier override, keyed by the static LP fee of the pool. Middle precedence.
    mapping(uint24 lpFeeTier => FeeConfig) private _tierFee;

    /// @notice Override applied to dynamic-fee pools, which have no static tier to key on.
    FeeConfig private _dynamicFee;

    /// @notice Emergency switch: when true every pool reports a zero protocol fee.
    /// @dev Lets governance stop accruing fees in one transaction without redeploying or unsetting
    /// each pool individually. Does not touch already-accrued fees.
    bool public feesDisabled;

    /// @notice Address that may switch fees OFF immediately, and do nothing else.
    /// @dev Delay belongs on privilege escalation, never on privilege reduction. If the only
    /// route to disabling fees runs through the governance timelock, the protocol keeps charging
    /// throughout an incident. The guardian closes that gap without widening the attack surface:
    /// it can only ever make the protocol take LESS. Re-enabling, changing any fee, and moving
    /// the guardian itself all remain owner-only and therefore timelocked.
    address public guardian;

    event DefaultFeeUpdated(uint16 zeroForOne, uint16 oneForZero);
    event PoolFeeUpdated(PoolId indexed poolId, bool isSet, uint16 zeroForOne, uint16 oneForZero);
    event TierFeeUpdated(uint24 indexed lpFeeTier, bool isSet, uint16 zeroForOne, uint16 oneForZero);
    event DynamicFeeUpdated(bool isSet, uint16 zeroForOne, uint16 oneForZero);
    event FeesDisabledSet(bool disabled);
    event GuardianUpdated(address indexed previousGuardian, address indexed newGuardian);
    event EmergencyFeesDisabled(address indexed caller);

    /// @notice A configured fee exceeds the 0.4% cap enforced by core
    error FeeExceedsMaximum(uint16 fee, uint16 maximum);

    /// @notice Caller is neither the guardian nor the owner
    error NotGuardianOrOwner();

    /// @param owner_ Should be the governance timelock, never an EOA on a live chain.
    /// @param guardian_ May disable fees instantly during an incident. May be address(0) to
    /// start with no guardian; the owner can appoint one later.
    constructor(address owner_, address guardian_) Ownable(owner_) {
        guardian = guardian_;
        emit GuardianUpdated(address(0), guardian_);
        _defaultFee = FeeConfig({isSet: true, zeroForOne: DEFAULT_FEE_PIPS, oneForZero: DEFAULT_FEE_PIPS});
        emit DefaultFeeUpdated(DEFAULT_FEE_PIPS, DEFAULT_FEE_PIPS);
    }

    /*//////////////////////////////////////////////////////////////
                    HOT PATH - CALLED DURING POOL INIT
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IProtocolFeeController
    /// @dev MUST NOT revert. Precedence: kill switch > per-pool > tier (or dynamic) > default.
    function protocolFeeForPool(PoolKey memory poolKey) external view override returns (uint24) {
        if (feesDisabled) return 0;

        FeeConfig memory config = _poolFee[poolKey.toId()];
        if (config.isSet) return _pack(config);

        config = poolKey.fee.isDynamicLPFee() ? _dynamicFee : _tierFee[poolKey.fee];
        if (config.isSet) return _pack(config);

        return _pack(_defaultFee);
    }

    /// @dev Pack two directional fees into the uint24 layout core expects:
    /// low 12 bits = zeroForOne, upper 12 bits = oneForZero.
    /// Inputs are already bounded by the setters, so no masking or validation is needed here.
    function _pack(FeeConfig memory config) private pure returns (uint24) {
        return uint24(config.zeroForOne) | (uint24(config.oneForZero) << 12);
    }

    /*//////////////////////////////////////////////////////////////
                          GOVERNANCE - VALIDATED
    //////////////////////////////////////////////////////////////*/

    function setDefaultFee(uint16 zeroForOne, uint16 oneForZero) external onlyOwner {
        _validate(zeroForOne);
        _validate(oneForZero);
        _defaultFee = FeeConfig({isSet: true, zeroForOne: zeroForOne, oneForZero: oneForZero});
        emit DefaultFeeUpdated(zeroForOne, oneForZero);
    }

    /// @notice Override the fee for one specific pool. Highest precedence.
    function setPoolFee(PoolId poolId, bool isSet, uint16 zeroForOne, uint16 oneForZero) external onlyOwner {
        if (isSet) {
            _validate(zeroForOne);
            _validate(oneForZero);
        }
        _poolFee[poolId] = FeeConfig({isSet: isSet, zeroForOne: zeroForOne, oneForZero: oneForZero});
        emit PoolFeeUpdated(poolId, isSet, zeroForOne, oneForZero);
    }

    /// @notice Override the fee for every pool on a given static LP fee tier.
    /// @dev The intended tool for keeping low-fee pools competitive: set a 0.01% stable tier to a
    /// much smaller protocol fee than the 0.1% default.
    function setTierFee(uint24 lpFeeTier, bool isSet, uint16 zeroForOne, uint16 oneForZero) external onlyOwner {
        if (isSet) {
            _validate(zeroForOne);
            _validate(oneForZero);
        }
        _tierFee[lpFeeTier] = FeeConfig({isSet: isSet, zeroForOne: zeroForOne, oneForZero: oneForZero});
        emit TierFeeUpdated(lpFeeTier, isSet, zeroForOne, oneForZero);
    }

    /// @notice Override the fee for dynamic-fee pools, which carry no static tier.
    function setDynamicFee(bool isSet, uint16 zeroForOne, uint16 oneForZero) external onlyOwner {
        if (isSet) {
            _validate(zeroForOne);
            _validate(oneForZero);
        }
        _dynamicFee = FeeConfig({isSet: isSet, zeroForOne: zeroForOne, oneForZero: oneForZero});
        emit DynamicFeeUpdated(isSet, zeroForOne, oneForZero);
    }

    /// @notice Stop or resume protocol fee accrual across every pool in one transaction.
    function setFeesDisabled(bool disabled) external onlyOwner {
        feesDisabled = disabled;
        emit FeesDisabledSet(disabled);
    }

    /// @notice Switch every pool to a zero protocol fee immediately. One-way.
    /// @dev Callable by the guardian or the owner. There is deliberately no guardian path back:
    /// re-enabling fees is an escalation and goes through `setFeesDisabled(false)`, which is
    /// owner-only and therefore timelocked. A compromised guardian can cost the protocol revenue
    /// and nothing else — it cannot raise a fee, retarget one, or change who controls this
    /// contract.
    function emergencyDisableFees() external {
        if (msg.sender != guardian && msg.sender != owner()) revert NotGuardianOrOwner();
        feesDisabled = true;
        emit FeesDisabledSet(true);
        emit EmergencyFeesDisabled(msg.sender);
    }

    /// @notice Appoint or remove the guardian. Owner-only, so timelocked.
    function setGuardian(address newGuardian) external onlyOwner {
        emit GuardianUpdated(guardian, newGuardian);
        guardian = newGuardian;
    }

    function _validate(uint16 fee) private pure {
        if (fee > MAX_PROTOCOL_FEE) revert FeeExceedsMaximum(fee, MAX_PROTOCOL_FEE);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function defaultFee() external view returns (bool isSet, uint16 zeroForOne, uint16 oneForZero) {
        FeeConfig memory c = _defaultFee;
        return (c.isSet, c.zeroForOne, c.oneForZero);
    }

    function poolFee(PoolId poolId) external view returns (bool isSet, uint16 zeroForOne, uint16 oneForZero) {
        FeeConfig memory c = _poolFee[poolId];
        return (c.isSet, c.zeroForOne, c.oneForZero);
    }

    function tierFee(uint24 lpFeeTier) external view returns (bool isSet, uint16 zeroForOne, uint16 oneForZero) {
        FeeConfig memory c = _tierFee[lpFeeTier];
        return (c.isSet, c.zeroForOne, c.oneForZero);
    }

    function dynamicFee() external view returns (bool isSet, uint16 zeroForOne, uint16 oneForZero) {
        FeeConfig memory c = _dynamicFee;
        return (c.isSet, c.zeroForOne, c.oneForZero);
    }
}
