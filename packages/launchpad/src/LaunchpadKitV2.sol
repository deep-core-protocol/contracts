/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";

import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";
import {IBinPositionManager} from "infinity-periphery/src/pool-bin/interfaces/IBinPositionManager.sol";
import {IBinFungibleToken} from "infinity-periphery/src/pool-bin/interfaces/IBinFungibleToken.sol";
import {IImmutableState} from "infinity-periphery/src/interfaces/IImmutableState.sol";
import {Permit2Forwarder} from "infinity-periphery/src/base/Permit2Forwarder.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {LaunchGuardHook} from "deepcore-hooks/src/launch/LaunchGuardHook.sol";
import {BinLaunchGuardHook} from "deepcore-hooks/src/launch/BinLaunchGuardHook.sol";
import {LaunchTaxModule} from "deepcore-hooks/src/launch/LaunchTaxModule.sol";
import {IDeepCoreLaunchOrigin} from "deepcore-registry/src/IDeepCoreLaunchOrigin.sol";
import {LaunchpadMetadata} from "deepcore-registry/src/IDeepCoreLaunchRegistry.sol";
import {ILockedLaunchOracle} from "deepcore-fees/src/interfaces/ILockedLaunchOracle.sol";

import {DeepCoreLPLocker} from "./DeepCoreLPLocker.sol";
import {DeepCoreBinLPLocker} from "./DeepCoreBinLPLocker.sol";
import {LockParams} from "./interfaces/IDeepCoreLPLocker.sol";
import {ILaunchTokenFactory} from "./interfaces/ILaunchTokenFactory.sol";
import {ILaunchRegistryWriter} from "./interfaces/ILaunchRegistryWriter.sol";
import {
    ILaunchpadKitV2,
    LegKind,
    BinShape,
    LegParams,
    ScheduleParams,
    TaxParams,
    LaunchParamsV2,
    LaunchResultV2,
    LegRecord,
    LaunchRecordV2,
    TenantConfig
} from "./interfaces/ILaunchpadKitV2.sol";
import {LaunchPresets, Preset, PresetParams} from "./libraries/LaunchPresets.sol";
import {LaunchLegs} from "./libraries/LaunchLegs.sol";

/// @title LaunchpadKitV2
/// @notice One transaction: a fresh launch token, 1..N LOCKED pools (single-sided CL ranges and/or shaped
/// Bin distributions) each quoted in native or any ERC-20, a launch guard on every pool, a registry record
/// per pool, and the protocol and tenant launch fees. Launch pools are born at a ZERO core protocol fee
/// through `DeepCoreProtocolFeeControllerV3`, which asks this contract `isLockedLaunch(poolId)`.
///
/// @dev Design of record: `docs/kit-v2-integration.md`, section "Kit v2 (implemented)". The load-bearing
/// properties, each tied to where it is enforced:
///
/// ########################## 1. THE V3 FLAG (the one promise V3 trusts) ##########################
///
///   `_lockedLaunch[poolId] = true` is written for EVERY leg in the checks-and-effects phase of
///   `createLaunch`, before the kit makes any external call at all (the token address is computed locally
///   from the factory's CREATE2 inputs precisely so this holds). Core reads the protocol fee once, inside
///   `initialize`, so the flag must already be there. It is written in exactly one place, never cleared,
///   and never touched by the owner, by `reconfigureLaunch`, or by any other path.
///
///   Every flagged leg is then initialized, seeded, and LOCKED in the same call, and the lock is read back
///   and asserted (`LockNotRecorded`). There is no try/catch in this contract or in `LaunchLegs`. So a flag
///   can only survive in a transaction whose lock was proven, and a failed lock reverts the flag with the pool.
///
///   The interaction phase lives in the linked library `LaunchLegs`, reached by one DELEGATECALL after every
///   flag is written: the kit in one piece measured 42.9 KB against EIP-170's 24,576 bytes. The library runs
///   in the kit's context (every call it makes is FROM the kit), has no storage, no owner and no upgrade path,
///   and its address is fixed in this contract's bytecode at link time.
///
///   Both leg types are flagged, because both are locked. The V3 doc's "never flag Bin legs" predates
///   `DeepCoreBinLPLocker`; the rule it encodes is "never flag an UNLOCKED leg", and v2 has no unlocked legs.
///   A Bin leg is flagged only because it is locked through `DeepCoreBinLPLocker` with the kit holding zero
///   of every seeded bin's shares afterwards (`KitRetainedBinShares`).
///
/// ################################# 2. SQUATTING #################################
///
///   * Token address: the factory salt is `keccak256(abi.encode(msg.sender, userSalt))`, so a launcher
///     cannot land on another launcher's mined address through the kit's shared factory namespace.
///   * Pool ids: both guards reserve pools on factory tokens for `deployerOf(token)` - this kit - and
///     refuse any claim on a currency with no code, and the token only gains code inside this call.
///
/// ################################# 3. FEES #################################
///
///   * Owner = the governance Safe (`Ownable2Step`; `renounceOwnership` reverts). Its ONLY power is the
///     protocol launch fee, inside the immutable `maxLaunchFeeWei`. Increases take effect automatically
///     `launchFeeNoticeSeconds` after they are announced; decreases are immediate; nothing is retroactive
///     (a launch pays the fee in force in its own block, and nothing about a launch reads it again).
///   * The tenant's integrator launch fee is capped by the immutable `maxIntegratorLaunchFeeWei`.
///   * Both are PULL-credited (`feesOwed`), never pushed during a launch: a recipient that cannot receive
///     native currency cannot block anybody's launch. `flushProtocolFees` is permissionless and can only
///     pay the immutable `protocolFeeRecipient`.
///   * `msg.value` below the total reverts; any excess is refunded to `msg.sender`, last.
///
/// ############################## 4. WHAT IT DOES NOT DO ##############################
///
///   * Custody between transactions. The kit ends every launch holding zero launch token (asserted) and
///     zero bin shares (asserted); its only resting balance is native owed to fee recipients.
///   * Touch the quote currency. A single-sided launch never transfers the quote, so a paused, blocklisted
///     or rebasing quote (a Robinhood stock token) cannot block or skew creation. It can block TRADING.
///   * Protect a launch against the tenant's own hook fee - launches use DeepCore's guards only. Those take
///     the trade fee themselves, in the quote, split by the lock's split (which the kit's library writes
///     into the guard) under the guards' own protocol floor, the same 20% the lockers carry.
///   * Enforce the creator tax's floor. `LaunchParamsV2.tax` is passed through to the guards' `configureTax`
///     with the recipients resolved (`creator`, `integrator`); the GUARD validates rates, expiry, the 10%
///     protocol floor and the 20% integrator cap, because anyone can configure a pool there without this
///     kit. The kit adds only tenant policy (`maxTaxBps`, a restated `taxIntegratorBps`) and asserts at
///     construction that both guards pay the same `protocolFeeRecipient` this kit does.
///   * Stop a sequencer from moving `block.timestamp` inside Nitro's bounds (see `LaunchGuardHook` CLOCK).
contract LaunchpadKitV2 is ILaunchpadKitV2, ILockedLaunchOracle, IDeepCoreLaunchOrigin, Ownable2Step, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;
    using BinPoolParametersHelper for bytes32;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice `beforeInitialize | beforeSwap | afterSwap | beforeSwapReturnsDelta | afterSwapReturnsDelta`, what
    /// `LaunchGuardHook` reports.
    uint16 public constant CL_HOOK_BITMAP = 0x0CC1;
    /// @notice `beforeInitialize | beforeMint | beforeSwap | afterSwap | beforeSwapReturnsDelta |
    /// afterSwapReturnsDelta`, what `BinLaunchGuardHook` reports.
    uint16 public constant BIN_HOOK_BITMAP = 0x0CC5;
    /// @notice The owner's LP-fee protocol floor. Both lockers must enforce at least this.
    uint16 public constant PROTOCOL_LP_FLOOR_BPS = 2_000;
    uint8 public constant MAX_LEGS_HARD_CAP = 8;
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
    /// @notice Mirrors both guards' `MAX_START_DELAY_SECONDS`, asserted equal at construction.
    uint32 public constant MAX_START_DELAY_SECONDS = 30 days;
    string public constant CLOCK_MODE = "mode=timestamp";
    uint16 private constant BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    ICLPoolManager public immutable clPoolManager;
    LaunchGuardHook public immutable clHook;
    ICLPositionManager public immutable clPositionManager;
    DeepCoreLPLocker public immutable clLocker;
    IBinPoolManager public immutable binPoolManager;
    BinLaunchGuardHook public immutable binHook;
    IBinPositionManager public immutable binPositionManager;
    DeepCoreBinLPLocker public immutable binLocker;
    ILaunchTokenFactory public immutable tokenFactory;
    ILaunchRegistryWriter public immutable launchRegistry;
    /// @dev Read off each position manager, never trusted from a deployer.
    IAllowanceTransfer public immutable clPermit2;
    IAllowanceTransfer public immutable binPermit2;
    /// @notice The governance Safe. Also both lockers' `protocolRecipient`, asserted at construction.
    address public immutable protocolFeeRecipient;
    /// @notice Steward of this kit's own `DeepCoreLaunchRegistry` launchpad listing. Metadata only.
    address public immutable launchpadSteward;
    uint256 public immutable maxLaunchFeeWei;
    uint32 public immutable launchFeeNoticeSeconds;
    uint256 public immutable maxIntegratorLaunchFeeWei;
    uint8 public immutable maxLegs;
    uint16 public immutable maxBinsPerLeg;
    /// @dev Both lockers' integrator cap (asserted equal), cached for tenant-config validation.
    uint16 public immutable maxIntegratorBps;
    /// @dev Both guards' creator-tax caps (asserted equal), cached for tenant-config validation.
    uint16 public immutable maxTaxBps;
    uint16 public immutable maxTaxIntegratorBps;
    bytes32 private immutable _tokenInitCodeHash;

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    // slot 0 `_owner` (Ownable), slot 1 `_pendingOwner` (Ownable2Step), slot 2 `_status` (ReentrancyGuard)
    uint256 private _launchFeeWei; // slot 3
    uint256 private _pendingLaunchFeeWei; // slot 4
    uint64 private _pendingLaunchFeeEffectiveAt; // slot 5
    /// @dev THE V3 flag. Written once per leg in `createLaunch`, never cleared.
    mapping(bytes32 poolId => bool) private _lockedLaunch; // slot 6
    mapping(bytes32 poolId => LegRecord) private _legs; // slot 7
    mapping(address token => LaunchRecordV2) private _launches; // slot 8
    mapping(address token => bytes32[]) private _legsOfToken; // slot 9
    /// @notice Native owed to each fee recipient. Sum is `totalFeesOwed`.
    mapping(address account => uint256) public feesOwed; // slot 10
    uint256 public totalFeesOwed; // slot 11
    mapping(address tenant => TenantConfig) private _tenants; // slot 12
    mapping(address tenant => mapping(address quote => bool)) public override tenantQuoteAllowed; // slot 13

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    struct Deployment {
        address owner;
        ICLPoolManager clPoolManager;
        LaunchGuardHook clHook;
        ICLPositionManager clPositionManager;
        DeepCoreLPLocker clLocker;
        IBinPoolManager binPoolManager;
        BinLaunchGuardHook binHook;
        IBinPositionManager binPositionManager;
        DeepCoreBinLPLocker binLocker;
        ILaunchTokenFactory tokenFactory;
        ILaunchRegistryWriter launchRegistry;
        address protocolFeeRecipient;
        address launchpadSteward;
        uint256 initialLaunchFeeWei;
        uint256 maxLaunchFeeWei;
        uint32 launchFeeNoticeSeconds;
        uint256 maxIntegratorLaunchFeeWei;
        uint8 maxLegs;
        uint16 maxBinsPerLeg;
    }

    constructor(Deployment memory d) Ownable(d.owner) {
        if (
            address(d.clPoolManager) == address(0) || address(d.binPoolManager) == address(0)
                || address(d.tokenFactory) == address(0) || address(d.launchRegistry) == address(0)
                || d.protocolFeeRecipient == address(0) || d.launchpadSteward == address(0)
        ) revert ZeroAddress();
        if (address(d.tokenFactory).code.length == 0) revert NoCode(address(d.tokenFactory));
        if (address(d.launchRegistry).code.length == 0) revert NoCode(address(d.launchRegistry));

        address vault_ = address(d.clPoolManager.vault());
        if (address(d.binPoolManager.vault()) != vault_) revert VaultMismatch(address(d.binPoolManager));
        if (IImmutableState(address(d.clPositionManager)).vault() != d.clPoolManager.vault()) {
            revert VaultMismatch(address(d.clPositionManager));
        }
        if (IImmutableState(address(d.binPositionManager)).vault() != d.clPoolManager.vault()) {
            revert VaultMismatch(address(d.binPositionManager));
        }
        if (d.launchRegistry.vault() != vault_) revert VaultMismatch(address(d.launchRegistry));
        if (address(d.clPositionManager.clPoolManager()) != address(d.clPoolManager)) {
            revert PositionManagerMismatch(address(d.clPositionManager));
        }
        if (address(d.binPositionManager.binPoolManager()) != address(d.binPoolManager)) {
            revert PositionManagerMismatch(address(d.binPositionManager));
        }

        // ---- the guards: right manager, right bitmap, timestamp clock, reservation bound to our factory,
        //      creator tax paying the same Safe with the same caps ----
        _checkHook(address(d.clHook), address(d.clPoolManager), CL_HOOK_BITMAP, address(d.tokenFactory));
        _checkHook(address(d.binHook), address(d.binPoolManager), BIN_HOOK_BITMAP, address(d.tokenFactory));
        if (
            d.clHook.MAX_START_DELAY_SECONDS() != MAX_START_DELAY_SECONDS
                || d.binHook.MAX_START_DELAY_SECONDS() != MAX_START_DELAY_SECONDS
        ) revert HookClockMismatch(address(d.clHook));

        // ---- the lockers: DeepCore's, on these position managers, paying the same Safe, same bounds ----
        if (address(d.clLocker.positionManager()) != address(d.clPositionManager)) revert LockerMismatch(address(d.clLocker));
        if (address(d.binLocker.positionManager()) != address(d.binPositionManager)) {
            revert LockerMismatch(address(d.binLocker));
        }
        if (
            d.clLocker.protocolRecipient() != d.protocolFeeRecipient
                || d.binLocker.protocolRecipient() != d.protocolFeeRecipient
                || d.clLocker.minProtocolBps() != d.binLocker.minProtocolBps()
                || d.clLocker.maxProtocolBps() != d.binLocker.maxProtocolBps()
                || d.clLocker.maxIntegratorBps() != d.binLocker.maxIntegratorBps()
        ) revert LockerMismatch(address(d.binLocker));
        if (d.clLocker.minProtocolBps() < PROTOCOL_LP_FLOOR_BPS) {
            revert LockerFloorTooLow(address(d.clLocker), d.clLocker.minProtocolBps());
        }

        // ---- the creator tax: both guards pay this kit's Safe, with one set of caps ----
        maxTaxBps = d.clHook.MAX_TAX_BPS();
        maxTaxIntegratorBps = d.clHook.MAX_INTEGRATOR_BPS();
        if (
            d.clHook.protocolRecipient() != d.protocolFeeRecipient || d.binHook.protocolRecipient() != d.protocolFeeRecipient
                || d.binHook.MAX_TAX_BPS() != maxTaxBps || d.binHook.MAX_INTEGRATOR_BPS() != maxTaxIntegratorBps
                || d.clHook.MIN_PROTOCOL_BPS() != d.binHook.MIN_PROTOCOL_BPS()
        ) revert HookTaxMismatch(address(d.binHook));

        // ---- bounds ----
        if (d.maxLegs == 0 || d.maxLegs > MAX_LEGS_HARD_CAP) revert InvalidLegCap(d.maxLegs);
        if (d.maxBinsPerLeg == 0 || d.maxBinsPerLeg > d.binLocker.maxBinsPerLock()) revert InvalidBinCap(d.maxBinsPerLeg);
        if (d.launchFeeNoticeSeconds < MIN_FEE_NOTICE_SECONDS || d.launchFeeNoticeSeconds > MAX_FEE_NOTICE_SECONDS) {
            revert InvalidNotice(d.launchFeeNoticeSeconds);
        }
        if (d.initialLaunchFeeWei > d.maxLaunchFeeWei) revert LaunchFeeAboveCap(d.initialLaunchFeeWei, d.maxLaunchFeeWei);

        clPoolManager = d.clPoolManager;
        clHook = d.clHook;
        clPositionManager = d.clPositionManager;
        clLocker = d.clLocker;
        binPoolManager = d.binPoolManager;
        binHook = d.binHook;
        binPositionManager = d.binPositionManager;
        binLocker = d.binLocker;
        tokenFactory = d.tokenFactory;
        launchRegistry = d.launchRegistry;
        clPermit2 = Permit2Forwarder(address(d.clPositionManager)).permit2();
        binPermit2 = Permit2Forwarder(address(d.binPositionManager)).permit2();
        protocolFeeRecipient = d.protocolFeeRecipient;
        launchpadSteward = d.launchpadSteward;
        maxLaunchFeeWei = d.maxLaunchFeeWei;
        launchFeeNoticeSeconds = d.launchFeeNoticeSeconds;
        maxIntegratorLaunchFeeWei = d.maxIntegratorLaunchFeeWei;
        maxLegs = d.maxLegs;
        maxBinsPerLeg = d.maxBinsPerLeg;
        maxIntegratorBps = d.clLocker.maxIntegratorBps();
        _tokenInitCodeHash = d.tokenFactory.launchTokenInitCodeHash();

        _launchFeeWei = d.initialLaunchFeeWei;
        emit LaunchFeeChanged(0, d.initialLaunchFeeWei);

        // The Bin locker pulls a lock's shares from `msg.sender` only, inside a `lock` call this kit makes.
        IBinFungibleToken(address(d.binPositionManager)).approveForAll(address(d.binLocker), true);
    }

    function _checkHook(address hook, address manager, uint16 bitmap, address factory) private view {
        if (hook == address(0)) revert ZeroAddress();
        // Both guards expose `poolManager()`, `CLOCK_MODE()` and `LAUNCH_TOKEN_FACTORY()` with identical
        // ABI shapes, so the CL type is used to read either.
        address hookManager = address(LaunchGuardHook(payable(hook)).poolManager());
        if (hookManager != manager) revert HookPoolManagerMismatch(manager, hookManager);
        uint16 actual = IHooks(hook).getHooksRegistrationBitmap();
        if (actual != bitmap) revert UnexpectedHookBitmap(bitmap, actual);
        if (keccak256(bytes(LaunchGuardHook(payable(hook)).CLOCK_MODE())) != keccak256(bytes(CLOCK_MODE))) {
            revert HookClockMismatch(hook);
        }
        if (address(LaunchGuardHook(payable(hook)).LAUNCH_TOKEN_FACTORY()) != factory) revert HookFactoryMismatch(hook, factory);
    }

    /*//////////////////////////////////////////////////////////////
                              THE ONE CALL
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILaunchpadKitV2
    function createLaunch(LaunchParamsV2 calldata p)
        external
        payable
        override
        nonReentrant
        returns (LaunchResultV2 memory r)
    {
        /* =========================== CHECKS (no external calls) =========================== */
        uint256 n = p.legs.length;
        if (n == 0 || n > maxLegs) revert InvalidLegCount(n, maxLegs);
        if (p.seedSupply == 0 || p.seedSupply > p.totalSupply) revert InvalidSeedSupply(p.seedSupply, p.totalSupply);
        if (p.seedSupply < p.totalSupply && p.allocationRecipient == address(0)) revert AllocationRecipientRequired();
        // The kit can never claim a locker credit or call `claimFees` for itself: naming it strands value forever.
        if (p.creator == address(this) || p.integrator == address(this) || p.allocationRecipient == address(this)) {
            revert InvalidRecipient(address(this));
        }

        uint256 required = _checkFees(p);
        LaunchLegs.Schedule memory s = _resolveSchedule(p.schedule);
        bytes32 salt = keccak256(abi.encode(msg.sender, p.userSalt));
        address token = _predict(salt);

        r.token = token;
        r.startTime = s.startTime;
        r.poolIds = new bytes32[](n);
        r.lockIds = new uint256[](n);
        r.protocolFeeWei = required - p.integratorLaunchFeeWei;
        r.integratorFeeWei = p.integratorLaunchFeeWei;

        PoolKey[] memory keys = new PoolKey[](n);
        uint256[] memory supplies = new uint256[](n);
        {
            uint256 weightSum;
            uint256 remaining = p.seedSupply;
            for (uint256 i; i < n; ++i) {
                LegParams calldata leg = p.legs[i];
                _checkLeg(p, leg, s, token);
                weightSum += leg.weightBps;
                uint256 supply = i + 1 == n ? remaining : p.seedSupply * leg.weightBps / BPS;
                remaining -= supply;
                if (supply == 0) revert EmptyLeg(i);
                if (supply > type(uint128).max) revert LegTooLarge(i, supply);
                supplies[i] = supply;

                bool launchIs0;
                (keys[i], launchIs0) = _buildKey(token, leg);
                bytes32 poolId = PoolId.unwrap(keys[i].toId());
                if (_lockedLaunch[poolId]) revert DuplicateLegPool(poolId);

                /* ------------------------------------------------------------------------------
                   THE FLAG. Written for every leg before this transaction makes its first call of
                   any kind. Mutation-checked: moving it after `initialize` lets V3 stamp V2's fee
                   on the pool, and every launch then reverts `ProtocolFeeNotZero`.
                   ------------------------------------------------------------------------------ */
                _lockedLaunch[poolId] = true;
                _legs[poolId] = LegRecord({launchToken: token, kind: leg.kind, launchTokenIsCurrency0: launchIs0, lockId: 0});
                _legsOfToken[token].push(poolId);
                r.poolIds[i] = poolId;
            }
            if (weightSum != BPS) revert LegWeightsDoNotSum(weightSum);
        }

        address creator = p.creator == address(0) ? msg.sender : p.creator;
        address operator = p.launchOperator == address(0) ? msg.sender : p.launchOperator;
        _launches[token] = LaunchRecordV2({
            creator: creator,
            createdAt: uint64(block.timestamp),
            // n <= MAX_LEGS_HARD_CAP
            // forge-lint: disable-next-line(unsafe-typecast)
            legCount: uint8(n),
            operator: operator,
            startTime: s.startTime,
            tenant: p.tenant,
            integrator: p.integrator
        });
        _credit(protocolFeeRecipient, r.protocolFeeWei);
        _credit(p.integrator, r.integratorFeeWei);

        /* ================================= INTERACTIONS ================================= */
        // One DELEGATECALL into the linked `LaunchLegs`: plan and validate every Bin shape, create the
        // token, open, seed, lock and register every leg, return the remainder, assert the kit holds none.
        // It runs in this contract's context, so every call it makes comes from the kit.
        r.lockIds = LaunchLegs.execute(
            LaunchLegs.Context({
                env: LaunchLegs.Env({
                    clPoolManager: clPoolManager,
                    clHook: clHook,
                    clPositionManager: clPositionManager,
                    clLocker: clLocker,
                    binPoolManager: binPoolManager,
                    binHook: binHook,
                    binPositionManager: binPositionManager,
                    binLocker: binLocker,
                    clPermit2: clPermit2,
                    binPermit2: binPermit2,
                    tokenFactory: tokenFactory,
                    launchRegistry: launchRegistry,
                    maxBinsPerLeg: maxBinsPerLeg
                }),
                token: token,
                salt: salt,
                creator: creator,
                steward: p.launchSteward == address(0) ? msg.sender : p.launchSteward,
                schedule: s,
                tax: _resolveTax(p.tax, p.tenant, s.startTime, creator, p.integrator),
                keys: keys,
                poolIds: r.poolIds,
                supplies: supplies
            }),
            p
        );
        for (uint256 i; i < n; ++i) {
            _legs[r.poolIds[i]].lockId = r.lockIds[i];
        }

        emit LaunchCreated(
            token,
            creator,
            p.tenant,
            msg.sender,
            operator,
            p.totalSupply,
            p.seedSupply,
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8(n),
            s.startTime,
            r.protocolFeeWei,
            p.integrator,
            r.integratorFeeWei
        );

        if (msg.value > required) _sendNative(msg.sender, msg.value - required);
    }

    /*//////////////////////////////////////////////////////////////
                               LEG CHECKS
    //////////////////////////////////////////////////////////////*/

    function _checkLeg(LaunchParamsV2 calldata p, LegParams calldata leg, LaunchLegs.Schedule memory s, address token)
        private
        view
    {
        address quote = leg.quote;
        if (quote == token) revert QuoteIsLaunchToken(quote);
        if (quote != address(0) && quote.code.length == 0) revert QuoteHasNoCode(quote);
        if (leg.kind == LegKind.Bin) {
            if (s.initialFeeBips > LPFeeLibrary.TEN_PERCENT_FEE) revert PresetUnavailableOnBin(p.schedule.preset);
        } else if (s.requiresMaxBuy && leg.maxBuyPerTx == 0) {
            revert MaxBuyRequiredByPreset(p.schedule.preset);
        }
        if (p.tenant != address(0)) {
            TenantConfig storage t = _tenants[p.tenant];
            if (t.restrictQuotes && !tenantQuoteAllowed[p.tenant][quote]) revert QuoteNotAllowed(p.tenant, quote);
            if (leg.kind == LegKind.Bin && (t.allowedBinShapes >> uint8(leg.bin.shape)) & 1 == 0) {
                revert BinShapeNotAllowed(p.tenant, leg.bin.shape);
            }
        }
    }

    /// @dev Fees and tenant policy. Returns the native total the launch owes.
    function _checkFees(LaunchParamsV2 calldata p) private view returns (uint256 required) {
        uint256 integratorFee = p.integratorLaunchFeeWei;
        if (integratorFee > maxIntegratorLaunchFeeWei) revert IntegratorFeeAboveCap(integratorFee, maxIntegratorLaunchFeeWei);
        if (integratorFee != 0 && p.integrator == address(0)) revert IntegratorFeeWithoutIntegrator();
        if (p.tenant != address(0)) {
            TenantConfig storage t = _tenants[p.tenant];
            if (!t.active) revert TenantNotActive(p.tenant);
            if (
                t.integrator != p.integrator || t.integratorBps != p.integratorBps
                    || t.integratorLaunchFeeWei != integratorFee
            ) revert TenantConfigMismatch(p.tenant);
            if ((t.allowedPresets >> uint8(p.schedule.preset)) & 1 == 0) revert PresetNotAllowed(p.tenant, p.schedule.preset);
        }
        required = launchFeeWei() + integratorFee;
        if (msg.value < required) revert InsufficientLaunchFee(required, msg.value);
    }

    function _resolveSchedule(ScheduleParams calldata sp) private view returns (LaunchLegs.Schedule memory s) {
        if (sp.startDelaySeconds > MAX_START_DELAY_SECONDS) revert StartDelayTooLong(sp.startDelaySeconds);
        // block.timestamp + at most 30 days fits uint40 until the year 36812.
        // forge-lint: disable-next-line(unsafe-typecast)
        s.startTime = uint40(block.timestamp + sp.startDelaySeconds);
        if (sp.preset == Preset.Custom) {
            s.initialFeeBips = sp.initialFeeBips;
            s.finalFeeBips = sp.finalFeeBips;
            s.decaySeconds = sp.decaySeconds;
            s.enabled = sp.enabled;
        } else {
            PresetParams memory pp = LaunchPresets.params(sp.preset);
            s.initialFeeBips = pp.initialFeeBips;
            s.finalFeeBips = pp.finalFeeBips;
            s.decaySeconds = pp.windowSeconds;
            s.enabled = pp.enabled;
            s.requiresMaxBuy = pp.requiresMaxBuyPerTx;
        }
    }

    /// @dev Tenant policy and recipient resolution for the creator tax; every bound is the guard's. An
    /// all-zero `t` is "no tax" and the legs skip `configureTax` entirely.
    function _resolveTax(TaxParams calldata t, address tenant, uint40 startTime, address creator, address integrator)
        private
        view
        returns (LaunchTaxModule.TaxConfig memory cfg)
    {
        if (
            t.buyBps == 0 && t.sellBps == 0 && t.taxSeconds == 0 && t.creatorBps == 0 && t.protocolBps == 0
                && t.integratorBps == 0
        ) return cfg;
        if (tenant != address(0)) {
            TenantConfig storage tc = _tenants[tenant];
            if (t.buyBps > tc.maxTaxBps) revert TaxNotAllowed(tenant, t.buyBps);
            if (t.sellBps > tc.maxTaxBps) revert TaxNotAllowed(tenant, t.sellBps);
            if (t.integratorBps != tc.taxIntegratorBps) revert TaxNotAllowed(tenant, t.integratorBps);
        }
        cfg.buyBps = t.buyBps;
        cfg.sellBps = t.sellBps;
        // startTime <= now + 30 days and taxSeconds < 2^32: fits uint40. The guard bounds the absolute expiry.
        // forge-lint: disable-next-line(unsafe-typecast)
        cfg.expiresAt = uint40(uint256(startTime) + t.taxSeconds);
        cfg.creatorBps = t.creatorBps;
        cfg.protocolBps = t.protocolBps;
        cfg.integratorBps = t.integratorBps;
        cfg.creator = t.creatorBps == 0 ? address(0) : creator;
        cfg.integrator = t.integratorBps == 0 ? address(0) : integrator;
    }

    function _buildKey(address token, LegParams calldata leg) private view returns (PoolKey memory key, bool launchIs0) {
        launchIs0 = uint160(token) < uint160(leg.quote);
        (address c0, address c1) = launchIs0 ? (token, leg.quote) : (leg.quote, token);
        key.currency0 = Currency.wrap(c0);
        key.currency1 = Currency.wrap(c1);
        // Never a caller input: a static fee silently discards the guard's fee override.
        key.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        if (leg.kind == LegKind.CL) {
            key.hooks = IHooks(address(clHook));
            key.poolManager = clPoolManager;
            key.parameters = bytes32(uint256(CL_HOOK_BITMAP)).setTickSpacing(leg.cl.tickSpacing);
        } else {
            key.hooks = IHooks(address(binHook));
            key.poolManager = binPoolManager;
            key.parameters = bytes32(uint256(BIN_HOOK_BITMAP)).setBinStep(leg.bin.binStep);
        }
    }

    /*//////////////////////////////////////////////////////////////
                            RECONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILaunchpadKitV2
    /// @dev Operator only, all legs at once (so every pool keeps one opening time), before the guards freeze
    /// at `startTime`. Pins each leg's launch-token side and per-leg buy cap; restates the creator tax (the
    /// guards freeze both together, and an all-zero `tax` clears it). Never touches `_lockedLaunch`.
    function reconfigureLaunch(
        address token,
        PoolKey[] calldata keys,
        ScheduleParams calldata schedule,
        TaxParams calldata tax
    ) external override nonReentrant {
        LaunchRecordV2 storage rec = _launches[token];
        if (rec.creator == address(0)) revert UnknownLaunch(token);
        if (msg.sender != rec.operator) revert NotLaunchOperator(token, msg.sender);

        LaunchLegs.Schedule memory s = _resolveSchedule(schedule);
        address tenant = rec.tenant;
        if (tenant != address(0) && (_tenants[tenant].allowedPresets >> uint8(schedule.preset)) & 1 == 0) {
            revert PresetNotAllowed(tenant, schedule.preset);
        }
        LaunchTaxModule.TaxConfig memory tc = _resolveTax(tax, tenant, s.startTime, rec.creator, rec.integrator);

        // The per-leg work lives in the linked library (kit size); it runs in this context, so every
        // guard call is FROM the kit, the launch owner. It never touches `_lockedLaunch`.
        bytes32[] storage ids = _legsOfToken[token];
        if (keys.length != ids.length) revert LegKeyMismatch(keys.length);
        LaunchLegs.Reconfig memory r = LaunchLegs.Reconfig({schedule: s, tax: tc, preset: schedule.preset});
        for (uint256 i; i < keys.length; ++i) {
            bytes32 poolId = PoolId.unwrap(keys[i].toId());
            if (poolId != ids[i]) revert LegKeyMismatch(i);
            LegRecord storage leg = _legs[poolId];
            if (leg.kind == LegKind.CL) LaunchLegs.reconfigureCL(clHook, keys[i], leg.launchTokenIsCurrency0, r);
            else LaunchLegs.reconfigureBin(binHook, keys[i], leg.launchTokenIsCurrency0, r);
        }
        rec.startTime = s.startTime;
        emit LaunchReconfigured(
            token,
            msg.sender,
            s.startTime,
            s.decaySeconds,
            s.initialFeeBips,
            s.finalFeeBips,
            s.enabled,
            tc.buyBps,
            tc.sellBps,
            tc.expiresAt
        );
    }

    /*//////////////////////////////////////////////////////////////
                       PROTOCOL LAUNCH FEE (OWNER)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILaunchpadKitV2
    /// @notice The owner's only power. `<=` the fee in force applies now and cancels any pending increase;
    /// `>` it is announced and takes effect `launchFeeNoticeSeconds` later, by itself. A new increase
    /// replaces a pending one and restarts the notice, so no announcement can ever shorten the wait.
    function setLaunchFee(uint256 newFeeWei) external override onlyOwner {
        if (newFeeWei > maxLaunchFeeWei) revert LaunchFeeAboveCap(newFeeWei, maxLaunchFeeWei);
        _materialiseLaunchFee();
        uint256 current = _launchFeeWei;
        if (newFeeWei <= current) {
            _clearPending();
            _launchFeeWei = newFeeWei;
            emit LaunchFeeChanged(current, newFeeWei);
        } else {
            uint64 effectiveAt = uint64(block.timestamp) + launchFeeNoticeSeconds;
            _pendingLaunchFeeWei = newFeeWei;
            _pendingLaunchFeeEffectiveAt = effectiveAt;
            emit LaunchFeeIncreaseScheduled(current, newFeeWei, effectiveAt);
        }
    }

    /// @inheritdoc ILaunchpadKitV2
    function cancelPendingLaunchFee() external override onlyOwner {
        _materialiseLaunchFee();
        if (_pendingLaunchFeeEffectiveAt == 0) revert NoPendingLaunchFee();
        _clearPending();
    }

    /// @inheritdoc ILaunchpadKitV2
    /// @notice The protocol launch fee a launch in THIS block pays.
    function launchFeeWei() public view override returns (uint256) {
        uint64 at = _pendingLaunchFeeEffectiveAt;
        if (at != 0 && block.timestamp >= at) return _pendingLaunchFeeWei;
        return _launchFeeWei;
    }

    /// @notice An announced increase that has not taken effect yet. `(0, 0)` when there is none.
    function pendingLaunchFee() external view returns (uint256 feeWei, uint64 effectiveAt) {
        effectiveAt = _pendingLaunchFeeEffectiveAt;
        if (effectiveAt == 0 || block.timestamp >= effectiveAt) return (0, 0);
        feeWei = _pendingLaunchFeeWei;
    }

    /// @notice Disabled. An owner that could renounce would freeze the fee at its current level forever.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Move an ERC-20 that was sent to the kit by mistake to `to`. Owner only.
    /// @dev The kit holds nothing between transactions by design: `createLaunch` asserts it retained no
    /// launch token and no Bin shares before it returns, and native fee credit is accounted per address.
    /// Any ERC-20 balance here is therefore misdirected value with, until now, no path out (acceptance
    /// finding A, 2026-09-18). This cannot reach a launch, a lock, a quote in flight or anyone's credit:
    /// none of those is ever an ERC-20 balance of the kit.
    function rescueERC20(address token, address to) external onlyOwner {
        if (to == address(0)) revert RescueToZero();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToRescue(token);
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    function _materialiseLaunchFee() private {
        uint64 at = _pendingLaunchFeeEffectiveAt;
        if (at != 0 && block.timestamp >= at) {
            uint256 next = _pendingLaunchFeeWei;
            emit LaunchFeeChanged(_launchFeeWei, next);
            _launchFeeWei = next;
            _pendingLaunchFeeWei = 0;
            _pendingLaunchFeeEffectiveAt = 0;
        }
    }

    function _clearPending() private {
        uint64 at = _pendingLaunchFeeEffectiveAt;
        if (at == 0) return;
        emit PendingLaunchFeeCancelled(_pendingLaunchFeeWei, at);
        _pendingLaunchFeeWei = 0;
        _pendingLaunchFeeEffectiveAt = 0;
    }

    /*//////////////////////////////////////////////////////////////
                              FEE PAYOUTS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILaunchpadKitV2
    function claimFees(address to) external override nonReentrant returns (uint256 amount) {
        if (to == address(0)) revert ZeroAddress();
        amount = _debit(msg.sender);
        emit FeesClaimed(msg.sender, to, amount);
        _sendNative(to, amount);
    }

    /// @inheritdoc ILaunchpadKitV2
    /// @notice Permissionless: it can only ever pay the immutable protocol recipient.
    function flushProtocolFees() external override nonReentrant returns (uint256 amount) {
        amount = _debit(protocolFeeRecipient);
        emit FeesClaimed(protocolFeeRecipient, protocolFeeRecipient, amount);
        _sendNative(protocolFeeRecipient, amount);
    }

    function _credit(address account, uint256 amount) private {
        if (amount == 0) return;
        feesOwed[account] += amount;
        totalFeesOwed += amount;
        emit FeesCredited(account, amount);
    }

    function _debit(address account) private returns (uint256 amount) {
        amount = feesOwed[account];
        if (amount == 0) revert NothingToClaim();
        feesOwed[account] = 0;
        totalFeesOwed -= amount;
    }

    function _sendNative(address to, uint256 amount) private {
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed(to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                         TENANTS (SELF-SERVICE)
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILaunchpadKitV2
    /// @notice `msg.sender` IS the tenant. Nobody else - the kit owner included - can write a tenant's policy.
    /// @dev A launch naming this tenant must restate `integrator`, `integratorBps` and
    /// `integratorLaunchFeeWei` exactly, so changing the config can only make a pending launch revert,
    /// never re-price it.
    function setTenantConfig(TenantConfig calldata c) external override {
        if (
            c.integratorLaunchFeeWei > maxIntegratorLaunchFeeWei || c.integratorBps > maxIntegratorBps
                || (
                    c.integrator == address(0)
                        && (c.integratorBps != 0 || c.integratorLaunchFeeWei != 0 || c.taxIntegratorBps != 0)
                ) || c.integrator == address(this) || c.allowedPresets == 0 || c.allowedPresets >= 32
                || c.allowedBinShapes >= 32 || c.maxTaxBps > maxTaxBps || c.taxIntegratorBps > maxTaxIntegratorBps
        ) revert InvalidTenantConfig();
        _tenants[msg.sender] = c;
        emit TenantConfigured(
            msg.sender,
            c.integrator,
            c.integratorBps,
            c.integratorLaunchFeeWei,
            c.allowedPresets,
            c.allowedBinShapes,
            c.restrictQuotes,
            c.active,
            c.maxTaxBps,
            c.taxIntegratorBps
        );
    }

    /// @inheritdoc ILaunchpadKitV2
    function setTenantQuote(address quote, bool allowed) external override {
        tenantQuoteAllowed[msg.sender][quote] = allowed;
        emit TenantQuoteSet(msg.sender, quote, allowed);
    }

    function tenantConfig(address tenant) external view override returns (TenantConfig memory) {
        return _tenants[tenant];
    }

    /*//////////////////////////////////////////////////////////////
                           LAUNCHPAD LISTING
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ILaunchpadKitV2
    /// @notice Permissionless. Lists this kit as `SelfRegistered` with the IMMUTABLE steward, or claims a
    /// listing a stranger created. The caller chooses only the initial metadata, which the steward can edit.
    function registerLaunchpad(LaunchpadMetadata calldata metadata) external override nonReentrant {
        if (launchRegistry.isLaunchpadRegistered(address(this))) {
            launchRegistry.claimLaunchpad(launchpadSteward);
        } else {
            launchRegistry.registerLaunchpad(address(this), launchpadSteward, metadata);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice `DeepCoreProtocolFeeControllerV3`'s question. A plain storage read: no guard, no calls.
    function isLockedLaunch(bytes32 poolId) external view override(ILaunchpadKitV2, ILockedLaunchOracle) returns (bool) {
        return _lockedLaunch[poolId];
    }

    /// @notice `DeepCoreLaunchRegistry`'s attribution probe.
    function launchOriginOf(bytes32 poolId)
        external
        view
        override(ILaunchpadKitV2, IDeepCoreLaunchOrigin)
        returns (address creator)
    {
        address token = _legs[poolId].launchToken;
        return token == address(0) ? address(0) : _launches[token].creator;
    }

    /// @inheritdoc ILaunchpadKitV2
    function predictLaunchToken(address launcher, bytes32 userSalt) external view override returns (address) {
        return _predict(keccak256(abi.encode(launcher, userSalt)));
    }

    /// @notice The key and id `createLaunch` builds for a leg of `token`, and which side the token sorts to.
    function computeLegKey(address token, LegParams calldata leg)
        external
        view
        returns (PoolKey memory key, bytes32 poolId, bool launchTokenIsCurrency0)
    {
        (key, launchTokenIsCurrency0) = _buildKey(token, leg);
        poolId = PoolId.unwrap(key.toId());
    }

    /// @inheritdoc ILaunchpadKitV2
    function getLeg(bytes32 poolId) external view override returns (LegRecord memory) {
        return _legs[poolId];
    }

    /// @inheritdoc ILaunchpadKitV2
    function getLaunch(address token) external view override returns (LaunchRecordV2 memory) {
        return _launches[token];
    }

    /// @inheritdoc ILaunchpadKitV2
    function legsOf(address token) external view override returns (bytes32[] memory) {
        return _legsOfToken[token];
    }

    /// @dev `LaunchTokenFactory` address rule, computed locally so no external call precedes the flags:
    /// CREATE2(factory, keccak256(abi.encode(kit, salt)), launchTokenInitCodeHash).
    function _predict(bytes32 salt) private view returns (address) {
        bytes32 effective = keccak256(abi.encode(address(this), salt));
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(tokenFactory), effective, _tokenInitCodeHash))))
        );
    }
}
