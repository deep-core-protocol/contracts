/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {LaunchMetadata, LaunchpadMetadata} from "deepcore-registry/src/IDeepCoreLaunchRegistry.sol";

import {Preset} from "../libraries/LaunchPresets.sol";

/*//////////////////////////////////////////////////////////////
                            PARAMETERS
//////////////////////////////////////////////////////////////*/

/// @notice Which pool type a leg opens. Every leg is LOCKED: CL in `DeepCoreLPLocker`, Bin in `DeepCoreBinLPLocker`.
enum LegKind {
    CL,
    Bin
}

/// @notice How a Bin leg's launch-token supply is spread over its bins.
/// @dev `Custom` validates caller arrays against rules R1-R6 (docs/kit-v2-integration.md, "Kit v2
/// (implemented)"). Every named shape is computed by the kit and passes the same validator.
enum BinShape {
    Custom,
    Flat,
    Linear,
    Exponential,
    Stepped
}

/// @notice A single-sided concentrated-liquidity range holding only the launch token.
struct CLLegParams {
    int24 tickSpacing;
    /// @dev Opening price, currency1 per currency0 after sorting, Q64.96.
    uint160 sqrtPriceX96;
    /// @dev Must sit strictly on the launch token's side of the tick core reports after `initialize`:
    /// launch token = currency0 needs `tickLower > tick`; launch token = currency1 needs `tickUpper <= tick`.
    int24 tickLower;
    int24 tickUpper;
}

/// @notice A single-sided Bin distribution holding only the launch token.
/// @dev Offsets and weights are in FILL ORDER: offset 1 is the bin adjacent to the active bin on the
/// launch token's side, and buyers consume bins in increasing offset. The kit maps them to above-active
/// (launch token = currency0) or below-active (currency1) itself, so a caller cannot get the side wrong.
struct BinLegParams {
    uint16 binStep;
    uint24 activeId;
    BinShape shape;
    /// @dev Named shapes only: number of bins, 1..`maxBinsPerLeg`.
    uint16 binCount;
    /// @dev `Custom` only: distances from the active bin, strictly increasing, each >= 1.
    uint24[] offsets;
    /// @dev `Custom` only: 1e18-precision fractions of the leg's supply, each > 0, summing to exactly 1e18.
    uint64[] weights;
    /// @dev `Custom` only: the first `floorBins` offsets must be exactly 1, 2, ..., floorBins (no gap near the
    /// opening price). Gaps are permitted only after it - that is the declaration a stepped shape makes.
    uint16 floorBins;
}

/// @notice One pool of a launch.
struct LegParams {
    LegKind kind;
    /// @dev `address(0)` is the chain's native asset. Any ERC-20 with code, including Robinhood stock tokens.
    address quote;
    /// @dev Share of `seedSupply`, in bps. Legs sum to exactly 10_000; the last leg takes the rounding remainder.
    uint16 weightBps;
    /// @dev Per-transaction buy cap in quote units, forwarded to the guard. 0 disables it.
    uint128 maxBuyPerTx;
    CLLegParams cl;
    BinLegParams bin;
}

/// @notice The launch-guard schedule, shared by every leg so all pools open together.
struct ScheduleParams {
    Preset preset;
    /// @dev `Preset.Custom` only.
    uint24 initialFeeBips;
    /// @dev `Preset.Custom` only.
    uint24 finalFeeBips;
    /// @dev `Preset.Custom` only. Seconds, inside the guard's [MIN_DECAY_SECONDS, MAX_DECAY_SECONDS].
    uint32 decaySeconds;
    /// @dev `Preset.Custom` only.
    bool enabled;
    /// @dev Trading opens `startDelaySeconds` after the launch transaction lands (block.timestamp).
    uint32 startDelaySeconds;
}

/// @notice The creator tax (Creator Economy): a buy rate and a sell rate taken by the launch guard on every
/// swap's unspecified side until `startTime + taxSeconds`, split creator / protocol / integrator.
/// @dev All zero = no tax. Everything else is validated by the GUARD (`LaunchTaxModule`): rates <= 10%,
/// `taxSeconds` such that the expiry is within 180 days of the launch transaction, buckets summing to 10_000
/// with protocol in [10%, 50%] and integrator <= 20%. The kit only resolves recipients (`creator`, `integrator`)
/// and applies tenant policy (`TenantConfig.maxTaxBps`, `TenantConfig.taxIntegratorBps`).
struct TaxParams {
    uint16 buyBps;
    uint16 sellBps;
    /// @dev Seconds of tax counted from `startTime` (trading open). The guard caps the absolute expiry.
    uint32 taxSeconds;
    uint16 creatorBps;
    uint16 protocolBps;
    uint16 integratorBps;
}

/// @notice Everything one `createLaunch` decides.
struct LaunchParamsV2 {
    /*------------------------------- the token -------------------------------*/
    string name;
    string symbol;
    string metadataURI;
    /// @dev Folded with `msg.sender` into the factory salt, so launchers cannot squat each other's addresses.
    bytes32 userSalt;
    uint256 totalSupply;
    /// @dev <= totalSupply. The rest, plus seeding rounding dust, goes to `allocationRecipient`.
    uint256 seedSupply;
    /// @dev Required iff `seedSupply < totalSupply`. When zero, seeding dust (a few wei) goes to `creator`.
    address allocationRecipient;
    /*------------------------------- the people ------------------------------*/
    /// @dev Lock creator and registry creator. `address(0)` means `msg.sender`.
    address creator;
    /// @dev May reconfigure the schedule until trading opens. `address(0)` means `msg.sender`.
    address launchOperator;
    /// @dev Registry steward of every leg's launch record. `address(0)` means `msg.sender`.
    address launchSteward;
    /*------------------------------- the tenant ------------------------------*/
    /// @dev `address(0)` for a direct launch. Otherwise a tenant with an active `TenantConfig`, whose values
    /// below MUST equal the stored ones (a tenant changing its config cannot re-price a pending launch).
    address tenant;
    /// @dev The tenant's fee wallet: the LP-lock integrator AND the integrator launch-fee payee.
    address integrator;
    uint16 integratorBps;
    uint256 integratorLaunchFeeWei;
    /*------------------------------- the split -------------------------------*/
    /// @dev `creatorBps + integratorBps + protocolBps == 10_000`, validated by both lockers' immutable bounds.
    uint16 creatorBps;
    uint16 protocolBps;
    /*------------------------------- the pools -------------------------------*/
    ScheduleParams schedule;
    /// @dev Applied to every leg; the creator bucket pays `creator`, the integrator bucket pays `integrator`.
    TaxParams tax;
    LegParams[] legs;
    /// @dev Written to every leg's `DeepCoreLaunchRegistry` record.
    LaunchMetadata listing;
}

/// @notice What a launch turned into.
struct LaunchResultV2 {
    address token;
    bytes32[] poolIds;
    /// @dev CL legs: the position token id held by `DeepCoreLPLocker`. Bin legs: the `DeepCoreBinLPLocker` lock id.
    uint256[] lockIds;
    uint40 startTime;
    uint256 protocolFeeWei;
    uint256 integratorFeeWei;
}

/// @notice One locked leg, keyed by pool id. `launchToken == address(0)` means the kit did not create it.
/// @dev Slot 0: launchToken | kind | launchTokenIsCurrency0. Slot 1: lockId.
struct LegRecord {
    address launchToken;
    LegKind kind;
    bool launchTokenIsCurrency0;
    uint256 lockId;
}

/// @notice One launch, keyed by launch token.
/// @dev Slot 0: creator | createdAt(uint64) | legCount(uint8). Slot 1: operator | startTime(uint40). Slot 2: tenant.
/// Slot 3: integrator (the tax's integrator bucket recipient, kept so `reconfigureLaunch` can restate the tax).
struct LaunchRecordV2 {
    address creator;
    uint64 createdAt;
    uint8 legCount;
    address operator;
    uint40 startTime;
    address tenant;
    address integrator;
}

/// @notice A tenant launchpad's on-chain policy, written by the tenant itself (`msg.sender`).
/// @dev Self-service: nobody but the tenant can write it, and the kit owner has no power over it.
struct TenantConfig {
    address integrator;
    uint16 integratorBps;
    uint96 integratorLaunchFeeWei;
    /// @dev Bit i allows `Preset(i)`. Non-zero.
    uint8 allowedPresets;
    /// @dev Bit i allows `BinShape(i)`. Zero forbids Bin legs.
    uint8 allowedBinShapes;
    /// @dev When true every leg's quote must be on the tenant's quote allowlist.
    bool restrictQuotes;
    bool active;
    /// @dev Highest `buyBps` / `sellBps` a launch through this tenant may set. 0 forbids a creator tax.
    uint16 maxTaxBps;
    /// @dev The tax's integrator bucket a launch through this tenant MUST restate (<= the guard's 20% cap).
    uint16 taxIntegratorBps;
}

/*//////////////////////////////////////////////////////////////
                             INTERFACE
//////////////////////////////////////////////////////////////*/

/// @title ILaunchpadKitV2
/// @notice One-transaction, locked, multi-pool launches on the shared DeepCore core.
interface ILaunchpadKitV2 {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event LaunchCreated(
        address indexed token,
        address indexed creator,
        address indexed tenant,
        address launcher,
        address operator,
        uint256 totalSupply,
        uint256 seedSupply,
        uint8 legCount,
        uint40 startTime,
        uint256 protocolFeeWei,
        address integrator,
        uint256 integratorFeeWei
    );

    /// @param launchTokenSeeded Launch-token units actually moved into the pool (measured).
    event LaunchLegCreated(
        address indexed token,
        bytes32 indexed poolId,
        address indexed quote,
        LegKind kind,
        uint256 lockId,
        uint256 launchTokenSeeded,
        uint16 weightBps
    );

    event LaunchReconfigured(
        address indexed token,
        address indexed operator,
        uint40 startTime,
        uint32 decaySeconds,
        uint24 initialFeeBips,
        uint24 finalFeeBips,
        bool enabled,
        uint16 taxBuyBps,
        uint16 taxSellBps,
        uint40 taxExpiresAt
    );

    /// @notice An increase was announced. It becomes the launch fee at `effectiveAt`, automatically.
    event LaunchFeeIncreaseScheduled(uint256 currentWei, uint256 newWei, uint64 effectiveAt);
    /// @notice The stored fee changed now: a decrease (immediate), or a matured increase being materialised.
    event LaunchFeeChanged(uint256 previousWei, uint256 newWei);
    event PendingLaunchFeeCancelled(uint256 cancelledWei, uint64 effectiveAt);
    /// @notice An ERC-20 sent to the kit by mistake was moved out by the owner.
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    event FeesCredited(address indexed account, uint256 amount);
    event FeesClaimed(address indexed account, address indexed to, uint256 amount);

    event TenantConfigured(
        address indexed tenant,
        address indexed integrator,
        uint16 integratorBps,
        uint96 integratorLaunchFeeWei,
        uint8 allowedPresets,
        uint8 allowedBinShapes,
        bool restrictQuotes,
        bool active,
        uint16 maxTaxBps,
        uint16 taxIntegratorBps
    );
    event TenantQuoteSet(address indexed tenant, address indexed quote, bool allowed);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    // ---- construction ----
    error ZeroAddress();
    error NoCode(address account);
    error HookPoolManagerMismatch(address expected, address actual);
    error UnexpectedHookBitmap(uint16 expected, uint16 actual);
    error HookClockMismatch(address hook);
    error HookFactoryMismatch(address hook, address factory);
    /// @notice A guard's creator-tax `protocolRecipient` is not the kit's `protocolFeeRecipient`, or its caps differ.
    error HookTaxMismatch(address hook);
    error PositionManagerMismatch(address positionManager);
    error VaultMismatch(address component);
    error LockerMismatch(address locker);
    error LockerFloorTooLow(address locker, uint16 minProtocolBps);
    error InvalidLegCap(uint8 maxLegs);
    error InvalidBinCap(uint16 maxBinsPerLeg);
    error InvalidNotice(uint32 noticeSeconds);
    error LaunchFeeAboveCap(uint256 feeWei, uint256 capWei);
    error RenounceDisabled();
    error RescueToZero();
    error NothingToRescue(address token);

    // ---- launch shape ----
    error InvalidLegCount(uint256 count, uint8 maxLegs);
    error LegWeightsDoNotSum(uint256 sum);
    error EmptyLeg(uint256 index);
    error LegTooLarge(uint256 index, uint256 amount);
    error InvalidSeedSupply(uint256 seedSupply, uint256 totalSupply);
    error AllocationRecipientRequired();
    /// @notice The kit itself was named as creator, integrator or allocation recipient: it could never claim.
    error InvalidRecipient(address recipient);
    error QuoteHasNoCode(address quote);
    error QuoteIsLaunchToken(address quote);
    error DuplicateLegPool(bytes32 poolId);
    error StartDelayTooLong(uint32 delaySeconds);
    error MaxBuyRequiredByPreset(Preset preset);
    error PresetUnavailableOnBin(Preset preset);
    error RangeNotSingleSided(uint256 index, int24 tickLower, int24 tickUpper, int24 currentTick);
    error SeedProducesNoLiquidity(uint256 index);
    error BinIdOutOfRange(uint256 index, uint24 activeId, uint24 offset);
    error ActiveIdMoved(uint256 index, uint24 expected, uint24 actual);

    // ---- fees ----
    error InsufficientLaunchFee(uint256 required, uint256 sent);
    error IntegratorFeeAboveCap(uint256 feeWei, uint256 capWei);
    error IntegratorFeeWithoutIntegrator();
    error NothingToClaim();
    error NoPendingLaunchFee();
    error NativeTransferFailed(address to, uint256 amount);

    // ---- tenants ----
    error TenantNotActive(address tenant);
    error TenantConfigMismatch(address tenant);
    error PresetNotAllowed(address tenant, Preset preset);
    error BinShapeNotAllowed(address tenant, BinShape shape);
    error QuoteNotAllowed(address tenant, address quote);
    error InvalidTenantConfig();
    /// @notice A tenant launch's tax rate is above the tenant's `maxTaxBps`, or its integrator bucket differs.
    error TaxNotAllowed(address tenant, uint16 bps);

    // ---- atomicity / oracle ----
    error LaunchTokenAddressMismatch(address predicted, address created);
    error LaunchTokenSupplyMismatch(uint256 expected, uint256 received);
    error LockNotRecorded(uint256 index, uint256 lockId);
    error ProtocolFeeNotZero(bytes32 poolId, uint24 protocolFee);
    error KitRetainedLaunchToken(uint256 balance);
    error KitRetainedBinShares(uint256 index, uint24 binId, uint256 balance);

    // ---- reconfiguration ----
    error UnknownLaunch(address token);
    error NotLaunchOperator(address token, address caller);
    error LegKeyMismatch(uint256 index);

    /*//////////////////////////////////////////////////////////////
                                METHODS
    //////////////////////////////////////////////////////////////*/

    function createLaunch(LaunchParamsV2 calldata p) external payable returns (LaunchResultV2 memory result);

    function reconfigureLaunch(address token, PoolKey[] calldata keys, ScheduleParams calldata schedule, TaxParams calldata tax)
        external;

    function setLaunchFee(uint256 newFeeWei) external;
    function rescueERC20(address token, address to) external;

    function cancelPendingLaunchFee() external;

    function claimFees(address to) external returns (uint256 amount);

    function flushProtocolFees() external returns (uint256 amount);

    function setTenantConfig(TenantConfig calldata config) external;

    function setTenantQuote(address quote, bool allowed) external;

    function tenantConfig(address tenant) external view returns (TenantConfig memory);

    function tenantQuoteAllowed(address tenant, address quote) external view returns (bool);

    function registerLaunchpad(LaunchpadMetadata calldata metadata) external;

    function isLockedLaunch(bytes32 poolId) external view returns (bool);

    function launchOriginOf(bytes32 poolId) external view returns (address creator);

    function launchFeeWei() external view returns (uint256);

    function predictLaunchToken(address launcher, bytes32 userSalt) external view returns (address);

    function getLeg(bytes32 poolId) external view returns (LegRecord memory);

    function getLaunch(address token) external view returns (LaunchRecordV2 memory);

    function legsOf(address token) external view returns (bytes32[] memory);
}
