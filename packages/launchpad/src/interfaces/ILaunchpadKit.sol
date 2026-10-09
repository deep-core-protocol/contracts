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
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {DeepCoreMetadata} from "deepcore-registry/src/IDeepCoreRegistry.sol";

import {Preset} from "../libraries/LaunchPresets.sol";

/*//////////////////////////////////////////////////////////////
                            PARAMETERS
//////////////////////////////////////////////////////////////*/

/// @notice Optional initial liquidity for the new pool.
/// @dev Seeding is skipped entirely when both amounts are zero.
struct SeedParams {
    /// @dev Lower tick of the seeded range. Must be a multiple of `tickSpacing`.
    int24 tickLower;
    /// @dev Upper tick of the seeded range. Must be a multiple of `tickSpacing`.
    int24 tickUpper;
    /// @dev Maximum launch-token units to spend. Pulled from `msg.sender` in full; whatever the
    /// mint does not consume is returned in the same transaction.
    uint128 launchTokenAmount;
    /// @dev Maximum quote-currency units to spend. Same pull-and-refund behaviour. When the quote
    /// currency is native, this must equal `msg.value`.
    uint128 quoteTokenAmount;
    /// @dev Recipient of the position NFT. `address(0)` means `msg.sender`.
    address positionRecipient;
    /// @dev Deadline forwarded to the position manager. `0` means `block.timestamp`.
    uint256 deadline;
}

/// @notice Optional registry listing for the hook backing this launch.
/// @dev The hook is shared across every launch it backs, so it is listed at most once. When
/// `register` is true and the hook is already listed, this is a no-op rather than a revert -
/// otherwise the second launch on a given hook could never be created.
struct HookListingParams {
    bool register;
    /// @dev Who ends up able to edit the listing's metadata. `address(0)` means `msg.sender`.
    /// The kit registers and then immediately hands the stewardship over, so the kit itself is
    /// never left holding an editing right over somebody else's listing.
    address steward;
    DeepCoreMetadata metadata;
}

/// @notice Everything a launchpad has to decide, in one struct.
struct LaunchParams {
    /*------------------------------- the pair -------------------------------*/
    /// @dev The token being launched. Must be a contract; the native asset cannot be launched.
    address launchToken;
    /// @dev The currency it trades against. `address(0)` is the chain's native asset.
    address quoteToken;
    /*------------------------------ pool shape ------------------------------*/
    int24 tickSpacing;
    /// @dev Opening price, as sqrt(price) in Q64.96, where "price" is currency1 per currency0
    /// AFTER sorting. Use the SDK's `sqrtPriceForLaunch` rather than computing this by hand: get
    /// it wrong and the pool opens at a price nobody wants, which cannot be undone.
    uint160 sqrtPriceX96;
    /*--------------------------- launch schedule ----------------------------*/
    Preset preset;
    /// @dev Ignored unless `preset == Preset.Custom`.
    uint24 initialFeeBips;
    /// @dev Ignored unless `preset == Preset.Custom`.
    uint24 finalFeeBips;
    /// @dev Ignored unless `preset == Preset.Custom`. In SECONDS of `block.timestamp`, inside the
    /// hook's [`MIN_DECAY_SECONDS`, `MAX_DECAY_SECONDS`] = [60 s, 30 days].
    uint32 decaySeconds;
    /// @dev Ignored unless `preset == Preset.Custom`.
    bool enabled;
    /// @dev How long after THIS TRANSACTION LANDS trading opens, in seconds of `block.timestamp`.
    /// Relative rather than absolute so a transaction that sits in the mempool cannot land with a
    /// `startTime` already in the past. At most the hook's `MAX_START_DELAY_SECONDS` (30 days).
    uint32 startDelaySeconds;
    /// @dev Per-TRANSACTION cap on a buy's input amount, in quote-currency units. `0` disables it.
    /// This is not, and cannot be, a per-wallet cap - see `LaunchPresets`.
    uint128 maxBuyPerTx;
    /*------------------------------ governance ------------------------------*/
    /// @dev May reconfigure the launch through this kit until trading opens. `address(0)` means
    /// `msg.sender`. Not transferable and not renounceable, matching the hook.
    address launchOperator;
    /*------------------------------- optional -------------------------------*/
    SeedParams seed;
    HookListingParams listing;
}

/// @notice What a launch turned into.
struct LaunchResult {
    PoolKey key;
    PoolId poolId;
    /// @dev First `block.timestamp` at which swaps are permitted.
    uint40 startTime;
    /// @dev Decay window actually written to the hook, in seconds.
    uint32 decaySeconds;
    /// @dev `0` when nothing was seeded.
    uint256 positionTokenId;
    /// @dev Liquidity minted into `positionTokenId`.
    uint128 liquiditySeeded;
    /// @dev Whether the launch token sorted to `currency0`. Derived, never caller-supplied.
    bool launchTokenIsCurrency0;
}

/// @notice What the kit recorded about a launch it created.
struct LaunchRecord {
    /// @dev `address(0)` means this kit did not create the pool.
    address operator;
    bool launchTokenIsCurrency0;
    /// @dev Kept so `reconfigureLaunch` cannot silently flip which side is the launch token.
    address launchToken;
}

/*//////////////////////////////////////////////////////////////
                             INTERFACE
//////////////////////////////////////////////////////////////*/

/// @title ILaunchpadKit
/// @notice One-call launch creation on DeepCore Protocol.
interface ILaunchpadKit {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event LaunchCreated(
        PoolId indexed poolId,
        address indexed launchToken,
        address indexed operator,
        address quoteToken,
        uint40 startTime,
        uint32 decaySeconds,
        uint24 initialFeeBips,
        uint24 finalFeeBips,
        uint128 maxBuyPerTx,
        bool launchTokenIsCurrency0,
        Preset preset
    );

    event LaunchSeeded(
        PoolId indexed poolId,
        uint256 indexed positionTokenId,
        address indexed positionRecipient,
        uint128 liquidity,
        uint256 amount0Spent,
        uint256 amount1Spent
    );

    event LaunchReconfigured(
        PoolId indexed poolId,
        address indexed operator,
        uint40 startTime,
        uint32 decaySeconds,
        uint24 initialFeeBips,
        uint24 finalFeeBips,
        uint128 maxBuyPerTx,
        bool enabled
    );

    event HookListed(address indexed hook, address indexed steward);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    /// @notice The launch token and the quote currency are the same asset.
    error IdenticalCurrencies(address currency);
    /// @notice The native asset was named as the launch token. Only the quote side may be native.
    error LaunchTokenCannotBeNative();
    /// @notice `launchToken` has no code, so it cannot be an ERC-20.
    error LaunchTokenHasNoCode(address launchToken);
    /// @notice This kit has already created a launch for this pool id.
    error LaunchAlreadyExists(PoolId poolId);
    /// @notice The pool id is not one this kit created.
    error UnknownLaunch(PoolId poolId);
    /// @notice Caller is not the recorded operator of this launch.
    error NotLaunchOperator(PoolId poolId, address caller);
    /// @notice The chosen preset is incoherent without a per-transaction cap.
    error MaxBuyRequiredByPreset(Preset preset);
    /// @notice `startDelaySeconds` is above the hook's `MAX_START_DELAY_SECONDS`.
    error StartDelayTooLong(uint256 delaySeconds);
    /// @notice `msg.value` does not match the native amount the seed declares.
    error NativeValueMismatch(uint256 expected, uint256 actual);
    /// @notice Native value was sent for a launch that involves no native currency.
    error UnexpectedNativeValue(uint256 value);
    /// @notice The seed's amounts and tick range produce zero liquidity.
    error SeedProducesNoLiquidity();
    /// @notice A tick range that is empty or the wrong way round.
    error InvalidTickRange(int24 tickLower, int24 tickUpper);
    /// @notice The kit was deployed without a registry but a listing was requested.
    error RegistryNotConfigured();
    /// @notice The hook does not report the bitmap this kit is built to drive.
    error UnexpectedHookBitmap(uint16 expected, uint16 actual);
    /// @notice The hook serves a different pool manager than the one this kit was given.
    error HookPoolManagerMismatch(address expected, address actual);
    /// @notice The hook does not report `CLOCK_MODE() == "mode=timestamp"`. A block-numbered hook
    /// has no `CLOCK_MODE()` at all; that case reverts with an empty `hookClockMode`.
    error HookClockMismatch(string hookClockMode);

    /*//////////////////////////////////////////////////////////////
                                METHODS
    //////////////////////////////////////////////////////////////*/

    function createLaunch(LaunchParams calldata params) external payable returns (LaunchResult memory result);

    function computePoolKey(address launchToken, address quoteToken, int24 tickSpacing)
        external
        view
        returns (PoolKey memory key, PoolId poolId, bool launchTokenIsCurrency0);

    function getLaunchRecord(PoolId poolId) external view returns (LaunchRecord memory);
}
