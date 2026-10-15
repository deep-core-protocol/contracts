// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";

/// @title IDeepCoreLiquidityRewards
/// @notice Reward streams paid to in-range concentrated liquidity, measured by a pool's own hook.
/// Design of record: `docs/products/liquidity-rewards.md`.
interface IDeepCoreLiquidityRewards {
    struct RewardsConfig {
        /// @dev 0..3 distinct tokens; `Currency.wrap(address(0))` is native. More can be allowed later, up to 3.
        Currency[] rewardTokens;
        /// @dev A position narrower than this (`tickUpper - tickLower`) is never mirrored and earns nothing.
        /// Fixed for the life of the pool. 0 = every position qualifies.
        uint24 minWidthTicks;
    }

    /// @dev Core's own position key: `sender` is whoever called `modifyLiquidity` (the position manager for
    /// NFT positions, whose salt is `bytes32(tokenId)`).
    struct PositionKey {
        address sender;
        int24 tickLower;
        int24 tickUpper;
        bytes32 salt;
    }

    /// @dev One reward token's stream on one pool.
    struct StreamView {
        Currency token;
        uint256 rateX64; // reward units per second, << 64
        uint64 periodFinish; // effective: includes the seconds with no eligible liquidity up to now
        uint64 lastUpdate;
        uint256 undistributed; // funded, not yet accrued to anybody (as of now)
        uint256 accruedUnpaid; // accrued to positions, not yet claimed or credited (as of now)
        address refundRecipient;
    }

    /*//////////////////////////////////////////////////////////////
                                  EVENTS
    //////////////////////////////////////////////////////////////*/

    event RewardsConfigured(PoolId indexed poolId, address indexed poolOwner, uint24 minWidthTicks, Currency[] rewardTokens);
    event RewardTokenAllowed(PoolId indexed poolId, Currency indexed token, uint8 index);
    event PoolOwnershipTransferStarted(PoolId indexed poolId, address indexed previousOwner, address indexed newOwner);
    event PoolOwnershipTransferred(PoolId indexed poolId, address indexed previousOwner, address indexed newOwner);
    event StreamStarted(
        PoolId indexed poolId,
        Currency indexed token,
        uint256 amount,
        uint256 rateX64,
        uint64 periodFinish,
        address refundRecipient
    );
    event StreamExtended(PoolId indexed poolId, Currency indexed token, uint256 amount, uint256 rateX64, uint64 periodFinish);
    event StreamToppedUp(PoolId indexed poolId, Currency indexed token, address indexed from, uint256 amount, uint256 rateX64);
    event RewardsClaimed(PoolId indexed poolId, bytes32 indexed positionId, address indexed to, Currency token, uint256 amount);
    event RewardsCredited(
        PoolId indexed poolId, bytes32 indexed positionId, address indexed recipient, Currency token, uint256 amount
    );
    event CreditClaimed(address indexed account, Currency indexed token, address to, uint256 amount);
    event Recycled(PoolId indexed poolId, bytes32 indexed positionId, Currency token, uint256 amount);
    event Reclaimed(PoolId indexed poolId, Currency indexed token, address indexed refundRecipient, uint256 amount);
    event ProtocolFeeTaken(PoolId indexed poolId, Currency indexed token, uint256 amount);
    event ProtocolFeesFlushed(Currency indexed token, address indexed to, uint256 amount);
    event Swept(Currency indexed token, address indexed to, uint256 amount);
    event ProtocolFeeChanged(uint16 previousBps, uint16 newBps);
    event ProtocolFeeIncreaseScheduled(uint16 currentBps, uint16 newBps, uint64 effectiveAt);
    event PendingProtocolFeeCancelled(uint16 cancelledBps, uint64 effectiveAt);

    /*//////////////////////////////////////////////////////////////
                                  ERRORS
    //////////////////////////////////////////////////////////////*/

    error PoolNotConfigured();
    error PoolAlreadyConfigured();
    error PoolNotInitialized();
    error WrongHook();
    error WrongPoolManager();
    error NotPoolOwner();
    error NotPendingPoolOwner();
    error TooManyRewardTokens();
    error DuplicateRewardToken();
    error TokenNotAllowed();
    error StreamRunning();
    error NoStream();
    error DurationOutOfRange();
    error RateWouldFall();
    error FinishWouldMoveIn();
    error StreamEndsTooSoon();
    error ZeroAmount();
    error AmountTooLarge();
    error ZeroAddress();
    error NotPositionOwner();
    error NothingToClaim();
    error NothingToRecycle();
    error NothingToReclaim();
    error NothingToFlush();
    error NothingToSweep();
    error PositionStillActive();
    error RecycleTooSoon(uint64 earliest);
    error ReclaimTooSoon(uint64 earliest);
    error InvalidRefundRecipient();
    error NativeNotAccepted();
    error NativeAmountMismatch();
    error MinWidthTooLarge();
    error InvalidDelay();
    error InvalidNotice(uint32 noticeSeconds);
    error FeeAboveCap(uint256 feeBps, uint256 capBps);
    error NoPendingFee();
    error RenounceDisabled();

    /*//////////////////////////////////////////////////////////////
                                FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function configureRewards(PoolKey calldata key, RewardsConfig calldata cfg) external;

    function allowRewardToken(PoolKey calldata key, Currency token) external;
    function transferPoolOwnership(PoolId id, address newOwner) external;
    function acceptPoolOwnership(PoolId id) external;
    function startStream(PoolKey calldata key, Currency token, uint256 amount, uint32 duration, address refundRecipient)
        external
        payable;
    function extendStream(PoolKey calldata key, Currency token, uint256 amount, uint64 newFinish) external payable;

    function topUp(PoolKey calldata key, Currency token, uint256 amount) external payable;
    function recycle(PoolId id, PositionKey calldata pos) external;
    function reclaim(PoolId id, Currency token) external returns (uint256);
    function flushProtocolFees(Currency token) external returns (uint256);
    function sweep(Currency token) external returns (uint256);

    function claim(PoolId id, PositionKey calldata pos, address to) external returns (uint256[] memory);
    function claimCredit(Currency token, address to) external returns (uint256);

    function earned(PoolId id, PositionKey calldata pos) external view returns (uint256[] memory);
    function streamOf(PoolId id, Currency token)
        external
        view
        returns (uint256 rateX64, uint64 periodFinish, uint256 undistributed, address refundRecipient);
    function streams(PoolId id) external view returns (StreamView[] memory);
    function eligibleLiquidity(PoolId id) external view returns (uint128);
    function zeroLiquiditySince(PoolId id) external view returns (uint64);
}
