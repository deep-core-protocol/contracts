/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {FullMath} from "infinity-core/src/pool-cl/libraries/FullMath.sol";

import {IPriceBandOracle} from "../interfaces/IPriceBandOracle.sol";

/// @title MarketHoursModule
/// @notice The three controls a tokenized-equity pool needs that a 24/7 AMM does not provide: a
/// trading calendar, an instant halt, and a price band enforced against a pluggable reference
/// oracle. Written as a mixin so it can be worn by a bare hook (`MarketHoursHook`) or bolted onto
/// the compliance gate (`StockPairHook`) without either one duplicating the other.
///
/// @dev ################### NO LEGAL ADVICE IS GIVEN OR IMPLIED ###################
///
/// This contract is a MECHANISM. It stops a pool trading outside hours an issuer chose, while an
/// issuer-chosen party says it is halted, and at prices outside a band an issuer-chosen oracle
/// implies. Whether any configuration of it discharges any market-structure obligation, listing
/// rule, exchange registration requirement, limit-up/limit-down regime, best-execution duty or
/// fair-and-orderly-market standard in any jurisdiction is a question for the issuer's counsel. It
/// is not answered here, it is not answered by the code, and no statement in this repository
/// should be read as answering it.
///
/// In particular: naming a control "circuit breaker" does not make it one in the regulatory sense,
/// and matching a venue's published session times does not make this pool that venue.
///
/// #####################################################################################
/// ############################ 1. THE TRADING CALENDAR ############################
/// #####################################################################################
///
/// A weekly base schedule plus per-day overrides, both resolved in O(1). Everything is UTC.
///
///   * `weekdayMask` - bit `i` set means weekday `i` is a trading day, with 0 = Sunday. Unix day 0
///     (1970-01-01) was a Thursday, so the weekday of day index `d` is `(d + 4) % 7`. Bit 7 is
///     reserved and refused (`InvalidWeekdayMask`).
///   * `openSecondOfDay` / `closeSecondOfDay` - the session window within a trading day. `open <
///     close` is an ordinary same-day session. `open > close` WRAPS past midnight and the session
///     is attributed to the day it OPENED on, which is the day whose weekday bit and whose
///     override are consulted. `open == close` is rejected at configuration time as ambiguous.
///   * Per-day overrides, keyed by `timestamp / 86400`, express holidays (`setHolidays`) and
///     half-days or special sessions (`setSpecialSessions`). An override REPLACES the weekday mask
///     for that day, which is how a special Saturday auction is scheduled.
///
/// AN OVERRIDE ON DAY D GOVERNS THE SESSION THAT OPENS ON D, NOT THE UTC CALENDAR DAY D. On a
/// same-day schedule the two are identical. On a WRAPPING schedule they are not, and the
/// difference is the part an issuer gets wrong:
///
///   * A holiday on D cancels D's session, including its tail into D+1. It does NOT close the tail
///     of D-1's session, which still trades from midnight until close on D.
///   * To stop ALL trading during UTC day D, write the holiday on D AND a non-wrapping special
///     session on D-1 ending at 86399 (the D-1 session then loses its final second).
///   * A venue whose overnight session belongs to the NEXT trade date - the usual convention for
///     an evening session - must write that trade date's holiday on the day BEFORE it, the day the
///     session opens. Translating an exchange holiday calendar date-for-date is wrong here.
///
/// THERE IS NO TIMEZONE AND NO DAYLIGHT SAVING. UTC does not observe DST; a venue that does will
/// shift by an hour twice a year relative to any fixed UTC window, and the schedule must be
/// re-cut when it does. `setSessionHours` exists for exactly that and is available to the issuer
/// without governance delay. An issuer who forgets will run an hour early or an hour late - which
/// is a visible, self-correcting error, unlike the alternative of encoding a DST table on-chain
/// and being wrong about a future rule change nobody can amend.
///
/// #####################################################################################
/// ############################ 2. THE HALT ############################
/// #####################################################################################
///
/// Three roles, deliberately asymmetric, following the guardian pattern used elsewhere in this
/// repository: a role may be handed the power to make the market MORE restricted without
/// governance delay; making it LESS restricted is the slower path.
///
///   * `guardian` (global, owner-set) - may ONLY `halt`. It cannot resume, cannot touch the
///     calendar, cannot touch the oracle, and cannot touch the band. A compromised guardian can
///     stop trading in every pool on this hook, which is visible, reversible by the issuer or the
///     owner, and costs nobody their funds. That asymmetry is what makes it safe to hand this to a
///     fast-moving incident desk or a keeper watching a feed.
///
///   * `issuer` (per-pool, owner-set) - runs the market day to day: `halt`, `resume`,
///     `setSessionHours`, `setHolidays`, `setSpecialSessions`, `clearDayOverrides`. It CANNOT
///     change the oracle, the band widths, the staleness window, or who the issuer is.
///
///   * owner - governance. Everything, including `configureMarket`, which is the only way the
///     oracle, the bands and the issuer address move, and `resetCalendar`, which discards every day
///     override on a pool in O(1). Rotating an issuer does NOT discard its calendar; an ousted
///     issuer's holidays stay in force until the owner resets them.
///
/// `halt` is instant and takes no argument that could fail. `resume` requires the issuer or the
/// owner. That is the "one-way-ish" part: the fast key only ever stops things.
///
/// #####################################################################################
/// ############################ 3. THE PRICE BAND ############################
/// #####################################################################################
///
/// Enforced in `afterSwap`, against the price the pool ACTUALLY ENDED AT, because that is the only
/// place the resulting print is knowable. The rule is a pure function of two things - the
/// post-swap price and the swap's direction - and it is:
///
///     A swap may not leave the pool priced outside the band, UNLESS it moved the price TOWARD
///     the band. `zeroForOne` decreases `sqrtPriceX96`; `!zeroForOne` increases it.
///
///       post above the upper edge + price-increasing swap  -> REJECT (a divergent print)
///       post above the upper edge + price-decreasing swap  -> ALLOW  (converging: pre >= post)
///       post below the lower edge + price-decreasing swap  -> REJECT
///       post below the lower edge + price-increasing swap  -> ALLOW  (converging)
///       post inside the band                               -> ALLOW
///
/// The exception is not a loophole, it is the thing that makes the control usable. A tokenized
/// equity gaps overnight: the reference moves while the pool sits where it closed. Without the
/// converging exception, the pool wakes up outside its own band and EVERY swap reverts, including
/// the arbitrage that would bring it back - a permanent, unrecoverable lockout caused by the
/// safety control itself. Because an AMM's price is monotone in the swap direction, a converging
/// swap can never end further from the band than it started, so permitting it cannot be used to
/// print a worse price than the pool already showed.
///
/// That argument only holds if every price the pool has shown was either band-checked or became
/// out-of-band because the REFERENCE moved. The one price no swap produces is the birth price, so
/// the hooks mixing this in also check it in `beforeInitialize`, strictly and with no converging
/// exception (`_requireInitialPriceInBand`). A front-runner may still choose where inside the band
/// a pool is born; the band width is the ceiling on that, not zero.
///
/// WHAT THE BAND DOES NOT DO, STATED PLAINLY:
///
///   * It does not bound the price of EVERY trade inside a swap, only the price the swap ends at.
///     A single large swap can start at the lower edge and end at the upper edge, executing
///     through the whole band on the way. Bounding execution is what `sqrtPriceLimitX96` and
///     `PermissionedPoolHook.maxSwapPerTx` are for; use them together with this.
///   * It does not stop the price being wrong. It stops the pool PRINTING further wrong. If the
///     reference oracle is wrong, the band is wrong in exactly the same direction.
///   * It is not a stop on cross-venue arbitrage, a last-look, or a minimum quote life.
///
/// FAILURE IS CLOSED. If the oracle reverts, exceeds its gas budget, is not a contract, returns
/// the wrong number of bytes, returns a zero price, or returns a price older than `maxPriceAge`,
/// the swap REVERTS. Losing the reference price is a reason to stop trading, not a reason to trade
/// unbounded. The corollary an issuer must accept: AN ORACLE OUTAGE HALTS THE POOL. The band is
/// therefore opt-in per pool (`bandEnabled`), and the oracle should be operated with that in mind.
///
/// LIQUIDITY IS NEVER TRAPPED BY THIS MODULE. Nothing here touches the removal path. A halt, a
/// closed session and a dead price oracle all leave `beforeRemoveLiquidity` exactly as the hook
/// that mixes this in left it - which in `PermissionedPoolHook`'s case is deliberately open. A
/// control that can confiscate LP capital by being switched on is not a control anyone should
/// ship.
/// #####################################################################################
abstract contract MarketHoursModule {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Caller is not the governance owner of this hook
    error NotMarketAdmin(address caller);

    /// @notice Caller is neither this pool's issuer nor the governance owner
    error NotMarketOperator(address caller);

    /// @notice Caller holds none of the three roles permitted to halt
    error NotHaltAuthority(address caller);

    /// @notice The owner has not configured market hours for this pool id
    error MarketNotConfigured(PoolId poolId);

    /// @notice Trading is halted for this pool
    error TradingHalted(PoolId poolId);

    /// @notice The pool is outside its trading session
    error MarketClosed(PoolId poolId, uint256 timestamp);

    /// @notice A session window that is ambiguous or out of range
    error InvalidSessionWindow(uint24 openSecondOfDay, uint24 closeSecondOfDay);

    /// @notice A session was enabled with no trading weekdays, which would close the pool forever
    error EmptyWeekdayMask();

    /// @notice A weekday mask set a bit outside 0-6. There are seven weekdays; bit 7 names none.
    /// @dev Distinct from `EmptyWeekdayMask` because the two are different mistakes: `0xFF` names
    /// all seven days AND a reserved bit, so calling it "empty" would be false. Carries the mask,
    /// like `InvalidSessionWindow` carries its window, so the caller sees what was refused.
    error InvalidWeekdayMask(uint8 weekdayMask);

    /// @notice A downward band wider than 100%, which cannot be expressed as a price
    error InvalidBandWidth(uint32 maxDownPpm);

    /// @notice The band was enabled without an oracle to judge it against
    error BandEnabledWithoutOracle();

    /// @notice A pool cannot name the zero address as its issuer
    error MarketZeroAddress();

    /// @notice Not enough gas remains to give the price oracle its full budget.
    /// @dev EIP-150 forwards at most 63/64 of the remaining gas, so a caller who sets a tight gas
    /// limit could otherwise starve the oracle call and make it read as unavailable. That already
    /// fails closed, so this is not a bypass - it is a diagnostic, so an operator sees "you sent
    /// too little gas" rather than being told their oracle is broken.
    error InsufficientGasForPriceOracle(uint256 gasLeft);

    /// @notice The price oracle reverted, exceeded its gas budget, returned the wrong number of
    /// bytes, is not a contract, or reported a zero price.
    error PriceOracleUnavailable(address oracle, PoolId poolId);

    /// @notice The reference price is older than the pool's staleness window
    error ReferencePriceStale(uint64 updatedAt, uint32 maxPriceAge, uint256 nowTimestamp);

    /// @notice The swap would have left the pool priced outside its band, moving away from it.
    /// @param ratioPpm Post-swap pool price as parts-per-million of the reference (1e6 == parity).
    error PriceBandBreached(PoolId poolId, uint256 ratioPpm, uint256 lowerPpm, uint256 upperPpm);

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted on every accepted `configureMarket`, including the first
    event MarketConfigured(
        PoolId indexed poolId,
        address indexed issuer,
        address indexed oracle,
        uint8 weekdayMask,
        uint24 openSecondOfDay,
        uint24 closeSecondOfDay,
        uint32 maxUpPpm,
        uint32 maxDownPpm,
        uint32 maxPriceAge,
        bool sessionEnabled,
        bool bandEnabled,
        bool gateLiquidity
    );

    /// @notice Emitted when the issuer re-cuts the weekly schedule (a DST shift, a session change)
    event SessionHoursSet(
        PoolId indexed poolId, address indexed by, uint8 weekdayMask, uint24 openSecondOfDay, uint24 closeSecondOfDay
    );

    /// @notice Emitted for every day whose override is written or cleared
    event DayOverrideSet(
        PoolId indexed poolId, uint32 indexed dayIndex, bool closed, uint24 openSecondOfDay, uint24 closeSecondOfDay
    );

    /// @notice Emitted for every day whose override is removed
    event DayOverrideCleared(PoolId indexed poolId, uint32 indexed dayIndex);

    /// @notice Emitted when the owner discards every day override on a pool. An indexer must drop
    /// every `DayOverrideSet` it holds for this pool from before this event.
    event CalendarReset(PoolId indexed poolId, address indexed by, uint32 newEpoch);

    /// @notice Emitted when trading is halted. The highest-signal event on this module.
    event TradingHaltedEvent(PoolId indexed poolId, address indexed by, bytes32 reason);

    /// @notice Emitted when trading resumes
    event TradingResumed(PoolId indexed poolId, address indexed by);

    /// @notice Emitted when the global halt-only guardian changes
    event MarketGuardianSet(address indexed previous, address indexed current);

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Denominator for every band width and price ratio in this module
    uint256 public constant PPM = 1_000_000;

    /// @notice Seconds in a UTC day. There are no leap seconds in Unix time.
    uint256 public constant SECONDS_PER_DAY = 86_400;

    /// @notice Gas forwarded to the price oracle, per query.
    /// @dev Bounded so a broken or hostile feed cannot burn the trader's whole gas budget. An
    /// oracle needing more than this reads as unavailable, which is the fail-closed direction.
    uint256 public constant PRICE_ORACLE_GAS_LIMIT = 200_000;

    /// @notice Gas that must remain before the oracle is queried.
    /// @dev EIP-150 forwards at most 63/64 of what is left, so holding `LIMIT * 64 / 63` is what
    /// guarantees the callee actually receives its full budget. The 30k reserve covers the band
    /// arithmetic and the revert that may follow. See `DeepCoreRegistry.PROBE_GAS_FLOOR`.
    uint256 public constant PRICE_ORACLE_GAS_FLOOR =
        PRICE_ORACLE_GAS_LIMIT + PRICE_ORACLE_GAS_LIMIT / 63 + 30_000;

    /// @notice Exact ABI return size of `IPriceBandOracle.referencePrice`: two words.
    /// @dev Compared against `returndatasize` before anything is copied, which is what defeats a
    /// return bomb.
    uint256 internal constant PRICE_ORACLE_RETURN_SIZE = 0x40;

    /// @dev Ceiling on the sqrt-price ratio (in PPM) above which the squaring step is skipped.
    /// A sqrt ratio of 1e9 is a price ratio of 1e18, i.e. 1e20 percent. The widest band this
    /// module can express is `type(uint32).max` PPM (~429,400%), whose sqrt ratio in PPM is under
    /// 6.6e7 - four hundred thousand times smaller. So anything above this clamp is unambiguously
    /// outside any expressible band, and clamping lets the squaring run in plain 256-bit
    /// arithmetic with no overflow rather than needing a second `mulDiv`.
    uint256 internal constant SQRT_RATIO_PPM_CLAMP = 1e15;

    /// @dev The only bits of `weekdayMask` that `_scheduleForDay` ever reads: bit `i` for weekday
    /// `i`, 0 = Sunday through 6 = Saturday. Any other bit is refused at every write, so the stored
    /// mask and the enforced mask are always the same number.
    uint8 internal constant WEEKDAY_MASK_BITS = 0x7F;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    /// @param configured Set by `configureMarket`. A hook mixing this in should refuse to
    ///        initialize an unconfigured pool, so an initialized pool is always a configured one.
    /// @param halted Instant trading stop. Independent of the calendar and of any global pause.
    /// @param sessionEnabled Whether the calendar is enforced at all. False means 24/7.
    /// @param gateLiquidity Whether the halt and the calendar also block ADDING liquidity. They
    ///        never block removing it.
    /// @param bandEnabled Whether the price band is enforced. Requires `oracle != address(0)`.
    ///        Explicit rather than inferred from the oracle address, so that rotating an oracle
    ///        cannot silently switch the circuit breaker off.
    /// @param weekdayMask Bit `i` = weekday `i` is a trading day, 0 = Sunday.
    /// @param openSecondOfDay Session open, seconds since UTC midnight, inclusive.
    /// @param closeSecondOfDay Session close, seconds since UTC midnight, exclusive. Less than
    ///        `openSecondOfDay` means the session wraps past midnight into the following day.
    /// @param issuer Per-pool operator. See the role note in the contract documentation.
    /// @param oracle Reference-price source for the band.
    /// @param maxUpPpm Permitted deviation ABOVE the reference, in PPM. 0 permits none.
    /// @param maxDownPpm Permitted deviation BELOW the reference, in PPM. Capped at `PPM`.
    /// @param maxPriceAge Staleness window for the reference, in seconds. 0 disables the check,
    ///        which means the oracle is trusted to report only prices it stands behind.
    struct MarketConfig {
        // ---- slot 0: 5 bools + uint8 + 2x uint24 + address = 32 bytes exactly ----
        bool configured;
        bool halted;
        bool sessionEnabled;
        bool gateLiquidity;
        bool bandEnabled;
        uint8 weekdayMask;
        uint24 openSecondOfDay;
        uint24 closeSecondOfDay;
        address issuer;
        // ---- slot 1: address + 3x uint32 = 32 bytes exactly ----
        IPriceBandOracle oracle;
        uint32 maxUpPpm;
        uint32 maxDownPpm;
        uint32 maxPriceAge;
    }

    /// @notice Owner-supplied configuration. Mirrors `MarketConfig` minus the two fields the
    /// module owns: `configured`, which only it may set, and `halted`, which `configureMarket`
    /// deliberately does not touch so that reconfiguring a halted pool cannot un-halt it.
    struct MarketSettings {
        address issuer;
        IPriceBandOracle oracle;
        uint32 maxUpPpm;
        uint32 maxDownPpm;
        uint32 maxPriceAge;
        uint24 openSecondOfDay;
        uint24 closeSecondOfDay;
        uint8 weekdayMask;
        bool sessionEnabled;
        bool bandEnabled;
        bool gateLiquidity;
    }

    /// @param isSet Whether this day has an override at all. A cleared day reads back false and
    ///        falls through to the weekly schedule.
    /// @param closed The day is a holiday: no session OPENS on it, whatever the weekday mask says.
    ///        On a wrapping schedule the previous day's session still runs into this day until its
    ///        close; see "AN OVERRIDE ON DAY D" in the contract documentation.
    /// @param openSecondOfDay Replacement session open for this day.
    /// @param closeSecondOfDay Replacement session close for this day.
    struct DayOverride {
        bool isSet;
        bool closed;
        uint24 openSecondOfDay;
        uint24 closeSecondOfDay;
    }

    /// @notice Per-pool market configuration
    mapping(PoolId poolId => MarketConfig) internal _markets;

    /// @notice Per-pool calendar exceptions, keyed by calendar epoch and then `timestamp / 86400`.
    /// @dev A mapping rather than a list, so resolving a day is one storage read and there is
    /// never a loop over a growable set on the swap path. Only the pool's CURRENT epoch
    /// (`_calendarEpoch`) is ever read; overrides written under an earlier epoch are unreachable.
    mapping(PoolId poolId => mapping(uint32 epoch => mapping(uint32 dayIndex => DayOverride))) internal
        _dayOverrides;

    /// @notice Global address permitted to halt any pool on this hook, and to do nothing else.
    /// @dev See the role note. This address can stop trading; it can never start it.
    address public marketGuardian;

    /// @notice Per-pool calendar generation. `resetCalendar` advances it, which orphans every day
    /// override written before, in O(1).
    /// @dev Without it, a rogue or compromised issuer could write thousands of future holidays and
    /// governance could replace the issuer but not the calendar: `configureMarket` leaves overrides
    /// alone, and `clearDayOverrides` is O(n) over an attacker-chosen n. `configureMarket` still does
    /// NOT advance it, on purpose - rotating an issuer for an ordinary reason must not silently delete
    /// a year of legitimate holidays and reopen those days to trading. Declared after every
    /// pre-existing slot.
    mapping(PoolId poolId => uint32 epoch) internal _calendarEpoch;

    /*//////////////////////////////////////////////////////////////
                        AUTHORISATION (mixin seam)
    //////////////////////////////////////////////////////////////*/

    /// @dev The governance address of the hook mixing this in. Concrete hooks return `owner()`.
    /// Kept abstract so this module carries no ownership implementation of its own and can be
    /// combined with a hook that already has one.
    function _marketAdmin() internal view virtual returns (address);

    /// @dev Reject a pool key that does not belong to this hook, so a misconfiguration surfaces at
    /// configuration time rather than at pool creation. Concrete hooks check `key.hooks`,
    /// `key.poolManager` and the fee flag.
    function _requireOwnPoolKey(PoolKey calldata key) internal view virtual;

    modifier onlyMarketAdmin() {
        if (msg.sender != _marketAdmin()) revert NotMarketAdmin(msg.sender);
        _;
    }

    /// @dev Issuer or owner. The day-to-day operating seat.
    modifier onlyMarketOperator(PoolId poolId) {
        if (msg.sender != _markets[poolId].issuer && msg.sender != _marketAdmin()) {
            revert NotMarketOperator(msg.sender);
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                             ADMINISTRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Create or replace the market configuration for `key`'s pool. Owner only.
    /// @dev Does NOT clear `halted`. Reconfiguring a halted pool leaves it halted; use `resume`,
    /// which is a separate call with a separate event, so "the market reopened" is never a side
    /// effect of "the market was reconfigured".
    function configureMarket(PoolKey calldata key, MarketSettings calldata settings) external onlyMarketAdmin {
        _requireOwnPoolKey(key);
        _validateSettings(settings);

        PoolId poolId = key.toId();
        MarketConfig storage cfg = _markets[poolId];

        cfg.configured = true;
        cfg.sessionEnabled = settings.sessionEnabled;
        cfg.gateLiquidity = settings.gateLiquidity;
        cfg.bandEnabled = settings.bandEnabled;
        cfg.weekdayMask = settings.weekdayMask;
        cfg.openSecondOfDay = settings.openSecondOfDay;
        cfg.closeSecondOfDay = settings.closeSecondOfDay;
        cfg.issuer = settings.issuer;
        cfg.oracle = settings.oracle;
        cfg.maxUpPpm = settings.maxUpPpm;
        cfg.maxDownPpm = settings.maxDownPpm;
        cfg.maxPriceAge = settings.maxPriceAge;

        emit MarketConfigured(
            poolId,
            settings.issuer,
            address(settings.oracle),
            settings.weekdayMask,
            settings.openSecondOfDay,
            settings.closeSecondOfDay,
            settings.maxUpPpm,
            settings.maxDownPpm,
            settings.maxPriceAge,
            settings.sessionEnabled,
            settings.bandEnabled,
            settings.gateLiquidity
        );
    }

    /// @notice Re-cut the weekly schedule. Issuer or owner.
    /// @dev The DST lever, and the reason the issuer holds it: a schedule change that has to queue
    /// behind a governance timelock arrives after the session it was meant to describe.
    function setSessionHours(PoolId poolId, uint8 weekdayMask, uint24 openSecondOfDay, uint24 closeSecondOfDay)
        external
        onlyMarketOperator(poolId)
    {
        MarketConfig storage cfg = _markets[poolId];
        if (!cfg.configured) revert MarketNotConfigured(poolId);
        // Validated unconditionally, even on a pool whose session is currently disabled: an inert
        // field that is nonsense today becomes an enforced field the moment somebody enables the
        // session, and that is a bad moment to discover it.
        if (weekdayMask == 0) revert EmptyWeekdayMask();
        _requireOnlyWeekdayBits(weekdayMask);
        _validateWindowTimes(openSecondOfDay, closeSecondOfDay);

        cfg.weekdayMask = weekdayMask;
        cfg.openSecondOfDay = openSecondOfDay;
        cfg.closeSecondOfDay = closeSecondOfDay;

        emit SessionHoursSet(poolId, msg.sender, weekdayMask, openSecondOfDay, closeSecondOfDay);
    }

    /// @notice Cancel the session that OPENS on each of these days. Issuer or owner.
    /// @dev On a same-day schedule this closes the whole day. On a wrapping schedule it does not
    /// close the tail of the PREVIOUS day's session, which still trades into these days until its
    /// close; see "AN OVERRIDE ON DAY D" in the contract documentation for the two-override recipe.
    ///
    /// Bounded by the calldata array the caller pays for; there is no growable set to loop.
    function setHolidays(PoolId poolId, uint32[] calldata dayIndexes) external onlyMarketOperator(poolId) {
        mapping(uint32 dayIndex => DayOverride) storage overrides = _dayOverrides[poolId][_calendarEpoch[poolId]];
        for (uint256 i = 0; i < dayIndexes.length; ++i) {
            uint32 dayIndex = dayIndexes[i];
            overrides[dayIndex] = DayOverride({isSet: true, closed: true, openSecondOfDay: 0, closeSecondOfDay: 0});
            emit DayOverrideSet(poolId, dayIndex, true, 0, 0);
        }
    }

    /// @notice Give specific days their own session window. Issuer or owner.
    /// @dev Half-days, early closes, and special sessions on a day the weekday mask excludes: an
    /// override REPLACES the mask for that day rather than intersecting with it.
    function setSpecialSessions(
        PoolId poolId,
        uint32[] calldata dayIndexes,
        uint24 openSecondOfDay,
        uint24 closeSecondOfDay
    ) external onlyMarketOperator(poolId) {
        // No weekday mask to check: an override names its days explicitly.
        _validateWindowTimes(openSecondOfDay, closeSecondOfDay);
        mapping(uint32 dayIndex => DayOverride) storage overrides = _dayOverrides[poolId][_calendarEpoch[poolId]];
        for (uint256 i = 0; i < dayIndexes.length; ++i) {
            uint32 dayIndex = dayIndexes[i];
            overrides[dayIndex] = DayOverride({
                isSet: true,
                closed: false,
                openSecondOfDay: openSecondOfDay,
                closeSecondOfDay: closeSecondOfDay
            });
            emit DayOverrideSet(poolId, dayIndex, false, openSecondOfDay, closeSecondOfDay);
        }
    }

    /// @notice Remove overrides, returning those days to the weekly schedule. Issuer or owner.
    function clearDayOverrides(PoolId poolId, uint32[] calldata dayIndexes) external onlyMarketOperator(poolId) {
        mapping(uint32 dayIndex => DayOverride) storage overrides = _dayOverrides[poolId][_calendarEpoch[poolId]];
        for (uint256 i = 0; i < dayIndexes.length; ++i) {
            uint32 dayIndex = dayIndexes[i];
            delete overrides[dayIndex];
            emit DayOverrideCleared(poolId, dayIndex);
        }
    }

    /// @notice Discard EVERY day override on this pool in one call. Owner only.
    /// @dev The O(1) remedy for a calendar written by an issuer governance no longer trusts. Advances
    /// the pool's calendar epoch, so every holiday and special session written before is unreachable
    /// and each day falls back to the weekly schedule. The old entries are not deleted (that would
    /// be the O(n) walk this replaces); they are simply never read again, and a later reset never
    /// brings them back.
    ///
    /// Owner only, never the issuer: wiping holidays REOPENS those days to trading, which is the
    /// less-restrictive direction and belongs on the slower key. Deliberately separate from
    /// `configureMarket`, so the recovery is `configureMarket` (rotate the issuer) then
    /// `resetCalendar`, and the new issuer re-writes whatever legitimate calendar should stand. Does
    /// not touch `halted`, the weekly schedule, the band or the issuer - halt first if the gap
    /// between the reset and the re-written calendar matters.
    function resetCalendar(PoolId poolId) external onlyMarketAdmin {
        if (!_markets[poolId].configured) revert MarketNotConfigured(poolId);
        uint32 epoch = _calendarEpoch[poolId] + 1;
        _calendarEpoch[poolId] = epoch;
        emit CalendarReset(poolId, msg.sender, epoch);
    }

    /// @notice Stop trading in this pool, immediately. Owner, issuer or guardian.
    /// @dev Deliberately the cheapest and most available action in this module. It takes one
    /// storage write, it cannot fail on a configuration problem, and three different keys can
    /// reach it - because the situation it exists for is one where the correct move is to stop
    /// and work out what happened afterwards.
    ///
    /// Halting does not touch removals. LPs can exit a halted pool.
    function halt(PoolId poolId, bytes32 reason) external {
        MarketConfig storage cfg = _markets[poolId];
        if (!cfg.configured) revert MarketNotConfigured(poolId);
        if (msg.sender != cfg.issuer && msg.sender != _marketAdmin() && msg.sender != marketGuardian) {
            revert NotHaltAuthority(msg.sender);
        }

        cfg.halted = true;
        emit TradingHaltedEvent(poolId, msg.sender, reason);
    }

    /// @notice Resume trading. Owner or issuer ONLY - never the guardian.
    /// @dev This is the asymmetry. The fast key stops the market; restarting it requires a party
    /// with standing to say the market should reopen.
    function resume(PoolId poolId) external onlyMarketOperator(poolId) {
        MarketConfig storage cfg = _markets[poolId];
        if (!cfg.configured) revert MarketNotConfigured(poolId);

        cfg.halted = false;
        emit TradingResumed(poolId, msg.sender);
    }

    /// @notice Set the global halt-only guardian. Owner only.
    /// @dev `address(0)` disables the role. The guardian can halt every pool on this hook, so this
    /// is a real power - but strictly a restricting one, which is why it does not need a timelock
    /// to be safe to delegate.
    function setMarketGuardian(address guardian) external onlyMarketAdmin {
        address previous = marketGuardian;
        marketGuardian = guardian;
        emit MarketGuardianSet(previous, guardian);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @notice Full market configuration for a pool id
    function marketConfig(PoolId poolId) external view returns (MarketConfig memory) {
        return _markets[poolId];
    }

    /// @notice The override in force, if any, for one day index (current calendar epoch only)
    function dayOverride(PoolId poolId, uint32 dayIndex) external view returns (DayOverride memory) {
        return _dayOverrides[poolId][_calendarEpoch[poolId]][dayIndex];
    }

    /// @notice The pool's calendar epoch; advanced only by `resetCalendar`.
    function calendarEpoch(PoolId poolId) external view returns (uint32) {
        return _calendarEpoch[poolId];
    }

    /// @notice The day index a timestamp falls in. `timestamp / 86400`, UTC.
    /// @dev The cast cannot truncate for any timestamp this chain will ever see: `uint32` day
    /// indexes run to the year 11,700,000. It would truncate only for a caller who passed a
    /// hand-made value above that, and this is a `pure` helper with no authority over anything.
    function dayIndexOf(uint256 timestamp) public pure returns (uint32) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(timestamp / SECONDS_PER_DAY);
    }

    /// @notice The UTC weekday of a day index, 0 = Sunday.
    /// @dev Unix day 0 (1970-01-01) was a Thursday, hence the `+ 4`.
    function weekdayOf(uint32 dayIndex) public pure returns (uint8) {
        // The modulus is 7, so the result is 0-6. It cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint8((uint256(dayIndex) + 4) % 7);
    }

    /// @notice Whether the calendar says this pool is inside a session at `timestamp`.
    /// @dev Ignores the halt and the band. `true` here does not mean a swap will succeed.
    function isSessionOpenAt(PoolId poolId, uint256 timestamp) external view returns (bool) {
        MarketConfig storage cfg = _markets[poolId];
        if (!cfg.configured) return false;
        if (!cfg.sessionEnabled) return true;
        return _sessionOpen(poolId, cfg, timestamp);
    }

    /// @notice Whether a swap could be accepted right now on calendar and halt grounds alone.
    /// @dev For routers and front-ends. Does NOT evaluate the price band, which depends on the
    /// price the swap would end at and so cannot be answered without the swap.
    function isTradable(PoolId poolId) external view returns (bool) {
        MarketConfig storage cfg = _markets[poolId];
        if (!cfg.configured || cfg.halted) return false;
        if (!cfg.sessionEnabled) return true;
        return _sessionOpen(poolId, cfg, block.timestamp);
    }

    /// @notice The band the pool is currently judged against, as PPM of the reference price.
    /// @return active Whether the band is enforced at all for this pool.
    /// @return lowerPpm Lower edge, `1e6 - maxDownPpm`.
    /// @return upperPpm Upper edge, `1e6 + maxUpPpm`.
    function priceBand(PoolId poolId) external view returns (bool active, uint256 lowerPpm, uint256 upperPpm) {
        MarketConfig storage cfg = _markets[poolId];
        return (cfg.bandEnabled, PPM - uint256(cfg.maxDownPpm), PPM + uint256(cfg.maxUpPpm));
    }

    /// @notice Dry-run the band decision for a hypothetical post-swap price.
    /// @dev Lets a router pre-flight a trade it has already quoted: quote the swap, take the
    /// resulting `sqrtPriceX96`, and ask here whether the hook would accept it.
    ///
    /// To pre-flight an `initialize`, ask BOTH directions: the birth check has no converging
    /// exception, so a price is acceptable at birth only if neither `zeroForOne` value reverts.
    /// @return wouldRevert Whether `afterSwap` would reject this outcome.
    /// @return reason Empty when it would not; otherwise the ABI-encoded custom error it would
    ///         revert with, so the caller can surface the exact cause.
    function previewPriceBand(PoolId poolId, bool zeroForOne, uint160 postSwapSqrtPriceX96)
        external
        view
        returns (bool wouldRevert, bytes memory reason)
    {
        reason = _checkPriceInBand(poolId, zeroForOne, postSwapSqrtPriceX96);
        wouldRevert = reason.length != 0;
    }

    /*//////////////////////////////////////////////////////////////
                              ENFORCEMENT
    //////////////////////////////////////////////////////////////*/

    /// @dev The calendar-and-halt gate. Call from `beforeSwap`, and from `beforeAddLiquidity` when
    /// the pool sets `gateLiquidity`. NEVER call it from a removal path.
    function _requireMarketOpen(PoolId poolId) internal view {
        MarketConfig storage cfg = _markets[poolId];
        if (!cfg.configured) revert MarketNotConfigured(poolId);
        if (cfg.halted) revert TradingHalted(poolId);
        if (cfg.sessionEnabled) {
            bool open = _sessionOpen(poolId, cfg, block.timestamp);
            if (!open) revert MarketClosed(poolId, block.timestamp);
        }
    }

    /// @dev Whether the halt/calendar gate applies to liquidity additions on this pool.
    function _liquidityGated(PoolId poolId) internal view returns (bool) {
        return _markets[poolId].gateLiquidity;
    }

    /// @dev The band gate for the price a pool is BORN at. Call from `beforeInitialize`.
    ///
    /// Without it, the band never constrained the one price no swap produces. `initialize` is
    /// permissionless once governance has configured a key, so anyone could front-run the issuer's
    /// initialize at any price; and from an out-of-band birth, the arbitrage that drains the first
    /// LP deposit is a CONVERGING swap - precisely the swap the band exists to permit.
    ///
    /// The converging exception has no meaning here: a pool that has never traded has not gapped,
    /// so the birth price must be strictly inside `[lowerPpm, upperPpm]`. That is exactly the
    /// conjunction of the two swap directions, because a price-increasing outcome is rejected only
    /// above the upper edge and a price-decreasing one only below the lower edge. Composing the
    /// swap-path check rather than restating the band keeps one definition of "in band", at the
    /// cost of querying the oracle twice - once per pool, on a path that is not hot.
    ///
    /// Fails closed on the same terms as a swap: no reference, a stale one, or an unreachable
    /// oracle means the pool cannot be created yet. A pool with `bandEnabled == false` is not
    /// checked, and so remains free to be born at any price.
    function _requireInitialPriceInBand(PoolId poolId, uint160 sqrtPriceX96) internal view {
        _requirePriceInBand(poolId, false, sqrtPriceX96);
        _requirePriceInBand(poolId, true, sqrtPriceX96);
    }

    /// @dev The band gate. Call from `afterSwap` with the price the pool ended at.
    function _requirePriceInBand(PoolId poolId, bool zeroForOne, uint160 postSwapSqrtPriceX96) internal view {
        bytes memory reason = _checkPriceInBand(poolId, zeroForOne, postSwapSqrtPriceX96);
        if (reason.length != 0) {
            assembly ("memory-safe") {
                revert(add(reason, 0x20), mload(reason))
            }
        }
    }

    /// @dev The whole band decision in one place, returning the reason rather than reverting, so
    /// the enforcement path and the preview view can never disagree about what "in band" means.
    /// @return Empty when the outcome is acceptable; otherwise the encoded error to revert with.
    function _checkPriceInBand(PoolId poolId, bool zeroForOne, uint160 postSwapSqrtPriceX96)
        internal
        view
        returns (bytes memory)
    {
        MarketConfig storage cfg = _markets[poolId];
        if (!cfg.bandEnabled) return "";

        IPriceBandOracle oracle = cfg.oracle;
        uint256 gasLeft = gasleft();
        if (gasLeft < PRICE_ORACLE_GAS_FLOOR) {
            return abi.encodeWithSelector(InsufficientGasForPriceOracle.selector, gasLeft);
        }

        (bool callOk, uint160 referenceSqrtPriceX96, uint64 updatedAt) = _queryPriceOracle(oracle, poolId);
        // Fails CLOSED: a revert, an out-of-gas inside the budget, a non-contract, any return that
        // is not exactly two words, or a zero price all land here.
        if (!callOk || referenceSqrtPriceX96 == 0) {
            return abi.encodeWithSelector(PriceOracleUnavailable.selector, address(oracle), poolId);
        }

        uint32 maxPriceAge = cfg.maxPriceAge;
        if (maxPriceAge != 0) {
            // A reference dated in the future is treated as fresh rather than rejected: block
            // timestamps and off-chain publication clocks disagree by seconds routinely, and
            // halting a market over clock skew is the wrong failure.
            bool stale = block.timestamp > uint256(updatedAt) + uint256(maxPriceAge);
            if (stale) {
                return abi.encodeWithSelector(
                    ReferencePriceStale.selector, updatedAt, maxPriceAge, block.timestamp
                );
            }
        }

        uint256 ratioPpm = _priceRatioPpm(postSwapSqrtPriceX96, referenceSqrtPriceX96);
        uint256 upperPpm = PPM + uint256(cfg.maxUpPpm);
        uint256 lowerPpm = PPM - uint256(cfg.maxDownPpm);

        // The converging exception. `zeroForOne` moves the price DOWN, so a swap that ends above
        // the band having moved down cannot have ended further out than it started.
        bool divergentAbove = ratioPpm > upperPpm && !zeroForOne;
        bool divergentBelow = ratioPpm < lowerPpm && zeroForOne;
        if (divergentAbove || divergentBelow) {
            return abi.encodeWithSelector(PriceBandBreached.selector, poolId, ratioPpm, lowerPpm, upperPpm);
        }
        return "";
    }

    /*//////////////////////////////////////////////////////////////
                            CALENDAR MATHS
    //////////////////////////////////////////////////////////////*/

    /// @dev Resolve the session window that applies to one day index.
    /// @return tradingDay Whether the day has a session at all.
    /// @return openSecondOfDay Session open for that day.
    /// @return closeSecondOfDay Session close for that day.
    function _scheduleForDay(
        mapping(uint32 dayIndex => DayOverride) storage overrides,
        MarketConfig storage cfg,
        uint256 dayIndex
    ) private view returns (bool tradingDay, uint256 openSecondOfDay, uint256 closeSecondOfDay) {
        // `dayIndex` is derived from `block.timestamp / 86400` (or that minus one), which stays
        // inside `uint32` until the year 11,700,000. See `dayIndexOf`.
        // forge-lint: disable-next-line(unsafe-typecast)
        DayOverride storage dayOverrideRecord = overrides[uint32(dayIndex)];
        if (dayOverrideRecord.isSet) {
            if (dayOverrideRecord.closed) return (false, 0, 0);
            return (true, dayOverrideRecord.openSecondOfDay, dayOverrideRecord.closeSecondOfDay);
        }
        uint256 weekday = (dayIndex + 4) % 7;
        // `weekday` is 0-6, so the shifted bit is at most 0x40 and fits `uint8`.
        // forge-lint: disable-next-line(unsafe-typecast)
        if (cfg.weekdayMask & uint8(1 << weekday) == 0) return (false, 0, 0);
        return (true, cfg.openSecondOfDay, cfg.closeSecondOfDay);
    }

    /// @dev Is `timestamp` inside a session? Two candidate days at most: the one it falls in, and
    /// - only when today's answer is no - the previous day, whose session may wrap past midnight.
    ///
    /// The second override read therefore lands only on the wrap path and the closed path, never on
    /// an ordinary in-session swap. The calendar epoch is read once, up front: one extra cold SLOAD
    /// for a session-enabled pool, none for a 24/7 one. There is no loop and no growable set: the
    /// cost is constant.
    function _sessionOpen(PoolId poolId, MarketConfig storage cfg, uint256 timestamp)
        internal
        view
        returns (bool)
    {
        uint256 dayIndex = timestamp / SECONDS_PER_DAY;
        uint256 secondOfDay = timestamp % SECONDS_PER_DAY;
        mapping(uint32 dayIndex => DayOverride) storage overrides = _dayOverrides[poolId][_calendarEpoch[poolId]];

        (bool tradingDay, uint256 openSecondOfDay, uint256 closeSecondOfDay) =
            _scheduleForDay(overrides, cfg, dayIndex);
        if (tradingDay && openSecondOfDay != closeSecondOfDay) {
            if (openSecondOfDay < closeSecondOfDay) {
                if (secondOfDay >= openSecondOfDay && secondOfDay < closeSecondOfDay) return true;
            } else if (secondOfDay >= openSecondOfDay) {
                // Wrapping session, opened today, still running.
                return true;
            }
        }

        // A session that opened yesterday and wraps into today. Day index 0 has no yesterday.
        if (dayIndex == 0) return false;
        (bool yesterdayTrading, uint256 yesterdayOpen, uint256 yesterdayClose) =
            _scheduleForDay(overrides, cfg, dayIndex - 1);
        if (yesterdayTrading && yesterdayOpen > yesterdayClose && secondOfDay < yesterdayClose) return true;

        return false;
    }

    /*//////////////////////////////////////////////////////////////
                              PRICE MATHS
    //////////////////////////////////////////////////////////////*/

    /// @notice The pool price as parts-per-million of the reference price. 1e6 is parity.
    ///
    /// @dev Both inputs are `sqrtPriceX96`, so the price ratio is the SQUARE of their ratio. The
    /// squaring is the only delicate part:
    ///
    ///   * `mulDiv` first, to get the sqrt ratio in PPM without losing the low bits of a ratio
    ///     near 1. `poolSqrt <= 2**160` and `referenceSqrt >= MIN_SQRT_RATIO (~2**32)`, so the
    ///     quotient is at most ~2**128 and the PPM-scaled value at most ~2**148: it fits.
    ///   * then a clamp, because squaring an arbitrary 148-bit number overflows. Any sqrt ratio
    ///     above `SQRT_RATIO_PPM_CLAMP` corresponds to a price ratio hundreds of thousands of
    ///     times wider than the widest band this module can express, so reporting `type(uint256).max`
    ///     for it is exact enough for every comparison that follows, and unambiguously "outside".
    ///   * then plain arithmetic, which cannot overflow below the clamp (1e15 squared is 1e30).
    ///
    /// Rounding is `mulDiv`'s, i.e. toward zero, so the reported ratio is at most 1 PPM below the
    /// true one. At the upper edge that rounds in the trader's favour by a millionth; at the lower
    /// edge it rounds against them by the same. Neither is exploitable: a band is a policy
    /// threshold, not a settlement price, and nothing is paid out on this number.
    function _priceRatioPpm(uint160 poolSqrtPriceX96, uint160 referenceSqrtPriceX96)
        internal
        pure
        returns (uint256)
    {
        uint256 sqrtRatioPpm = FullMath.mulDiv(uint256(poolSqrtPriceX96), PPM, uint256(referenceSqrtPriceX96));
        if (sqrtRatioPpm > SQRT_RATIO_PPM_CLAMP) return type(uint256).max;
        return (sqrtRatioPpm * sqrtRatioPpm) / PPM;
    }

    /// @notice Query the price oracle without letting it damage the trader.
    ///
    /// @dev A raw `staticcall` rather than `try/catch`, for the same three reasons
    /// `PermissionedPoolHook._queryOracle` gives: a hard gas bound on a looping oracle, a
    /// `returndatasize` check made BEFORE any copying so a return bomb cannot force this frame to
    /// pay for memory expansion, and masking on the way out so a non-canonical return cannot
    /// smuggle high-order bits into a narrower type.
    ///
    /// A `staticcall` to an address with no code succeeds with `returndatasize == 0`, which fails
    /// the size check, so "oracle is an EOA / self-destructed / not yet deployed" reads as
    /// unavailable rather than silently succeeding with a zero price.
    ///
    /// @return callOk False if the oracle reverted, exceeded its budget, is not a contract, or
    ///         returned anything other than exactly two words.
    function _queryPriceOracle(IPriceBandOracle oracle, PoolId poolId)
        internal
        view
        returns (bool callOk, uint160 sqrtPriceX96, uint64 updatedAt)
    {
        bytes memory callData = abi.encodeCall(IPriceBandOracle.referencePrice, (poolId));

        // Bound to locals: inline assembly reads stack slots, not the constant table.
        uint256 gasBudget = PRICE_ORACLE_GAS_LIMIT;
        uint256 returnSize = PRICE_ORACLE_RETURN_SIZE;

        assembly ("memory-safe") {
            // Scratch above the free-memory pointer; never read after this block, and the pointer
            // is not advanced, so no allocation is disturbed.
            let out := mload(0x40)
            let ok := staticcall(gasBudget, oracle, add(callData, 0x20), mload(callData), out, returnSize)

            if and(ok, eq(returndatasize(), returnSize)) {
                callOk := 1
                sqrtPriceX96 := and(mload(out), 0xffffffffffffffffffffffffffffffffffffffff)
                updatedAt := and(mload(add(out, 0x20)), 0xffffffffffffffff)
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                              VALIDATION
    //////////////////////////////////////////////////////////////*/

    function _validateSettings(MarketSettings calldata settings) private pure {
        if (settings.issuer == address(0)) revert MarketZeroAddress();
        if (settings.maxDownPpm > PPM) revert InvalidBandWidth(settings.maxDownPpm);
        if (settings.bandEnabled && address(settings.oracle) == address(0)) revert BandEnabledWithoutOracle();
        // Reserved bits are refused whether or not the session is enabled. A zero mask on a
        // disabled session means "no schedule" and is legitimate; a set bit 7 means nothing in any
        // mode, so there is no configuration in which storing it is correct.
        _requireOnlyWeekdayBits(settings.weekdayMask);
        if (settings.sessionEnabled) {
            // An empty mask is rejected because it configures a pool that can never trade while
            // looking, in every event and every view, exactly like a configured one.
            if (settings.weekdayMask == 0) revert EmptyWeekdayMask();
            _validateWindowTimes(settings.openSecondOfDay, settings.closeSecondOfDay);
        }
    }

    /// @dev Refuse any bit `_scheduleForDay` does not read.
    ///
    /// Checking `mask == 0` alone is not enough, and was the original defect: `0x80` is non-zero,
    /// passed that check, and matched no weekday, so it configured a pool that could never trade
    /// while `marketConfig`, `MarketConfigured` and `SessionHoursSet` all reported a non-empty
    /// schedule. With this check in place, an accepted non-zero mask has at least one bit in 0-6,
    /// i.e. at least one trading weekday.
    function _requireOnlyWeekdayBits(uint8 weekdayMask) private pure {
        if (weekdayMask & ~WEEKDAY_MASK_BITS != 0) revert InvalidWeekdayMask(weekdayMask);
    }

    /// @dev A session window must be unambiguous and in range.
    ///
    /// `open == close` is rejected rather than read as "closed" or as "always open": both readings
    /// are defensible, which is precisely why it must not be silently assigned one of them. A pool
    /// that should trade continuously sets `sessionEnabled = false` and says so.
    function _validateWindowTimes(uint24 openSecondOfDay, uint24 closeSecondOfDay) private pure {
        if (uint256(openSecondOfDay) >= SECONDS_PER_DAY || uint256(closeSecondOfDay) >= SECONDS_PER_DAY) {
            revert InvalidSessionWindow(openSecondOfDay, closeSecondOfDay);
        }
        if (openSecondOfDay == closeSecondOfDay) revert InvalidSessionWindow(openSecondOfDay, closeSecondOfDay);
    }
}
