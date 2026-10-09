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

/// @title AggregatorV3Interface
/// @notice The three Chainlink aggregator methods this adapter uses, declared locally.
///
/// @dev Declared here rather than pulled in as a dependency, deliberately. `@chainlink/contracts`
/// is a large package under its own licence, and this adapter needs three function signatures from
/// it. Vendoring three signatures is not a derivative-work question and does not add a submodule to
/// a monorepo that already pins its dependencies by sibling path.
///
/// The signatures are the ones every Chainlink `AggregatorV3` proxy and every L2 sequencer-uptime
/// feed exposes; the selectors are what matter and they are fixed by the ABI, not by this file.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title ChainlinkPriceBandAdapter
/// @notice An `IPriceBandOracle` backed by a Chainlink `AggregatorV3` feed, for pools trading a
/// tokenized real-world asset against a stablecoin. The push-based sibling of
/// `PythPriceBandAdapter`.
///
/// @dev ####################### WHY THIS IS STILL TWO CALLS #######################
///
/// Chainlink is PUSH-based: the price already exists on chain and `latestRoundData` is a `view`, so
/// unlike the Pyth sibling nothing here is forced to split the work by mutability. It is split
/// anyway, for the reason the interface itself gives:
///
///   `refresh(poolId)`    PERMISSIONLESS. Reads the aggregator, validates the round, converts to
///                        the pool's units — the rescale and the square root — and caches it.
///   `referencePrice()`   `view`. Two SLOADs, one bounded staticcall to the sequencer feed when
///                        one is configured, and no arithmetic beyond a comparison.
///
/// A swap that had to rescale a feed answer and take a 256-bit square root inside the Vault lock
/// would pay for it on every trade, and would do so under `MarketHoursModule`'s hard
/// `PRICE_ORACLE_GAS_LIMIT` — a budget an unbounded aggregator proxy chain could plausibly blow,
/// which would read as "oracle unavailable" and halt the pool for a reason that has nothing to do
/// with the price. The conversion happens once per feed update instead, exactly as the interface
/// prescribes.
///
/// `refresh` is permissionless because the keeper package is permissionless by design (CLAUDE.md
/// § Automation): a privileged refresh makes the pool's ability to trade a liveness dependency on
/// one key, and a stolen key that can only refresh buys an attacker nothing. The caller supplies no
/// price and cannot influence the result — every input comes from the aggregator and from
/// owner-set configuration.
///
/// ####################### THE UNIT. THIS IS THE PART THAT GOES WRONG. #######################
///
/// The interface warns that getting this backwards INVERTS THE BAND: the consumer would read a
/// pool trading at fair value as wildly off it, reject every swap in one direction, and permit any
/// swap in the other. The conversion is therefore written out longhand.
///
/// Chainlink reports a HUMAN price: `answer / 10**feedDecimals` units of the quote asset per ONE
/// WHOLE unit of the base asset. `AAPL/USD` at `answer = 18_950_000_000, decimals = 8` is $189.50.
///
/// The pool wants
///
///     sqrtPriceX96 = sqrt(currency1 smallest-units per ONE currency0 smallest-unit) * 2**96
///
/// which depends on BOTH tokens' decimals AND on which of the two sorted lower:
///
///   baseIsCurrency0 == true    (the RWA token sorted below the stablecoin)
///       R = answer * 10**quoteDecimals / (10**feedDecimals * 10**baseDecimals)
///
///   baseIsCurrency0 == false   (the stablecoin sorted below the RWA token)
///       R = the RECIPROCAL of the above.
///
/// Both are carried as an exact rational `num / den` and inverted by SWAPPING the two, so the price
/// itself is never rounded before the single square root at the end.
///
/// ####################### THE L2 SEQUENCER #######################
///
/// Chainlink's documented guidance for L2s is that a price read must also consult the chain's
/// sequencer-uptime feed and refuse prices published while the sequencer was down, or within a
/// grace period of it coming back. The hazard is the restart: transactions queued during an outage
/// all execute in a burst against a reference nobody was able to update.
///
/// Note carefully that the cache's own staleness does NOT cover this. An outage shorter than a
/// feed's `heartbeat` leaves the cached reference looking perfectly fresh at restart, and the
/// burst trades against it. That is precisely the window the grace period exists for, and it is why
/// the check is applied in `referencePrice` and not only in `refresh`.
///
/// `sequencerUptimeFeed` is an immutable constructor argument and MAY be `address(0)`:
///
///   * SET      — enforced in both `refresh` and `referencePrice`. A down sequencer, an
///                uninitialised uptime round, an uptime feed that reverts or returns the wrong
///                shape, or a recovery inside `sequencerGracePeriod` all read as no reference
///                price, and the consumer halts the pool.
///
///   * ZERO     — THE CHECK IS ABSENT AND THIS CONTRACT SAYS SO OUT LOUD. The constructor emits
///                `SequencerCheckAbsent`, `sequencerCheckEnabled()` returns false, and this
///                paragraph is the warning: on an L2 deployed without an uptime feed, A SEQUENCER
///                RESTART CAN BE TRADED THROUGH. A burst of queued swaps will execute against
///                whatever reference was last cached, and the only thing standing between them and
///                a stale price is the feed's `heartbeat`. Do not read "not configured" as
///                "the sequencer is up" — nothing here has checked.
///
///                This is not a hypothetical default. At the time of writing, no sequencer-uptime
///                feed is published for Robinhood Chain by either Chainlink or the chain operator,
///                so a deployment there MUST pass zero and MUST compensate with a `heartbeat`
///                short enough that an outage of operational significance ages the cache out.
///
/// The feed is immutable rather than owner-settable on purpose. It is the one parameter whose
/// removal LOOSENS the contract, and a setter would hand the owner a one-transaction way to
/// disable a safety check. Repointing is cheap by other means: this adapter holds no funds and no
/// history, and `MarketHoursModule` names its oracle in per-pool settings, so adopting an uptime
/// feed that gets published later is a redeploy and a config change, not a migration.
///
/// ####################### FAILURE IS A VALID ANSWER #######################
///
/// Rule 4 of the interface: no reference price means STOP TRADING, never "skip the check". The two
/// halves fail in opposite styles, both closed:
///
///   `refresh`         REVERTS, with a named error, and caches nothing. A revert is a free read
///                     for a keeper that simulates before it sends (CLAUDE.md § Automation), and
///                     it leaves the previous cache in place rather than zeroing it — the previous
///                     price then ages out on its own `heartbeat`.
///
///   `referencePrice`  NEVER REVERTS. It returns `(0, 0)` for: no feed configured, nothing ever
///                     cached, a cached answer older than the feed's `heartbeat`, and — when an
///                     uptime feed is configured — a sequencer that is down, inside its grace
///                     period, or unreadable. `(0, 0)` is what the consumer treats as unavailable.
///                     Returning rather than reverting costs the consumer nothing (it reads a
///                     revert the same way) and makes this contract usable from any other reader
///                     without a try/catch.
///
/// `updatedAt` is THE FEED'S OWN round timestamp, never `block.timestamp` and never the moment
/// `refresh` ran. That is what makes a stale cache detectable by the consumer's own staleness
/// window, and it is what makes the whole arrangement fail closed: if nobody refreshes, the number
/// ages, the consumer rejects it, and trading halts. A cache refreshed one second ago from an
/// hour-old round is an hour-old price and must report itself as one.
///
/// ####################### ROUNDING #######################
///
/// Every step rounds DOWN (`Math.mulDiv` and `Math.sqrt` both floor), so the reference is at most
/// one unit of `sqrtPriceX96` below the exact value. See `_toSqrtPriceX96` for why that is the
/// right choice and how small the resulting error is.
///
/// ####################### WHAT THIS IS NOT #######################
///
/// Nothing here is legal advice, and a price cached here is not a valuation, a NAV, a mark, an
/// official closing price, or a representation that any trade near it is fair or lawful. A
/// Chainlink feed is a third party this contract cannot audit; pointing a pool at one is a trust
/// decision, which is why it is `onlyOwner`. See `IPriceBandOracle`.
contract ChainlinkPriceBandAdapter is IPriceBandOracle, Ownable2Step {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();

    /// @notice No aggregator is configured for this pool.
    error FeedNotConfigured(PoolId poolId);

    /// @notice Token decimals outside the range the conversion can carry.
    error InvalidDecimals(uint8 baseDecimals, uint8 quoteDecimals);

    /// @notice The aggregator's own `decimals()` is outside the range the conversion can carry.
    error InvalidFeedDecimals(uint8 feedDecimals);

    /// @notice `heartbeat` is zero, or long enough that it has stopped being a staleness bound.
    error InvalidHeartbeat(uint32 heartbeat);

    /// @notice `sequencerGracePeriod` disagrees with whether an uptime feed was supplied.
    /// @dev A non-zero grace with no feed is a lie; a zero grace with a feed is the L2 check
    /// disabled by omission, which is precisely the silent state this contract refuses to have.
    error InvalidGracePeriod(address uptimeFeed, uint32 gracePeriod);

    /// @notice The aggregator reported a price at or below zero.
    /// @dev Chainlink's `answer` is `int256`. A negative or zero answer on an equity or FX feed is
    /// a malfunction, not a price, and there is no reading of it that should govern a band.
    error NonPositiveAnswer(int256 answer);

    /// @notice The round has no timestamp, i.e. it has not been completed.
    error IncompleteRound(uint80 roundId);

    /// @notice The round is older than this feed's `heartbeat`.
    error AnswerTooOld(uint256 roundUpdatedAt, uint32 heartbeat, uint256 nowTs);

    /// @notice The answer is larger than the conversion can carry without overflowing.
    /// @dev Not a plausible price on any real feed; the bound exists so an absurd or corrupted
    /// answer produces a named revert rather than an arithmetic panic.
    error AnswerOutOfRange(uint256 answer);

    /// @notice The aggregator's `decimals()` no longer matches what the owner configured.
    /// @dev A Chainlink proxy can be repointed at a new underlying aggregator. If that aggregator
    /// reports different decimals, every conversion made with the configured value would be wrong
    /// by a power of ten. Checked on every refresh rather than trusted from configuration time.
    error DecimalsChanged(uint8 configured, uint8 current);

    /// @notice The sequencer-uptime feed says the sequencer is down.
    error SequencerDown();

    /// @notice The sequencer is back, but not for long enough yet.
    error SequencerGracePeriod(uint256 upSince, uint32 gracePeriod, uint256 nowTs);

    /// @notice The uptime feed could not be read, or answered in the wrong shape.
    /// @dev Treated as "assume the worst". An unreadable uptime feed is not evidence of uptime.
    error SequencerFeedUnreadable();

    /// @notice The price ratio is so far outside the representable range that even the reduced
    /// fixed-point scale would overflow.
    error RatioUnrepresentable(uint256 num, uint256 den);

    /// @notice The converted price is outside the range core can represent as a pool price.
    error PriceOutOfRange(uint256 sqrtPriceX96);

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

    /// @notice Emitted once, from the constructor, when an L2 sequencer-uptime feed IS configured.
    event SequencerUptimeFeedConfigured(address indexed uptimeFeed, uint32 gracePeriod);

    /// @notice Emitted once, from the constructor, when one IS NOT.
    /// @dev Deliberately its own event rather than the one above with a zero address. A deployment
    /// without the L2 check is a materially different security posture and an indexer, a monitor
    /// or a reviewer should be able to find it with a topic filter rather than by decoding
    /// arguments. See the contract header for what it means.
    event SequencerCheckAbsent();

    event FeedConfigured(
        PoolId indexed poolId,
        address indexed aggregator,
        bool baseIsCurrency0,
        uint8 baseDecimals,
        uint8 quoteDecimals,
        uint8 feedDecimals,
        uint32 heartbeat
    );

    event FeedRemoved(PoolId indexed poolId);

    /// @notice Emitted on every successful `refresh`.
    /// @dev `roundUpdatedAt` is the AGGREGATOR's, not `block.timestamp`, so a reader can see how
    /// far behind the cache already was at the moment it was written.
    event ReferenceRefreshed(
        PoolId indexed poolId, address indexed by, uint160 sqrtPriceX96, uint64 roundUpdatedAt, uint80 roundId
    );

    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    /// @param aggregator The Chainlink `AggregatorV3` proxy. Zero means no feed is configured.
    /// @param baseIsCurrency0 True when the feed's BASE asset (the RWA) is the pool's `currency0`.
    ///        This is the field that inverts the band if it is wrong. It is not derivable here —
    ///        this contract never sees the pool's tokens — so it is the owner's assertion, and the
    ///        deployment runbook must confirm it against the live pool's `getSlot0`.
    /// @param baseDecimals ERC-20 decimals of the base (RWA) token.
    /// @param quoteDecimals ERC-20 decimals of the quote (stablecoin).
    /// @param feedDecimals The aggregator's `decimals()`, recorded at configuration time and
    ///        re-checked on every refresh.
    /// @param heartbeat Oldest acceptable round age, in seconds. Enforced in `refresh` so a stale
    ///        round is never cached, and again in `referencePrice` so a cache that has aged since
    ///        reads as unavailable.
    /// @dev 160 + 8 + 8 + 8 + 8 + 32 = 224 bits: ONE slot, so the freshness policy costs the hot
    /// read a single SLOAD.
    struct Feed {
        address aggregator;
        bool baseIsCurrency0;
        uint8 baseDecimals;
        uint8 quoteDecimals;
        uint8 feedDecimals;
        uint32 heartbeat;
    }

    /// @dev `uint160 + uint64` is 224 bits and shares ONE slot, so the cached reference is a single
    /// SLOAD. That matters: it is read inside a Vault lock under a hard gas cap on every swap.
    struct Cached {
        uint160 sqrtPriceX96;
        uint64 roundUpdatedAt;
    }

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice The L2 sequencer-uptime feed, or `address(0)` when the check is absent.
    /// @dev Immutable. See the contract header for why this is not a setter.
    address public immutable sequencerUptimeFeed;

    /// @notice Seconds the sequencer must have been continuously up before a price is acted on.
    /// @dev Zero exactly when `sequencerUptimeFeed` is zero; the constructor enforces the pairing.
    uint32 public immutable sequencerGracePeriod;

    mapping(PoolId poolId => Feed) internal _feeds;
    mapping(PoolId poolId => Cached) internal _cache;

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @dev 36 is well above any real token or feed and keeps `10 ** diff` far inside a uint256.
    uint8 internal constant MAX_DECIMALS = 36;

    /// @dev Largest raw answer the conversion accepts. `MAX_ANSWER * 10**MAX_DECIMALS` is 1e76,
    /// which is under `type(uint256).max` (~1.16e77), so the rescale below cannot overflow. At a
    /// feed's usual 8 decimals this permits a price of 1e32 quote units per base unit — not a
    /// bound any real feed can reach, only one a corrupted answer can.
    uint256 internal constant MAX_ANSWER = 1e40;

    /// @dev Gas forwarded to the sequencer-uptime feed from the hot `view`.
    ///
    /// Bounded for the same reason `MarketHoursModule` bounds what it forwards to this contract: a
    /// broken or repointed proxy must not be able to consume the whole budget the module allowed
    /// us and take the pool's trading with it. A read that does not fit is treated as unreadable,
    /// which is the fail-closed direction.
    ///
    /// 50,000 is roughly an order of magnitude more than a proxy-plus-aggregator `latestRoundData`
    /// costs cold, and a quarter of `PRICE_ORACLE_GAS_LIMIT`, so the whole view stays comfortably
    /// inside the module's cap even in the worst case.
    uint256 internal constant SEQUENCER_GAS_LIMIT = 50_000;

    /// @dev Exact ABI return size of `latestRoundData`: five words. Compared against
    /// `returndatasize` BEFORE anything is copied, which is what defeats a return-data bomb.
    uint256 internal constant SEQUENCER_RETURN_SIZE = 0xa0;

    /// @dev Longest `heartbeat` `configureFeed` will accept, 7 days.
    ///
    /// Unlike the grace period, this bound is load-bearing rather than a units check. `heartbeat`
    /// is the ONLY thing that ages a cached reference out, and it is the sole mechanism that makes
    /// a chain with no sequencer-uptime feed fail closed at all. A heartbeat long enough to be
    /// meaningless is therefore the one owner mistake here that LOOSENS the contract instead of
    /// halting it, and the house rule is that a loosening needs a bound.
    ///
    /// Seven days is deliberately generous — well above the 24-hour heartbeat of the slowest real
    /// equity or FX feed — because the tight bound belongs in the deployment runbook, not in
    /// immutable code that cannot accommodate a feed nobody has met yet. The consumer's own
    /// `maxPriceAge` is the second, independent limit and should normally be far shorter.
    uint32 internal constant MAX_HEARTBEAT = 7 days;

    /// @dev Longest sequencer grace period the constructor will accept, 24 hours.
    ///
    /// A long grace is fail-closed rather than dangerous — it halts trading for longer — so this is
    /// not a safety bound. It is a units check: the single most likely way to get this argument
    /// wrong is to pass milliseconds, and a value of 3_600_000 would silently halt every pool this
    /// adapter serves for forty-one days.
    uint32 internal constant MAX_SEQUENCER_GRACE = 24 hours;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    /// @param uptimeFeed_ The chain's Chainlink sequencer-uptime feed, or `address(0)` when the
    ///        chain has none published. Passing zero is a supported deployment and a documented
    ///        weakening — read the contract header before you do it.
    /// @param gracePeriod_ Seconds the sequencer must have been up before a price is acted on.
    ///        Must be zero exactly when `uptimeFeed_` is zero, so the pair cannot disagree.
    /// @param initialOwner Ownership seat. Per CLAUDE.md's ownership table this is the governance
    ///        Safe, matching `PythPriceBandAdapter`: the owner here only configures, and every
    ///        power it has is reversible.
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

    /// @notice Point a pool at a Chainlink aggregator. Owner only.
    ///
    /// @dev Deliberately owner-gated even though `refresh` is not: choosing WHICH feed prices an
    /// asset, asserting which of the pool's two tokens the feed's base asset is, and deciding how
    /// old an answer may be are the trust decisions. Executing them is not.
    ///
    /// `feedDecimals` is checked against the aggregator's live `decimals()` here AND on every
    /// refresh, so a configuration typo is caught at configuration time and a proxy repointed at an
    /// aggregator with different decimals is caught before it can produce a price wrong by a power
    /// of ten. The call also proves the address is a contract that answers the ABI, so an
    /// aggregator address off by a character does not sit in storage looking configured.
    function configureFeed(PoolId poolId, Feed calldata feed) external onlyOwner {
        if (feed.aggregator == address(0)) revert ZeroAddress();
        if (feed.baseDecimals > MAX_DECIMALS || feed.quoteDecimals > MAX_DECIMALS) {
            revert InvalidDecimals(feed.baseDecimals, feed.quoteDecimals);
        }
        if (feed.feedDecimals > MAX_DECIMALS) revert InvalidFeedDecimals(feed.feedDecimals);
        if (feed.heartbeat == 0 || feed.heartbeat > MAX_HEARTBEAT) revert InvalidHeartbeat(feed.heartbeat);

        uint8 live = AggregatorV3Interface(feed.aggregator).decimals();
        if (live != feed.feedDecimals) revert DecimalsChanged(feed.feedDecimals, live);

        _feeds[poolId] = feed;
        emit FeedConfigured(
            poolId,
            feed.aggregator,
            feed.baseIsCurrency0,
            feed.baseDecimals,
            feed.quoteDecimals,
            feed.feedDecimals,
            feed.heartbeat
        );
    }

    /// @notice Stop pricing a pool. Owner only.
    /// @dev Clears the cache as well as the feed. Leaving a cached price behind after removing its
    /// source would let a pool keep trading against a number nobody is maintaining. With both
    /// cleared, `referencePrice` returns `(0, 0)` and the consumer halts the pool — the correct
    /// reading of "this offering no longer has a price source".
    function removeFeed(PoolId poolId) external onlyOwner {
        delete _feeds[poolId];
        delete _cache[poolId];
        emit FeedRemoved(poolId);
    }

    /**
     * @notice Permanently disabled. Reverts for every caller.
     *
     * @dev CLAUDE.md § "Deployed and unfixable" makes this the house rule for every contract
     * deployed from here on, and `MerkleEpochDistributor` is the reference. The reason applies
     * with full force here.
     *
     * `configureFeed` and `removeFeed` are the only `onlyOwner` functions, and both are
     * REVERSIBLE — the owner can only choose which feed prices a pool, or withdraw one. Renouncing
     * therefore removes no power that could be abused. What it removes is the ability to repoint a
     * pool at a working aggregator after the current one is deprecated, retired, or repointed at an
     * aggregator with different decimals. Every pool this adapter serves would then run out its
     * `heartbeat` and halt, permanently and with no recovery, because `transferOwnership` is itself
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

    /// @notice Recompute a pool's cached reference from the aggregator's latest round.
    ///
    /// @dev PERMISSIONLESS, and that is a security property rather than a convenience. The caller
    /// supplies no price and cannot influence the result: every input comes from the aggregator and
    /// from owner-set configuration. The worst a hostile caller can do is refresh at a moment of
    /// their choosing, which is bounded by what Chainlink published and by `heartbeat`.
    ///
    /// Reverts rather than caching anything questionable. A revert leaves the previous cache in
    /// place; if that in turn ages past `heartbeat`, `referencePrice` reports unavailable and the
    /// consumer halts the pool. Both failure directions stop trading, neither lets an unverified
    /// price through.
    function refresh(PoolId poolId) external returns (uint160 sqrtPriceX96, uint64 roundUpdatedAt) {
        Feed memory feed = _feeds[poolId];
        if (feed.aggregator == address(0)) revert FeedNotConfigured(poolId);

        _requireSequencerUp();

        uint80 roundId;
        (roundId, sqrtPriceX96, roundUpdatedAt) = _read(feed);

        // Effects last: nothing above writes, and the external reads are all `view`. There is no
        // reentrancy surface here at all, but the ordering is kept explicit because a future edit
        // that adds one should have to move this line to break it.
        _cache[poolId] = Cached({sqrtPriceX96: sqrtPriceX96, roundUpdatedAt: roundUpdatedAt});
        emit ReferenceRefreshed(poolId, msg.sender, sqrtPriceX96, roundUpdatedAt, roundId);
    }

    /// @notice What `refresh` WOULD write, without writing it.
    /// @dev For a keeper deciding whether a refresh is worth the gas, and for an operator
    /// diagnosing why a pool has halted. Reverts with exactly the error `refresh` would, which is
    /// what makes a simulation a free read of every guard.
    function previewRefresh(PoolId poolId) external view returns (uint160 sqrtPriceX96, uint64 roundUpdatedAt) {
        Feed memory feed = _feeds[poolId];
        if (feed.aggregator == address(0)) revert FeedNotConfigured(poolId);
        _requireSequencerUp();
        (, sqrtPriceX96, roundUpdatedAt) = _read(feed);
    }

    /// @dev The shared body of `refresh` and `previewRefresh`. Every rejection below halts the pool
    /// rather than letting an unverified price through.
    function _read(Feed memory feed)
        internal
        view
        returns (uint80 roundId, uint160 sqrtPriceX96, uint64 roundUpdatedAt)
    {
        // A repointed proxy whose underlying aggregator reports different decimals would make every
        // conversion wrong by a power of ten. Checked live, not trusted from configuration time.
        uint8 live = AggregatorV3Interface(feed.aggregator).decimals();
        if (live != feed.feedDecimals) revert DecimalsChanged(feed.feedDecimals, live);

        int256 answer;
        uint256 updated;
        (roundId, answer,, updated,) = AggregatorV3Interface(feed.aggregator).latestRoundData();

        // `updatedAt == 0` is Chainlink's own marker for a round that was started but never
        // completed. Its `answer` is not a price.
        if (updated == 0) revert IncompleteRound(roundId);
        if (answer <= 0) revert NonPositiveAnswer(answer);

        // Future-dated rounds are tolerated for the same reason `MarketHoursModule` tolerates them:
        // oracle clocks and block timestamps disagree by seconds routinely, and halting a market
        // over clock skew is the wrong failure. Written as an addition rather than a subtraction so
        // a future-dated round cannot underflow.
        if (updated + feed.heartbeat < block.timestamp) {
            revert AnswerTooOld(updated, feed.heartbeat, block.timestamp);
        }

        uint256 raw = uint256(answer);
        if (raw > MAX_ANSWER) revert AnswerOutOfRange(raw);

        uint256 computed = _toSqrtPriceX96(raw, feed);
        if (computed < TickMath.MIN_SQRT_RATIO || computed > TickMath.MAX_SQRT_RATIO) {
            revert PriceOutOfRange(computed);
        }

        // Both narrowings are bounded above: `computed` by the range check, and `updated` by the
        // heartbeat check, which pins it to roughly now. `uint64` seconds runs to the year 584
        // billion, so a plausible round timestamp cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        sqrtPriceX96 = uint160(computed);
        // forge-lint: disable-next-line(unsafe-typecast)
        roundUpdatedAt = uint64(updated);
    }

    /*//////////////////////////////////////////////////////////////
                              CONVERSION
    //////////////////////////////////////////////////////////////*/

    /// @dev Chainlink's human price -> the pool's `sqrtPriceX96`. Written as an exact rational so
    /// the price is never rounded before the single square root at the end.
    ///
    /// Let `H = answer / 10**feedDecimals` be quote units per ONE WHOLE base unit. The pool's ratio
    /// is
    ///
    ///     R = currency1_smallest_units / currency0_smallest_unit
    ///
    /// With the base token as currency0:  R = H * 10**quoteDecimals / 10**baseDecimals
    /// With the base token as currency1:  R = 1 / that
    ///
    /// Collecting every power of ten into one numerator and one denominator avoids computing `H`
    /// (which is fractional) at all, and inverting is a SWAP of the two rather than a division.
    ///
    /// ---- THE TWO SCALES ----
    ///
    /// `sqrtPriceX96 = sqrt(R) * 2**96 = sqrt(R * 2**192)`, so the natural computation is
    /// `sqrt(mulDiv(num, 2**192, den))`. That is exact and loses nothing at the LOW end: core's
    /// `MIN_SQRT_RATIO` is `R = 2**-128`, where `R * 2**192` is still `2**64`.
    ///
    /// It breaks at the HIGH end. `mulDiv` reverts once the quotient passes `2**256`, i.e. once
    /// `R >= 2**64` — while core happily represents ratios up to `R ~= 2**128.6`. A pool with a
    /// 6-decimal token as currency0 and an 18-decimal token as currency1 crosses that at a human
    /// price of about 18.4, which is not an exotic pool. (`PythPriceBandAdapter._toSqrtPriceX96`
    /// handles this identically: the same two scales, the same exact branch condition, and the
    /// same `RatioUnrepresentable` rejection at `R >= 2**130`, so for the same `num / den` the two
    /// adapters return the same `sqrtPriceX96` or the same error.)
    ///
    /// So the scale is chosen from the ratio's magnitude, and the branch condition is exact:
    /// `(num >> 64) >= den` if and only if `num >= den * 2**64`, i.e. `R >= 2**64`.
    ///
    ///   R <  2**64   scale 2**192, result is `sqrt(R * 2**192)` directly.
    ///   R >= 2**64   scale 2**126, result is `sqrt(R * 2**126) << 33` — because
    ///                `sqrt(R * 2**126) = sqrt(R) * 2**63`, and `2**63 << 33 == 2**96`.
    ///
    /// The reduced branch keeps at least 95 significant bits in the square root (its input is at
    /// least `2**190`), so it costs nothing measurable in precision, and it cannot overflow: the
    /// pre-check rejects `R >= 2**130`, which is outside anything core can represent anyway.
    ///
    /// ---- ROUNDING: DOWN, EVERYWHERE, AND WHY THAT IS THE SAFE CHOICE ----
    ///
    /// `Math.mulDiv` and `Math.sqrt` both floor, so the reference is at most ONE unit of
    /// `sqrtPriceX96` below the exact value. Three reasons that is right:
    ///
    ///  1. IT IS NEGLIGIBLE AT THE SCALE THE BAND IS EXPRESSED IN. `MarketHoursModule` measures
    ///     the band in parts per million. A realistic reference is on the order of `2**96`, so a
    ///     one-unit floor is a relative error near `2**-96` — roughly twenty orders of magnitude
    ///     below one ppm. There is no band width for which this changes a decision.
    ///
    ///  2. IT IS UNIFORM, SO IT DOES NOT SYSTEMATICALLY LOOSEN EITHER SIDE. A reference that is
    ///     one unit low shifts the whole band down by one unit: the upper edge tightens by
    ///     the same amount the lower edge loosens. The failure a band must not have is a rounding
    ///     rule that widens BOTH edges, and flooring a single value cannot do that. The consumer
    ///     makes the same observation about its own floor in `_priceRatioPpm`.
    ///
    ///  3. IT MATCHES THE SIBLINGS BIT FOR BIT. `PythPriceBandAdapter` and every publisher writing
    ///     into `ManualPriceBandOracle` floor as well, so two adapters reading the same underlying
    ///     price agree exactly rather than differing by a unit. Agreement between price sources is
    ///     worth more here than the direction of a rounding error this small, because a discrepancy
    ///     is what makes an operator distrust a halt.
    ///
    /// Nothing is settled or paid out on this number — it is a policy threshold, not a price — so
    /// there is no party for a one-unit floor to extract value from.
    function _toSqrtPriceX96(uint256 answer, Feed memory feed) internal pure returns (uint256) {
        uint256 num = answer;
        uint256 den = 10 ** uint256(feed.feedDecimals);

        if (feed.quoteDecimals >= feed.baseDecimals) {
            // Cannot overflow: `answer <= MAX_ANSWER` (1e40) and the exponent is at most
            // `MAX_DECIMALS` (36), so this is at most 1e76 against a uint256 ceiling of ~1.16e77.
            num *= 10 ** uint256(uint8(feed.quoteDecimals - feed.baseDecimals));
        } else {
            // At most 1e36 * 1e36 = 1e72.
            den *= 10 ** uint256(uint8(feed.baseDecimals - feed.quoteDecimals));
        }

        // Reciprocal when the stablecoin sorted below the RWA token. Swapping the rational is
        // exact; inverting a computed decimal would not be.
        if (!feed.baseIsCurrency0) {
            (num, den) = (den, num);
        }

        // `den` is a product of powers of ten, or (after the swap) an `answer` already rejected
        // when non-positive, so it is never zero.
        if ((num >> 64) >= den) {
            // R >= 2**64. Reduced scale. Reject beyond 2**130 first, where even that overflows.
            if ((num >> 130) >= den) revert RatioUnrepresentable(num, den);
            // sqrt(R * 2**126) == sqrt(R) * 2**63; shifting up 33 gives sqrt(R) * 2**96.
            return Math.sqrt(Math.mulDiv(num, 1 << 126, den)) << 33;
        }

        // R < 2**64, so `num * 2**192 / den < 2**256`. `mulDiv` carries the intermediate at 512
        // bits, so the numerator itself cannot overflow either.
        return Math.sqrt(Math.mulDiv(num, 1 << 192, den));
    }

    /*//////////////////////////////////////////////////////////////
                            SEQUENCER UPTIME
    //////////////////////////////////////////////////////////////*/

    /// @dev The `refresh` side of the L2 check. Reverts with a named error so a keeper simulating
    /// the call learns exactly why, and so a monitor can distinguish "sequencer" from "price".
    function _requireSequencerUp() internal view {
        address uptimeFeed = sequencerUptimeFeed;
        // Absent by construction. The constructor said so in an event and `sequencerCheckEnabled`
        // says so on demand; nothing here pretends the sequencer was checked.
        if (uptimeFeed == address(0)) return;

        (bool readable, int256 answer, uint256 startedAt) = _readSequencer(uptimeFeed);
        if (!readable) revert SequencerFeedUnreadable();
        // Chainlink's convention: 0 is up, 1 is down. Anything else is not a status this contract
        // understands, and an unknown status is not evidence of uptime.
        if (answer != 0) revert SequencerDown();
        // `startedAt == 0` is the uptime feed's own marker for a round that has not been
        // initialised. It is not a claim that the sequencer came up at the epoch.
        if (startedAt == 0) revert SequencerFeedUnreadable();
        if (block.timestamp < startedAt + sequencerGracePeriod) {
            revert SequencerGracePeriod(startedAt, sequencerGracePeriod, block.timestamp);
        }
    }

    /// @dev The `referencePrice` side of the same check. Returns false instead of reverting,
    /// because the hot view is contracted never to revert.
    function _sequencerOk() internal view returns (bool) {
        address uptimeFeed = sequencerUptimeFeed;
        if (uptimeFeed == address(0)) return true; // absent, and loudly so. See the header.

        (bool readable, int256 answer, uint256 startedAt) = _readSequencer(uptimeFeed);
        if (!readable || answer != 0 || startedAt == 0) return false;
        return block.timestamp >= startedAt + sequencerGracePeriod;
    }

    /// @notice Read the uptime feed without letting it damage the caller.
    ///
    /// @dev A raw `staticcall` rather than a plain call, for the three reasons
    /// `MarketHoursModule._queryPriceOracle` gives about reading THIS contract: a hard gas bound so
    /// a looping or repointed proxy cannot consume the budget the module allowed us; a
    /// `returndatasize` check made BEFORE any copying, so a return bomb cannot force this frame to
    /// pay for memory expansion; and reading only the two words we need.
    ///
    /// A `staticcall` to an address with no code succeeds with `returndatasize == 0`, which fails
    /// the size check — so "the uptime feed is an EOA, was self-destructed, or is not deployed on
    /// this chain" reads as unreadable rather than silently succeeding with a zero answer, which
    /// would decode as "sequencer up".
    ///
    /// @return readable False if the feed reverted, exceeded its budget, is not a contract, or
    ///         returned anything other than exactly five words.
    function _readSequencer(address uptimeFeed)
        internal
        view
        returns (bool readable, int256 answer, uint256 startedAt)
    {
        // Bound to locals: inline assembly reads stack slots, not the constant table.
        uint256 gasBudget = SEQUENCER_GAS_LIMIT;
        uint256 returnSize = SEQUENCER_RETURN_SIZE;
        bytes4 selector = AggregatorV3Interface.latestRoundData.selector;

        assembly ("memory-safe") {
            // Scratch above the free-memory pointer; never read after this block, and the pointer
            // is not advanced, so no allocation is disturbed.
            let ptr := mload(0x40)
            mstore(ptr, selector)
            let out := add(ptr, 0x20)

            let ok := staticcall(gasBudget, uptimeFeed, ptr, 4, out, returnSize)

            if and(ok, eq(returndatasize(), returnSize)) {
                readable := 1
                // (roundId, answer, startedAt, updatedAt, answeredInRound); we need words 1 and 2.
                answer := mload(add(out, 0x20))
                startedAt := mload(add(out, 0x40))
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IPriceBandOracle
    ///
    /// @dev Two SLOADs, plus one bounded staticcall when an uptime feed is configured. Never
    /// reverts: every failure is `(0, 0)`, which the consumer treats as unavailable and which
    /// rejects the swap rather than skipping the band check.
    ///
    /// The timestamp reported is THE AGGREGATOR'S round timestamp, not the time `refresh` ran. That
    /// is the meaningful one: a cache refreshed a second ago from an hour-old round is an hour-old
    /// price, and the consumer's own staleness window must be able to see that. It is also what
    /// makes the whole arrangement fail closed — if nobody refreshes, the number ages out and
    /// trading halts rather than continuing against a stale reference.
    ///
    /// The `heartbeat` is read from the FEED CONFIG rather than copied into the cache, on purpose.
    /// An owner who shortens a heartbeat is tightening a freshness policy, and a tightening must
    /// bite immediately; a cached copy would leave the old, looser window in force until somebody
    /// refreshed — which is the wrong direction for a safety parameter to lag in.
    function referencePrice(PoolId poolId) external view override returns (uint160 sqrtPriceX96, uint64 updatedAt) {
        Feed storage f = _feeds[poolId];
        uint32 heartbeat = f.heartbeat;
        // `heartbeat == 0` is unreachable for a configured feed (`configureFeed` rejects it), so it
        // is exactly the "no feed" case. One slot answers both questions.
        if (heartbeat == 0) return (0, 0);

        Cached storage c = _cache[poolId];
        uint160 cachedPrice = c.sqrtPriceX96;
        uint64 cachedAt = c.roundUpdatedAt;
        if (cachedPrice == 0) return (0, 0); // never refreshed

        // Addition, not subtraction: a future-dated round must not underflow into "fresh forever".
        if (uint256(cachedAt) + uint256(heartbeat) < block.timestamp) return (0, 0);

        if (!_sequencerOk()) return (0, 0);

        return (cachedPrice, cachedAt);
    }

    /// @notice Whether this deployment consults an L2 sequencer-uptime feed at all.
    /// @dev FALSE MEANS THE CHECK IS ABSENT, not that the sequencer is up. On an L2, a deployment
    /// reading false can be traded through during a sequencer restart: queued swaps execute in a
    /// burst against whatever was last cached, and only the feed's `heartbeat` limits how stale
    /// that is. Surfaced as a getter so a UI, a monitor or a reviewer can state the posture without
    /// having to read constructor arguments off a block explorer.
    function sequencerCheckEnabled() external view returns (bool) {
        return sequencerUptimeFeed != address(0);
    }

    /// @notice The live sequencer status as this contract sees it.
    /// @param enabled Whether an uptime feed is configured at all.
    /// @param ok Whether a price would be served right now. Always true when `enabled` is false —
    ///        which is the absence of a check, not the presence of an "up" answer.
    /// @param upSince The `startedAt` of the current uptime round, or 0 when unavailable.
    function sequencerStatus() external view returns (bool enabled, bool ok, uint256 upSince) {
        address uptimeFeed = sequencerUptimeFeed;
        enabled = uptimeFeed != address(0);
        if (!enabled) return (false, true, 0);
        (bool readable, int256 answer, uint256 startedAt) = _readSequencer(uptimeFeed);
        upSince = readable ? startedAt : 0;
        ok = readable && answer == 0 && startedAt != 0 && block.timestamp >= startedAt + sequencerGracePeriod;
    }

    /// @notice The feed configured for a pool. `aggregator == address(0)` means none.
    function feedFor(PoolId poolId) external view returns (Feed memory) {
        return _feeds[poolId];
    }

    /// @notice The raw cache for a pool, ignoring staleness and the sequencer.
    /// @dev For operators. `referencePrice` is the one that applies the policy; this is the one
    /// that shows what the policy is being applied to.
    function cachedReference(PoolId poolId) external view returns (Cached memory) {
        return _cache[poolId];
    }

    /// @notice The aggregator's own self-description, for a UI confirming an operator pointed a
    /// pool at the feed they meant.
    /// @dev Not called on any hot path — `description()` returns a string and is unbounded, which
    /// is exactly why it appears here and nowhere near `referencePrice`.
    function feedDescription(PoolId poolId) external view returns (string memory) {
        address aggregator = _feeds[poolId].aggregator;
        if (aggregator == address(0)) revert FeedNotConfigured(poolId);
        return AggregatorV3Interface(aggregator).description();
    }
}
