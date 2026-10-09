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
import {IPyth} from "../interfaces/IPyth.sol";

/// @title PythPriceBandAdapter
/// @notice An `IPriceBandOracle` backed by a Pyth price feed, for pools trading a tokenized
/// real-world asset against a stablecoin.
///
/// @dev ####################### WHY THIS IS TWO CALLS, NOT ONE #######################
///
/// Pyth is PULL-based: a price only exists on chain once somebody submits a signed update, and
/// `updatePriceFeeds` is `payable` and state-changing. `IPriceBandOracle.referencePrice` is
/// required to be `view` — the consumer reaches it by `staticcall` from inside a Vault lock, and
/// any state write reverts the call and reads as "unavailable".
///
/// So this adapter cannot pull. It splits the work:
///
///   `refresh(poolId)`     PERMISSIONLESS. Reads whatever Pyth currently holds, converts it into
///                         the pool's units, and caches the result. Does the expensive `sqrt`.
///   `referencePrice()`    `view`, one SLOAD of a single packed slot. What every swap pays for.
///
/// This is exactly what the interface's own note prescribes: "An adapter computes it once per feed
/// update instead" of making every trader pay for a rescale and a square root.
///
/// Posting the Pyth update itself is deliberately NOT this contract's job. A keeper posts to Pyth
/// and then calls `refresh`; keeping the two separate means this contract never holds a balance,
/// never forwards value, and cannot be drained of an update fee.
///
/// ####################### THE UNIT. THIS IS THE PART THAT GOES WRONG. #######################
///
/// The interface warns that getting this backwards INVERTS THE BAND — the consumer would then
/// reject every swap in one direction and permit any swap in the other. The conversion here is
/// therefore written out longhand rather than compressed.
///
/// Pyth reports a HUMAN price: `price * 10**expo` units of the quote asset per ONE whole unit of
/// the base asset. Example: AAPL/USD at `price = 18_950_000_000, expo = -8` is $189.50.
///
/// The pool wants `sqrt(currency1 smallest-units per ONE currency0 smallest-unit) * 2**96`, which
/// depends on BOTH tokens' decimals AND on which of the two sorted lower. Two cases:
///
///   baseIsCurrency0 == true   (the RWA token sorted below the stablecoin)
///       currency1 per currency0 = price * 10**expo * 10**quoteDecimals / 10**baseDecimals
///
///   baseIsCurrency0 == false  (the stablecoin sorted below the RWA token)
///       the ratio is the RECIPROCAL of the above.
///
/// Both are expressed below as an exact rational `num / den`, and the square root is taken once, on
/// `num * 2**192 / den` (or `num * 2**126 / den` for ratios at or above `2**64`; see
/// `_toSqrtPriceX96`), so there is no intermediate rounding of the price itself.
///
/// ####################### FAILURE IS A VALID ANSWER #######################
///
/// Rule 4 of the interface: reverting means "no reference price", and the consumer treats that as
/// a reason to STOP TRADING. Every rejection below is therefore deliberate, and every one of them
/// halts the pool rather than letting an unverified price through:
///
///   * no feed configured for this pool
///   * Pyth's price is not strictly positive
///   * Pyth's publish time is older than `maxPublishAge`
///   * the confidence interval is wider than `maxConfBps` of the price
///   * the converted price falls outside the range core can represent (`PriceOutOfRange`, or
///     `RatioUnrepresentable` when the ratio is too large even to compute)
///
/// The first four are checked in `refresh`, so a bad feed never reaches the cache. The consumer
/// separately rejects a cache that has gone stale, because `referencePrice` reports Pyth's own
/// publish time and not the time `refresh` happened to run.
contract PythPriceBandAdapter is IPriceBandOracle, Ownable2Step {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error FeedNotConfigured(PoolId poolId);
    error InvalidDecimals(uint8 baseDecimals, uint8 quoteDecimals);
    error InvalidConfidenceBound(uint16 maxConfBps);
    error InvalidMaxPublishAge();

    /// @notice Pyth reported a price at or below zero.
    error NonPositivePrice(int64 price);

    /// @notice Pyth's price is older than this feed's `maxPublishAge`.
    error PriceTooOld(uint256 publishTime, uint32 maxPublishAge, uint256 nowTs);

    /// @notice The confidence interval is too wide a fraction of the price to act on.
    /// @dev Not a claim the price is wrong — a statement that Pyth's own publishers disagree by
    /// more than this issuer is willing to trade through.
    error ConfidenceTooWide(uint64 conf, uint256 maxConf);

    /// @notice The converted price is outside the range core can represent as a pool price.
    error PriceOutOfRange(uint256 sqrtPriceX96);

    /// @notice The price ratio `num / den` is so far above the representable range that even the
    /// reduced fixed-point scale would overflow. Every such ratio is also above
    /// `TickMath.MAX_SQRT_RATIO`, so this is `PriceOutOfRange` reported before it can be computed.
    /// @dev Same name and shape as `ChainlinkPriceBandAdapter.RatioUnrepresentable`, so a keeper or
    /// monitor decodes both adapters with one ABI entry.
    error RatioUnrepresentable(uint256 num, uint256 den);

    /// @notice `expo` was outside the range any real feed uses.
    /// @dev Guards the `10**|expo|` below from becoming an absurd exponentiation.
    error ExponentOutOfRange(int32 expo);

    /// @notice `renounceOwnership` is permanently disabled. See the override.
    error RenounceDisabled();

    /// @notice `rescueERC20` was asked to pay the zero address.
    error RescueToZero();
    /// @notice `rescueERC20` found no balance of `token` here.
    error NothingToRescue(address token);
    /// @notice An ERC-20 sent here by mistake was moved out by the owner.
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event FeedConfigured(
        PoolId indexed poolId,
        bytes32 indexed priceId,
        bool baseIsCurrency0,
        uint8 baseDecimals,
        uint8 quoteDecimals,
        uint16 maxConfBps,
        uint32 maxPublishAge
    );

    event FeedRemoved(PoolId indexed poolId);

    /// @notice Emitted on every successful `refresh`.
    /// @dev `publishTime` is Pyth's, not `block.timestamp`, so a reader can see how far behind the
    /// cache was at the moment it was written.
    event ReferenceRefreshed(
        PoolId indexed poolId, address indexed by, uint160 sqrtPriceX96, uint64 publishTime
    );

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @param priceId Pyth's feed id. Zero means no feed is configured.
    /// @param baseIsCurrency0 True when the RWA token is the pool's `currency0`.
    /// @param baseDecimals Decimals of the base (RWA) token.
    /// @param quoteDecimals Decimals of the quote (stablecoin).
    /// @param maxConfBps Widest acceptable `conf/price`, in bps of the price.
    /// @param maxPublishAge Oldest acceptable Pyth publish time, in seconds.
    struct Feed {
        bytes32 priceId;
        bool baseIsCurrency0;
        uint8 baseDecimals;
        uint8 quoteDecimals;
        uint16 maxConfBps;
        uint32 maxPublishAge;
    }

    /// @dev `uint160 + uint64` is 224 bits and shares ONE slot, so `referencePrice` is a single
    /// SLOAD. That matters: it runs inside a Vault lock under a hard gas cap on every swap.
    struct Cached {
        uint160 sqrtPriceX96;
        uint64 publishTime;
    }

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    IPyth public immutable pyth;

    mapping(PoolId poolId => Feed) internal _feeds;
    mapping(PoolId poolId => Cached) internal _cache;

    uint256 private constant BPS_DENOMINATOR = 10_000;

    /// @dev Pyth exponents live around -8. Anything beyond this is not a feed we understand, and
    /// bounding it keeps `10**|expo|` from overflowing or costing unbounded gas.
    int32 private constant MIN_EXPO = -30;
    int32 private constant MAX_EXPO = 12;

    constructor(IPyth pyth_, address initialOwner) Ownable(initialOwner) {
        if (address(pyth_) == address(0)) revert ZeroAddress();
        pyth = pyth_;
    }

    /*//////////////////////////////////////////////////////////////
                             ADMINISTRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Point a pool at a Pyth feed. Owner only; on a live chain that owner is a timelock.
    /// @dev Deliberately owner-gated even though `refresh` is not: choosing WHICH feed prices an
    /// asset, and how wide a confidence interval to accept, is the trust decision. Executing that
    /// decision is not.
    function configureFeed(PoolId poolId, Feed calldata feed) external onlyOwner {
        if (feed.priceId == bytes32(0)) revert FeedNotConfigured(poolId);
        // 77 is the largest power of ten that fits a uint256; a token cannot exceed it, and the
        // difference of the two is what the conversion exponentiates.
        if (feed.baseDecimals > 36 || feed.quoteDecimals > 36) {
            revert InvalidDecimals(feed.baseDecimals, feed.quoteDecimals);
        }
        // A zero bound would reject every real price (conf is essentially never 0); a bound at or
        // above 100% would accept a price Pyth has no confidence in at all.
        if (feed.maxConfBps == 0 || feed.maxConfBps >= BPS_DENOMINATOR) {
            revert InvalidConfidenceBound(feed.maxConfBps);
        }
        if (feed.maxPublishAge == 0) revert InvalidMaxPublishAge();

        _feeds[poolId] = feed;
        emit FeedConfigured(
            poolId,
            feed.priceId,
            feed.baseIsCurrency0,
            feed.baseDecimals,
            feed.quoteDecimals,
            feed.maxConfBps,
            feed.maxPublishAge
        );
    }

    /// @notice Stop pricing a pool. Owner only.
    /// @dev Clears the cache as well as the feed. Leaving a stale cached price behind after
    /// removing its source would let a pool keep trading against a number nobody is maintaining.
    /// With both cleared, `referencePrice` returns 0 and the consumer halts the pool — which is
    /// the correct reading of "this offering no longer has a price source".
    function removeFeed(PoolId poolId) external onlyOwner {
        delete _feeds[poolId];
        delete _cache[poolId];
        emit FeedRemoved(poolId);
    }

    /**
     * @notice Permanently disabled. Reverts for every caller.
     *
     * @dev CLAUDE.md § "Deployed and unfixable" makes this the house rule for every contract
     * deployed from here on, and `MerkleEpochDistributor` is the reference. The reason is the same
     * one `ChainlinkPriceBandAdapter` gives.
     *
     * `configureFeed` and `removeFeed` are the only `onlyOwner` functions, and both are
     * REVERSIBLE — the owner can only choose which Pyth feed prices a pool and how much confidence
     * and staleness to accept, or withdraw a feed. Renouncing therefore removes no power that could
     * be abused. What it removes is the ability to repoint a pool whose feed stops publishing, to
     * tighten a `maxConfBps` or `maxPublishAge` that proves too loose, or to withdraw a price source
     * nobody maintains any more. Every pool this adapter serves would be stuck with the
     * configuration it had at that moment, permanently, because `transferOwnership` is itself
     * `onlyOwner`.
     *
     * The bounded form of the same intent already exists and is unaffected: an owner who wants out
     * transfers to the address that should have it. `Ownable2Step` means that cannot land somewhere
     * unreachable by typo.
     */
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Move an ERC-20 that was sent here by mistake to `to`.
    /// @dev An adapter holds nothing by design, so any ERC-20 balance is misdirected value with, until now, no path out
    /// (acceptance finding L-1, docs/protocol-acceptance.md, 2026-09-18). Whole balance, `SafeERC20`.
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

    /// @notice Recompute a pool's cached reference from whatever Pyth currently holds.
    ///
    /// @dev PERMISSIONLESS, and that is a security property rather than a convenience. The caller
    /// supplies no price and cannot influence the result: every input comes from Pyth and from
    /// owner-set configuration. The worst a hostile caller can do is refresh at a moment of their
    /// choosing, which is bounded by what Pyth published and by `maxConfBps`.
    ///
    /// Reverts rather than caching anything questionable. A revert leaves the previous cache in
    /// place; if that in turn ages past the consumer's own window, the consumer halts the pool.
    /// Both failure directions stop trading, neither lets an unverified price through.
    function refresh(PoolId poolId) external returns (uint160 sqrtPriceX96, uint64 publishTime) {
        Feed memory feed = _feeds[poolId];
        if (feed.priceId == bytes32(0)) revert FeedNotConfigured(poolId);

        IPyth.Price memory p = pyth.getPriceUnsafe(feed.priceId);

        if (p.price <= 0) revert NonPositivePrice(p.price);
        if (p.expo < MIN_EXPO || p.expo > MAX_EXPO) revert ExponentOutOfRange(p.expo);

        // Future-dated publish times are tolerated for the same reason the consuming module
        // tolerates them: publisher clocks and block timestamps disagree by seconds routinely, and
        // halting a market over clock skew is the wrong failure.
        if (p.publishTime + feed.maxPublishAge < block.timestamp) {
            revert PriceTooOld(p.publishTime, feed.maxPublishAge, block.timestamp);
        }

        uint256 price = uint256(uint64(p.price));
        uint256 maxConf = (price * feed.maxConfBps) / BPS_DENOMINATOR;
        if (p.conf > maxConf) revert ConfidenceTooWide(p.conf, maxConf);

        uint256 computed = _toSqrtPriceX96(price, p.expo, feed);
        if (computed < TickMath.MIN_SQRT_RATIO || computed > TickMath.MAX_SQRT_RATIO) {
            revert PriceOutOfRange(computed);
        }

        // forge-lint: disable-next-line(unsafe-typecast)
        sqrtPriceX96 = uint160(computed);
        // Pyth publish times are uint256 by ABI but are unix seconds; the bound above already
        // constrains this to roughly now.
        // forge-lint: disable-next-line(unsafe-typecast)
        publishTime = uint64(p.publishTime);

        _cache[poolId] = Cached({sqrtPriceX96: sqrtPriceX96, publishTime: publishTime});
        emit ReferenceRefreshed(poolId, msg.sender, sqrtPriceX96, publishTime);
    }

    /*//////////////////////////////////////////////////////////////
                              CONVERSION
    //////////////////////////////////////////////////////////////*/

    /// @dev Pyth's human price -> the pool's `sqrtPriceX96`. Written as an exact rational so the
    /// price is never rounded before the single square root at the end.
    ///
    /// Let `H = price * 10**expo` be quote units per ONE whole base unit. The pool's ratio is
    ///
    ///     R = currency1_smallest_units / currency0_smallest_unit
    ///
    /// With the base token as currency0:  R = H * 10**quoteDecimals / 10**baseDecimals
    /// With the base token as currency1:  R = 1 / that
    ///
    /// Collecting every power of ten into one numerator and one denominator avoids computing `H`
    /// (which is fractional) at all.
    ///
    /// ---- THE TWO SCALES (mirrors `ChainlinkPriceBandAdapter._toSqrtPriceX96`) ----
    ///
    /// `sqrtPriceX96 = sqrt(R * 2**192)`, so the natural computation is
    /// `sqrt(mulDiv(num, 2**192, den))`. That is exact, and loses nothing at the LOW end: core's
    /// `MIN_SQRT_RATIO` is `R ~= 2**-128`, where `R * 2**192` is still `~2**64`.
    ///
    /// It breaks at the HIGH end. `mulDiv` reverts with OpenZeppelin's generic
    /// `MathOverflowedMulDiv()` once the quotient reaches `2**256`, i.e. once `R >= 2**64` — while
    /// core represents ratios up to `R ~= 2**128`. A 0-decimal security token priced against an
    /// 18-decimal stablecoin crosses `2**64` at a human price of about 18.45. Before this branch
    /// existed, such a pool's `refresh` reverted forever with an error naming neither this
    /// contract nor the cause, and the pool could never trade.
    ///
    /// So the scale is chosen from the ratio's magnitude, and the branch condition is exact:
    /// `(num >> 64) >= den` iff `num >= den * 2**64` iff `R >= 2**64` iff the single-scale
    /// `mulDiv` would overflow. Every input the single-scale formula could compute therefore still
    /// takes it, bit for bit.
    ///
    ///   R <  2**64    scale 2**192: `sqrt(R * 2**192)` directly.
    ///   R >= 2**64    scale 2**126: `sqrt(R * 2**126) << 33`, since `sqrt(R * 2**126) = sqrt(R) * 2**63`
    ///                 and `2**63 << 33 == 2**96`. Its input is at least `2**190`, so the root keeps
    ///                 at least 95 significant bits; the shift floors the result to a multiple of
    ///                 `2**33`, a relative error below `2**-95`, far under any band width.
    ///   R >= 2**130   `RatioUnrepresentable`. `mulDiv(num, 2**126, den)` would overflow, and every
    ///                 such ratio is already above `MAX_SQRT_RATIO` (whose `R` is below `2**128`),
    ///                 so no representable price is rejected here.
    ///
    /// The range check against `TickMath` in `refresh`/`previewRefresh` is unchanged and still
    /// decides the final answer for everything below `2**130`, including the low end, where a
    /// ratio too small to represent floors below `MIN_SQRT_RATIO` (down to 0) and reverts
    /// `PriceOutOfRange` with the computed value.
    function _toSqrtPriceX96(uint256 price, int32 expo, Feed memory feed)
        internal
        pure
        returns (uint256)
    {
        // Start from `price * 10**quoteDecimals / 10**baseDecimals`, then fold in `10**expo`.
        uint256 num = price;
        uint256 den = 1;

        if (feed.quoteDecimals >= feed.baseDecimals) {
            num *= 10 ** uint256(uint8(feed.quoteDecimals - feed.baseDecimals));
        } else {
            den *= 10 ** uint256(uint8(feed.baseDecimals - feed.quoteDecimals));
        }

        if (expo >= 0) {
            num *= 10 ** uint256(uint32(expo));
        } else {
            den *= 10 ** uint256(uint32(-expo));
        }

        // Reciprocal when the stablecoin sorted below the RWA token. Swapping the rational is
        // exact; inverting a computed decimal would not be.
        if (!feed.baseIsCurrency0) {
            (num, den) = (den, num);
        }

        // `den` is a product of powers of ten or, after the swap, a price already rejected when
        // non-positive, so it is never zero.
        if ((num >> 64) >= den) {
            // R >= 2**64: the 2**192 scale would overflow. Reject beyond 2**130 first, where even
            // the reduced scale overflows and core could not represent the price anyway.
            if ((num >> 130) >= den) revert RatioUnrepresentable(num, den);
            // sqrt(R * 2**126) == sqrt(R) * 2**63; shifting up 33 gives sqrt(R) * 2**96.
            return Math.sqrt(Math.mulDiv(num, 1 << 126, den)) << 33;
        }

        // R < 2**64, so `num * 2**192 / den < 2**256`. `mulDiv` carries the intermediate at 512
        // bits, so the numerator itself cannot overflow either.
        return Math.sqrt(Math.mulDiv(num, 1 << 192, den));
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPriceBandOracle
    /// @dev One SLOAD. An unconfigured or never-refreshed pool reads `(0, 0)`, which the consumer
    /// treats as unavailable and rejects the swap — the correct fail-closed answer.
    ///
    /// The timestamp reported is PYTH'S publish time, not the time `refresh` ran. That is the
    /// meaningful one: a cache refreshed a second ago from an hour-old Pyth price is an hour-old
    /// price, and the consumer's staleness window should see it that way.
    function referencePrice(PoolId poolId)
        external
        view
        override
        returns (uint160 sqrtPriceX96, uint64 updatedAt)
    {
        // Fail closed on age, like the Chainlink adapter (audit B, 2026-10-07): a consumer configured with
        // `maxPriceAge == 0` ("trust the oracle") otherwise had NO staleness check at all, and a stalled
        // keeper left trading against an arbitrarily old reference. `maxPublishAge` is this feed's own
        // bound, the same one `refresh` enforces at write time. Addition, not subtraction: a future-dated
        // publish time must not underflow into "fresh forever".
        Feed storage f = _feeds[poolId];
        if (f.priceId == bytes32(0)) return (0, 0); // no feed
        Cached storage c = _cache[poolId];
        if (c.sqrtPriceX96 == 0) return (0, 0); // never refreshed
        if (uint256(c.publishTime) + uint256(f.maxPublishAge) < block.timestamp) return (0, 0); // stale
        return (c.sqrtPriceX96, c.publishTime);
    }

    /// @notice The feed configured for a pool. `priceId == 0` means none.
    function feedFor(PoolId poolId) external view returns (Feed memory) {
        return _feeds[poolId];
    }

    /// @notice What `refresh` WOULD write, without writing it.
    /// @dev For a keeper deciding whether posting a Pyth update is worth the fee, and for an
    /// operator diagnosing why a pool has halted. Reverts with the same error `refresh` would.
    function previewRefresh(PoolId poolId)
        external
        view
        returns (uint160 sqrtPriceX96, uint64 publishTime)
    {
        Feed memory feed = _feeds[poolId];
        if (feed.priceId == bytes32(0)) revert FeedNotConfigured(poolId);

        IPyth.Price memory p = pyth.getPriceUnsafe(feed.priceId);
        if (p.price <= 0) revert NonPositivePrice(p.price);
        if (p.expo < MIN_EXPO || p.expo > MAX_EXPO) revert ExponentOutOfRange(p.expo);
        if (p.publishTime + feed.maxPublishAge < block.timestamp) {
            revert PriceTooOld(p.publishTime, feed.maxPublishAge, block.timestamp);
        }

        uint256 price = uint256(uint64(p.price));
        uint256 maxConf = (price * feed.maxConfBps) / BPS_DENOMINATOR;
        if (p.conf > maxConf) revert ConfidenceTooWide(p.conf, maxConf);

        uint256 computed = _toSqrtPriceX96(price, p.expo, feed);
        if (computed < TickMath.MIN_SQRT_RATIO || computed > TickMath.MAX_SQRT_RATIO) {
            revert PriceOutOfRange(computed);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint160(computed), uint64(p.publishTime));
    }
}
