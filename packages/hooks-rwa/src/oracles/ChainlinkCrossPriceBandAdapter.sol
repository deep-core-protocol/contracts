/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

import {IPriceBandOracle} from "../interfaces/IPriceBandOracle.sol";
import {AggregatorV3Interface} from "./ChainlinkPriceBandAdapter.sol";

/// @title ChainlinkCrossPriceBandAdapter
/// @notice An `IPriceBandOracle` for a pool whose QUOTE is not worth one dollar: a stock token
///         paired with the chain's native currency (or its wrapped form, or any other priced asset).
///         The reference is the ratio of two Chainlink feeds that share a denominator:
///
///             base / quote  =  (base / USD)  /  (quote / USD)
///
/// @dev WHY THIS IS A SEPARATE CONTRACT. `ChainlinkPriceBandAdapter` reads ONE feed and treats the
/// quote token as worth exactly one unit of the feed's denominator. That is right for a stock priced
/// in dollars and paired with a dollar stablecoin. Point it at a stock/USD feed for a pool quoted in
/// the native currency and the band is wrong by the native currency's whole price: `beforeInitialize`
/// refuses every honest birth price and the pool can never trade. That adapter is accepted and is
/// left untouched; this one adds the second leg.
///
/// ############################ THE TWO LEGS, AND WHY BOTH ARE CHECKED ############################
///
/// A cross rate is only as fresh as its STALER leg and only as true as its WORSE leg. So:
///
///   - each feed has its own heartbeat, and `refresh` reverts if EITHER round is older than its own;
///   - `referencePrice` reports the OLDER of the two round timestamps as `updatedAt`, so the consumer's
///     staleness window is measured against the leg that has waited longest;
///   - the cached price is served only while BOTH legs are still inside their heartbeats. A stock feed
///     that prints once a day and a native feed that prints every few minutes do not share a clock,
///     and using one clock for both would either serve a dead native price or starve a live one;
///   - each answer must be positive, complete, in range, and reported with the decimals configured.
///
/// THE NATIVE LEG MOVES AROUND THE CLOCK. A stock/stable reference only changes while the stock's
/// market prints. A stock/native reference changes whenever the native currency does, including all
/// weekend. Refresh it more often than a one-feed pool (`refresh` is permissionless and bounded), and
/// size the band with BOTH feeds' deviation thresholds in mind: two feeds that are each allowed to be
/// half a percent stale can together be a full percent away from the truth.
///
/// ############################ THE UNIT ############################
///
/// As everywhere in this package the result is in the POOL's units:
/// `sqrt(currency1 per currency0, each in its own smallest unit) * 2**96`. With
///
///     P = baseAnswer / 10**baseFeedDecimals      (dollars per whole base token)
///     Q = quoteAnswer / 10**quoteFeedDecimals    (dollars per whole quote token)
///
/// one whole base token is worth P / Q whole quote tokens, so in smallest units
///
///     quote per base = (baseAnswer * 10**quoteFeedDecimals * 10**quoteDecimals)
///                      / (quoteAnswer * 10**baseFeedDecimals * 10**baseDecimals)
///
/// and the fraction is inverted when the base token is currency1. The native currency is
/// `address(0)` in a pool key and therefore ALWAYS currency0, so a stock/native pool has
/// `baseIsCurrency0 == false`; getting that backwards inverts the band (see `IPriceBandOracle`).
///
/// BOUNDS. Both answers are capped at 1e36 and every decimals value at 18, so numerator and
/// denominator each stay below 1e72 and cannot overflow a word. A feed or a token outside those
/// bounds is refused at `configureFeed` rather than mispriced.
///
/// ############################ WHAT THE OWNER CAN AND CANNOT DO ############################
///
/// The owner (the Safe, per the ownership table) chooses which two feeds price a pool and can remove
/// them. It cannot write a price: every reference is computed from the two aggregators' own answers
/// in `refresh`, which anyone may call. It cannot renounce. It can rescue an ERC-20 sent here by
/// mistake; this contract never holds anything, has no `receive` and no `fallback`.
///
/// Nothing here is advice about what band width or feed pair is appropriate for any instrument.
contract ChainlinkCrossPriceBandAdapter is IPriceBandOracle, Ownable2Step {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error SameAggregator(address aggregator);
    error FeedNotConfigured(PoolId poolId);
    error InvalidDecimals(uint8 baseDecimals, uint8 quoteDecimals);
    error InvalidFeedDecimals(uint8 feedDecimals);
    error InvalidHeartbeat(uint32 heartbeat);
    error InvalidGracePeriod(address uptimeFeed, uint32 gracePeriod);
    error NonPositiveAnswer(address aggregator, int256 answer);
    error IncompleteRound(address aggregator, uint80 roundId);
    error AnswerTooOld(address aggregator, uint256 roundUpdatedAt, uint32 heartbeat, uint256 nowTs);
    error AnswerOutOfRange(address aggregator, uint256 answer);
    error DecimalsChanged(address aggregator, uint8 configured, uint8 current);
    error SequencerDown();
    error SequencerGracePeriod(uint256 upSince, uint32 gracePeriod, uint256 nowTs);
    error SequencerFeedUnreadable();
    error RatioUnrepresentable(uint256 num, uint256 den);
    error PriceOutOfRange(uint256 sqrtPriceX96);
    error RenounceDisabled();
    error RescueToZero();
    error NothingToRescue(address token);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event SequencerUptimeFeedConfigured(address indexed uptimeFeed, uint32 gracePeriod);
    event SequencerCheckAbsent();
    event CrossFeedConfigured(
        PoolId indexed poolId,
        address indexed baseAggregator,
        address indexed quoteAggregator,
        bool baseIsCurrency0,
        uint8 baseDecimals,
        uint8 quoteDecimals,
        uint32 baseHeartbeat,
        uint32 quoteHeartbeat
    );
    event CrossFeedRemoved(PoolId indexed poolId);
    event ReferenceRefreshed(
        PoolId indexed poolId, address indexed by, uint160 sqrtPriceX96, uint64 baseUpdatedAt, uint64 quoteUpdatedAt
    );

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @notice One pool's pair of feeds.
    /// @dev ORDERED FOR THE HOT PATH. The first seven members fill exactly one storage word
    /// (160 + 32 + 32 + 8 + 8 + 8 + 8 = 256 bits), and it holds both heartbeats, which is all
    /// `referencePrice` needs from the configuration. Do not reorder without re-measuring the swap.
    struct CrossFeed {
        /// @dev quote / USD, e.g. the chain's native / USD feed.
        address quoteAggregator;
        /// @dev Seconds a base round stays usable. Non-zero; it is also the "configured" flag.
        uint32 baseHeartbeat;
        /// @dev Seconds a quote round stays usable. Non-zero.
        uint32 quoteHeartbeat;
        /// @dev True when the BASE token (the stock) is the pool's currency0. False for every pool
        /// quoted in the native currency, because `address(0)` always sorts first.
        bool baseIsCurrency0;
        /// @dev Token decimals of the base asset.
        uint8 baseDecimals;
        /// @dev Token decimals of the quote asset (18 for a native currency).
        uint8 quoteDecimals;
        /// @dev `decimals()` of the base aggregator, pinned at configuration.
        uint8 baseFeedDecimals;
        /// @dev base / USD, e.g. a tokenized stock's own feed.
        address baseAggregator;
        /// @dev `decimals()` of the quote aggregator, pinned at configuration.
        uint8 quoteFeedDecimals;
    }

    /// @notice The last computed reference and the two rounds it was computed from. One word.
    struct Cached {
        uint160 sqrtPriceX96;
        uint48 baseUpdatedAt;
        uint48 quoteUpdatedAt;
    }

    /*//////////////////////////////////////////////////////////////
                                STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice L2 sequencer uptime feed, or `address(0)` on a chain that has none.
    address public immutable sequencerUptimeFeed;
    /// @notice Seconds after the sequencer comes back before a price is trusted again.
    uint32 public immutable sequencerGracePeriod;

    mapping(PoolId poolId => CrossFeed) internal _feeds;
    mapping(PoolId poolId => Cached) internal _cache;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev Token and feed decimals alike. See BOUNDS in the header.
    uint8 internal constant MAX_DECIMALS = 18;
    uint256 internal constant MAX_ANSWER = 1e36;
    uint256 internal constant SEQUENCER_GAS_LIMIT = 50_000;
    uint256 internal constant SEQUENCER_RETURN_SIZE = 0xa0;
    uint32 internal constant MAX_HEARTBEAT = 7 days;
    uint32 internal constant MAX_SEQUENCER_GRACE = 24 hours;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    /// @param uptimeFeed_ The chain's sequencer uptime feed, or `address(0)` where none exists.
    /// @param gracePeriod_ Seconds to wait after the sequencer returns; zero if and only if there is no feed.
    /// @param initialOwner The Safe.
    constructor(address uptimeFeed_, uint32 gracePeriod_, address initialOwner) Ownable(initialOwner) {
        if (uptimeFeed_ == address(0)) {
            if (gracePeriod_ != 0) revert InvalidGracePeriod(uptimeFeed_, gracePeriod_);
        } else {
            if (gracePeriod_ == 0 || gracePeriod_ > MAX_SEQUENCER_GRACE) {
                revert InvalidGracePeriod(uptimeFeed_, gracePeriod_);
            }
        }
        sequencerUptimeFeed = uptimeFeed_;
        sequencerGracePeriod = gracePeriod_;
        if (uptimeFeed_ == address(0)) {
            emit SequencerCheckAbsent();
        } else {
            emit SequencerUptimeFeedConfigured(uptimeFeed_, gracePeriod_);
        }
    }

    /*//////////////////////////////////////////////////////////////
                             ADMINISTRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the pair of feeds that prices `poolId`. Replaces any earlier pair and drops the
    ///         cached reference, so nothing computed from the old pair can be served.
    function configureFeed(PoolId poolId, CrossFeed calldata feed) external onlyOwner {
        if (feed.baseAggregator == address(0) || feed.quoteAggregator == address(0)) revert ZeroAddress();
        if (feed.baseAggregator == feed.quoteAggregator) revert SameAggregator(feed.baseAggregator);
        if (feed.baseDecimals > MAX_DECIMALS || feed.quoteDecimals > MAX_DECIMALS) {
            revert InvalidDecimals(feed.baseDecimals, feed.quoteDecimals);
        }
        if (feed.baseFeedDecimals > MAX_DECIMALS) revert InvalidFeedDecimals(feed.baseFeedDecimals);
        if (feed.quoteFeedDecimals > MAX_DECIMALS) revert InvalidFeedDecimals(feed.quoteFeedDecimals);
        if (feed.baseHeartbeat == 0 || feed.baseHeartbeat > MAX_HEARTBEAT) revert InvalidHeartbeat(feed.baseHeartbeat);
        if (feed.quoteHeartbeat == 0 || feed.quoteHeartbeat > MAX_HEARTBEAT) {
            revert InvalidHeartbeat(feed.quoteHeartbeat);
        }
        _requireDecimals(feed.baseAggregator, feed.baseFeedDecimals);
        _requireDecimals(feed.quoteAggregator, feed.quoteFeedDecimals);

        _feeds[poolId] = feed;
        delete _cache[poolId];
        emit CrossFeedConfigured(
            poolId,
            feed.baseAggregator,
            feed.quoteAggregator,
            feed.baseIsCurrency0,
            feed.baseDecimals,
            feed.quoteDecimals,
            feed.baseHeartbeat,
            feed.quoteHeartbeat
        );
    }

    /// @notice Remove a pool's feeds. Its reference reads as unavailable afterwards, which stops trading.
    function removeFeed(PoolId poolId) external onlyOwner {
        delete _feeds[poolId];
        delete _cache[poolId];
        emit CrossFeedRemoved(poolId);
    }

    /// @dev An adapter nobody owns can never have a dead feed replaced.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Send the whole balance of a token that reached this contract by mistake to `to`.
    function rescueERC20(address token, address to) external onlyOwner {
        if (to == address(0)) revert RescueToZero();
        uint256 amount = IERC20(token).balanceOf(address(this));
        if (amount == 0) revert NothingToRescue(token);
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 REFRESH
    //////////////////////////////////////////////////////////////*/

    /// @notice Read both feeds, compute the cross rate and cache it. Permissionless: it can only
    ///         write what the two aggregators themselves report, and it reverts unless both are sound.
    function refresh(PoolId poolId)
        external
        returns (uint160 sqrtPriceX96, uint64 baseUpdatedAt, uint64 quoteUpdatedAt)
    {
        CrossFeed memory feed = _feeds[poolId];
        if (feed.baseHeartbeat == 0) revert FeedNotConfigured(poolId);
        _requireSequencerUp();
        (sqrtPriceX96, baseUpdatedAt, quoteUpdatedAt) = _read(feed);
        _cache[poolId] = Cached({
            sqrtPriceX96: sqrtPriceX96,
            baseUpdatedAt: uint48(baseUpdatedAt),
            quoteUpdatedAt: uint48(quoteUpdatedAt)
        });
        emit ReferenceRefreshed(poolId, msg.sender, sqrtPriceX96, baseUpdatedAt, quoteUpdatedAt);
    }

    /// @notice What `refresh` would cache right now, without writing it.
    function previewRefresh(PoolId poolId)
        external
        view
        returns (uint160 sqrtPriceX96, uint64 baseUpdatedAt, uint64 quoteUpdatedAt)
    {
        CrossFeed memory feed = _feeds[poolId];
        if (feed.baseHeartbeat == 0) revert FeedNotConfigured(poolId);
        _requireSequencerUp();
        return _read(feed);
    }

    function _read(CrossFeed memory feed)
        internal
        view
        returns (uint160 sqrtPriceX96, uint64 baseUpdatedAt, uint64 quoteUpdatedAt)
    {
        uint256 baseAnswer;
        uint256 quoteAnswer;
        (baseAnswer, baseUpdatedAt) = _readLeg(feed.baseAggregator, feed.baseFeedDecimals, feed.baseHeartbeat);
        (quoteAnswer, quoteUpdatedAt) = _readLeg(feed.quoteAggregator, feed.quoteFeedDecimals, feed.quoteHeartbeat);

        uint256 computed = _toSqrtPriceX96(baseAnswer, quoteAnswer, feed);
        if (computed < TickMath.MIN_SQRT_RATIO || computed > TickMath.MAX_SQRT_RATIO) {
            revert PriceOutOfRange(computed);
        }
        sqrtPriceX96 = uint160(computed);
    }

    /// @dev One feed, held to every check the one-feed adapter applies.
    function _readLeg(address aggregator, uint8 configuredDecimals, uint32 heartbeat)
        internal
        view
        returns (uint256 raw, uint64 roundUpdatedAt)
    {
        _requireDecimals(aggregator, configuredDecimals);

        (uint80 roundId, int256 answer,, uint256 updated,) = AggregatorV3Interface(aggregator).latestRoundData();
        if (updated == 0) revert IncompleteRound(aggregator, roundId);
        if (answer <= 0) revert NonPositiveAnswer(aggregator, answer);
        if (updated + heartbeat < block.timestamp) {
            revert AnswerTooOld(aggregator, updated, heartbeat, block.timestamp);
        }
        raw = uint256(answer);
        if (raw > MAX_ANSWER) revert AnswerOutOfRange(aggregator, raw);
        // A round stamped in the future is clamped to now: it must not buy extra life in the cache.
        roundUpdatedAt = uint64(updated > block.timestamp ? block.timestamp : updated);
    }

    function _requireDecimals(address aggregator, uint8 configured) internal view {
        uint8 live = AggregatorV3Interface(aggregator).decimals();
        if (live != configured) revert DecimalsChanged(aggregator, configured, live);
    }

    /*//////////////////////////////////////////////////////////////
                              CONVERSION
    //////////////////////////////////////////////////////////////*/

    /// @dev See THE UNIT and BOUNDS in the header. With every factor bounded as configured,
    /// `num` and `den` are each below 1e72.
    function _toSqrtPriceX96(uint256 baseAnswer, uint256 quoteAnswer, CrossFeed memory feed)
        internal
        pure
        returns (uint256)
    {
        uint256 num = baseAnswer * 10 ** uint256(feed.quoteFeedDecimals);
        uint256 den = quoteAnswer * 10 ** uint256(feed.baseFeedDecimals);
        if (feed.quoteDecimals >= feed.baseDecimals) {
            num *= 10 ** uint256(uint8(feed.quoteDecimals - feed.baseDecimals));
        } else {
            den *= 10 ** uint256(uint8(feed.baseDecimals - feed.quoteDecimals));
        }
        if (!feed.baseIsCurrency0) {
            (num, den) = (den, num);
        }
        // Scale-switched exactly as the one-feed adapter: 2**192 loses nothing for small ratios and
        // overflows for large ones, so a ratio at or above 2**64 takes the 2**126 path instead.
        if ((num >> 64) >= den) {
            if ((num >> 130) >= den) revert RatioUnrepresentable(num, den);
            return Math.sqrt(Math.mulDiv(num, 1 << 126, den)) << 33;
        }
        return Math.sqrt(Math.mulDiv(num, 1 << 192, den));
    }

    /*//////////////////////////////////////////////////////////////
                            SEQUENCER UPTIME
    //////////////////////////////////////////////////////////////*/

    function _requireSequencerUp() internal view {
        address uptimeFeed = sequencerUptimeFeed;
        if (uptimeFeed == address(0)) return;
        (bool readable, int256 answer, uint256 startedAt) = _readSequencer(uptimeFeed);
        if (!readable) revert SequencerFeedUnreadable();
        if (answer != 0) revert SequencerDown();
        if (startedAt == 0) revert SequencerFeedUnreadable();
        if (block.timestamp < startedAt + sequencerGracePeriod) {
            revert SequencerGracePeriod(startedAt, sequencerGracePeriod, block.timestamp);
        }
    }

    function _sequencerOk() internal view returns (bool) {
        address uptimeFeed = sequencerUptimeFeed;
        if (uptimeFeed == address(0)) return true; // absent, and loudly so: see the constructor's event
        (bool readable, int256 answer, uint256 startedAt) = _readSequencer(uptimeFeed);
        if (!readable || answer != 0 || startedAt == 0) return false;
        return block.timestamp >= startedAt + sequencerGracePeriod;
    }

    /// @dev Bounded in gas and in return size, so a broken uptime feed reads as "unreadable" and can
    /// neither burn the caller's gas nor hand back a return-data bomb.
    function _readSequencer(address uptimeFeed)
        internal
        view
        returns (bool readable, int256 answer, uint256 startedAt)
    {
        uint256 gasBudget = SEQUENCER_GAS_LIMIT;
        uint256 returnSize = SEQUENCER_RETURN_SIZE;
        bytes4 selector = AggregatorV3Interface.latestRoundData.selector;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr, selector)
            let out := add(ptr, 0x20)
            let ok := staticcall(gasBudget, uptimeFeed, ptr, 4, out, returnSize)
            if and(ok, eq(returndatasize(), returnSize)) {
                readable := 1
                answer := mload(add(out, 0x20))
                startedAt := mload(add(out, 0x40))
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPriceBandOracle
    /// @dev The hot path: one configuration word, one cache word, and the sequencer read where there
    /// is one. Returns `(0, 0)`, which the consumer treats as "stop trading", when the pool is not
    /// configured, was never refreshed, EITHER leg has outlived its heartbeat, or the sequencer is
    /// down or inside its grace period. `updatedAt` is the OLDER leg's round.
    function referencePrice(PoolId poolId) external view override returns (uint160 sqrtPriceX96, uint64 updatedAt) {
        CrossFeed storage f = _feeds[poolId];
        uint32 baseHeartbeat = f.baseHeartbeat;
        uint32 quoteHeartbeat = f.quoteHeartbeat;
        if (baseHeartbeat == 0) return (0, 0);

        Cached storage c = _cache[poolId];
        uint160 cachedPrice = c.sqrtPriceX96;
        uint48 baseAt = c.baseUpdatedAt;
        uint48 quoteAt = c.quoteUpdatedAt;
        if (cachedPrice == 0) return (0, 0); // never refreshed

        if (uint256(baseAt) + uint256(baseHeartbeat) < block.timestamp) return (0, 0);
        if (uint256(quoteAt) + uint256(quoteHeartbeat) < block.timestamp) return (0, 0);
        if (!_sequencerOk()) return (0, 0);

        return (cachedPrice, baseAt < quoteAt ? baseAt : quoteAt);
    }

    function sequencerCheckEnabled() external view returns (bool) {
        return sequencerUptimeFeed != address(0);
    }

    function sequencerStatus() external view returns (bool enabled, bool ok, uint256 upSince) {
        address uptimeFeed = sequencerUptimeFeed;
        enabled = uptimeFeed != address(0);
        if (!enabled) return (false, true, 0);
        (bool readable, int256 answer, uint256 startedAt) = _readSequencer(uptimeFeed);
        upSince = readable ? startedAt : 0;
        ok = readable && answer == 0 && startedAt != 0 && block.timestamp >= startedAt + sequencerGracePeriod;
    }

    function feedFor(PoolId poolId) external view returns (CrossFeed memory) {
        return _feeds[poolId];
    }

    function cachedReference(PoolId poolId) external view returns (Cached memory) {
        return _cache[poolId];
    }

    /// @notice The two aggregators' own descriptions, e.g. ("NVDA / USD", "ETH / USD").
    function feedDescriptions(PoolId poolId) external view returns (string memory base, string memory quote) {
        CrossFeed storage f = _feeds[poolId];
        if (f.baseHeartbeat == 0) revert FeedNotConfigured(poolId);
        base = AggregatorV3Interface(f.baseAggregator).description();
        quote = AggregatorV3Interface(f.quoteAggregator).description();
    }
}
