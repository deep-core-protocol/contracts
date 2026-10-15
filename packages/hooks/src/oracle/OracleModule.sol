// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {IDeepCoreOracle} from "./IDeepCoreOracle.sol";

/// @title OracleModule
/// @notice A truncated time-weighted average tick for a CL pool, kept by the pool's own hook.
/// Design of record: `docs/products/price-oracle-deepcore.md`. Inherited by `DeepCoreOracleHook`
/// (the module alone) and `DeepCoreDexHook` (with the dynamic fee).
///
/// ############################## WHAT IS RECORDED ##############################
///
/// At most ONE observation per second, written by the FIRST swap of that second, holding the tick as
/// it stood BEFORE that swap, clamped to within `ORACLE_MAX_TICK_DELTA` of the previous record:
///
///   clamped    = clamp(preSwapTick, last.tick - D, last.tick + D)
///   cumulative = last.tickCumulative + clamped * (t - last.timestamp)
///
/// The pre-swap tick at the first swap of second t is the price that stood since the last swap,
/// and every swap since the last observation happened inside that observation's second, so
/// `clamped` is the (clamped) tick in force over the whole interval `(last.timestamp, t]`.
/// Consequences, both deliberate:
///   1. a move made and undone inside one second is never seen;
///   2. one observation moves the recorded tick by at most D, however far the pool moved and
///      however long it then stood. This oracle LAGS real moves on purpose.
///
/// ############################## READING ##############################
///
/// `consult(id, window)` returns the arithmetic mean tick over `[now - window, now]` (the geometric
/// mean price). It REFUSES a window under `ORACLE_MIN_WINDOW_SECONDS` and a window longer than the
/// recorded history; it never shortens a window. From the last observation to now it extrapolates
/// with the pool's CURRENT tick, clamped the same way; in a second that already has a swap there is
/// nothing to extrapolate, so a swap in the reading transaction cannot move the answer. It also
/// returns the age of the last write, so the consumer judges staleness; the oracle does not.
///
/// ############################## SAFETY ##############################
///
/// The write path never reverts: no external call, no loop, only wrapping arithmetic. Every
/// cumulative is `int56` and every difference is taken in wrapping arithmetic, exactly as Uniswap
/// v3's oracle does: the true difference over any window a `uint32` can express fits `int56`.
/// No transient storage: the module behaves identically under both build profiles.
abstract contract OracleModule is IDeepCoreOracle {
    /*//////////////////////////////////////////////////////////////
                                 TYPES
    //////////////////////////////////////////////////////////////*/

    // `Observation` (one slot: uint40 timestamp, int56 tickCumulative, int24 tick, bool initialized)
    // is declared in IDeepCoreOracle. timestamp uint40 does not wrap before year 36812; tickCumulative
    // int56 holds over 1,000 years at the extreme tick and wraps harmlessly beyond (differences only).

    /// @dev One slot. `cardinality` is the live ring size; `cardinalityNext` the size it grows to at
    /// the next wrap (slots up to it are pre-paid).
    struct OracleState {
        uint16 index;
        uint16 cardinality;
        uint16 cardinalityNext;
    }

    /*//////////////////////////////////////////////////////////////
                           CONSTANTS AND IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    /// @notice `keccak256("deepcore.oracle.truncated-twap.v1")`, so a consumer can check what it reads.
    bytes32 public constant ORACLE_KIND = keccak256("deepcore.oracle.truncated-twap.v1");

    uint24 public constant HARD_MAX_TICK_DELTA = 1_000;
    uint32 public constant HARD_MIN_WINDOW_FLOOR = 60;
    uint32 public constant HARD_MIN_WINDOW_CEILING = 86_400;
    uint16 public constant HARD_MAX_INITIAL_CARDINALITY = 1_024;

    /// @notice The most one observation may move the recorded tick.
    uint24 public immutable ORACLE_MAX_TICK_DELTA;
    /// @notice The shortest window `consult` answers.
    uint32 public immutable ORACLE_MIN_WINDOW_SECONDS;
    /// @notice Ring slots pre-paid when a pool is initialized.
    uint16 public immutable ORACLE_INITIAL_CARDINALITY;

    /*//////////////////////////////////////////////////////////////
                                 STORAGE
    //////////////////////////////////////////////////////////////*/

    mapping(PoolId => OracleState) private _oracleStates;
    mapping(PoolId => Observation[65_535]) private _observations;

    /*//////////////////////////////////////////////////////////////
                             ERRORS AND EVENTS
    //////////////////////////////////////////////////////////////*/

    // Errors and the event are declared in IDeepCoreOracle.

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    /// @dev Reasons: 1 max tick delta outside 1..1,000; 2 min window outside 60..86,400; 3 initial
    /// cardinality outside 1..1,024.
    constructor(uint24 maxTickDelta_, uint32 minWindowSeconds_, uint16 initialCardinality_) {
        if (maxTickDelta_ == 0 || maxTickDelta_ > HARD_MAX_TICK_DELTA) revert InvalidOracleParameters(1);
        if (minWindowSeconds_ < HARD_MIN_WINDOW_FLOOR || minWindowSeconds_ > HARD_MIN_WINDOW_CEILING) {
            revert InvalidOracleParameters(2);
        }
        if (initialCardinality_ == 0 || initialCardinality_ > HARD_MAX_INITIAL_CARDINALITY) {
            revert InvalidOracleParameters(3);
        }
        ORACLE_MAX_TICK_DELTA = maxTickDelta_;
        ORACLE_MIN_WINDOW_SECONDS = minWindowSeconds_;
        ORACLE_INITIAL_CARDINALITY = initialCardinality_;
    }

    /*//////////////////////////////////////////////////////////////
                              WRITE PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev From `afterInitialize`: the first observation, at the birth tick, and the pre-paid ring.
    function _oracleInitialize(PoolId id, int24 tick) internal {
        _observations[id][0] =
            Observation({timestamp: uint40(block.timestamp), tickCumulative: 0, tick: tick, initialized: true});
        uint16 next = ORACLE_INITIAL_CARDINALITY;
        _oracleStates[id] = OracleState({index: 0, cardinality: 1, cardinalityNext: next});
        _prepay(id, 1, next);
    }

    /// @dev From `beforeSwap`, with the pool's tick BEFORE the swap. Never reverts.
    function _oracleWrite(PoolId id, int24 preSwapTick) internal {
        OracleState memory st = _oracleStates[id];
        if (st.cardinality == 0) return; // not observed: unreachable for a pool born on this hook
        Observation memory last = _observations[id][st.index];
        uint40 t = uint40(block.timestamp);
        if (t <= last.timestamp) return; // this second is already recorded
        int24 clamped = _clampTick(preSwapTick, last.tick);
        unchecked {
            // Grow the ring when the write would wrap and more slots are paid for.
            uint16 card = st.cardinality;
            if (st.index == card - 1 && st.cardinalityNext > card) card = st.cardinalityNext;
            uint16 next = uint16((uint256(st.index) + 1) % card);
            _observations[id][next] = Observation({
                timestamp: t,
                // wrapping by design; differences only. dt < 2^40, |clamped| < 2^20.
                tickCumulative: last.tickCumulative + int56(clamped) * int56(uint56(t - last.timestamp)),
                tick: clamped,
                initialized: true
            });
            _oracleStates[id] = OracleState({index: next, cardinality: card, cardinalityNext: st.cardinalityNext});
        }
    }

    /// @dev `tick` clamped into `[ref - D, ref + D]`. Both bounds lie between
    /// `ref` and `tick` whenever they bind, so the result is always a valid tick.
    function _clampTick(int24 tick, int24 ref) internal view returns (int24) {
        int256 d = int256(uint256(ORACLE_MAX_TICK_DELTA));
        int256 lo = int256(ref) - d;
        int256 hi = int256(ref) + d;
        int256 x = int256(tick);
        if (x < lo) x = lo;
        else if (x > hi) x = hi;
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(x);
    }

    function _prepay(PoolId id, uint16 from, uint16 to) private {
        // A non-zero timestamp makes the later real write a warm-slot update. `initialized` stays
        // false, so a pre-paid slot is never read as history.
        for (uint256 i = from; i < to; ++i) {
            _observations[id][i].timestamp = 1;
        }
    }

    /// @notice Pre-pay more ring slots for a pool. Anyone may call; the caller pays the gas. A
    /// write still touches one slot whatever the size.
    function increaseCardinalityNext(PoolId id, uint16 next) external {
        OracleState storage st = _oracleStates[id];
        if (st.cardinality == 0) revert PoolNotObserved(id);
        uint16 previous = st.cardinalityNext;
        if (next <= previous) revert CardinalityNotIncreased(previous, next);
        _prepay(id, previous, next);
        st.cardinalityNext = next;
        emit CardinalityNextIncreased(id, previous, next);
    }

    /*//////////////////////////////////////////////////////////////
                               READ PATH
    //////////////////////////////////////////////////////////////*/

    /// @dev The pool's current tick, for extrapolation. Implemented by the hook.
    function _oracleCurrentTick(PoolId id) internal view virtual returns (int24);

    /// @notice The mean tick over the last `window` seconds and the age of the last write.
    /// @dev Reverts below the minimum window and beyond the recorded history. Rounds toward
    /// negative infinity, as Uniswap v3's `OracleLibrary.consult` does.
    function consult(PoolId id, uint32 window) external view returns (int24 meanTick, uint32 lastWriteAge) {
        if (window < ORACLE_MIN_WINDOW_SECONDS) revert WindowTooShort(window, ORACLE_MIN_WINDOW_SECONDS);
        OracleState memory st = _requireObserved(id);
        uint40 t = uint40(block.timestamp);
        Observation memory last = _observations[id][st.index];
        uint32 available = _available(id, st, t);
        if (window > available) revert HistoryTooShort(available, window);
        int56 cumNow = _cumulativeAt(id, st, last, t);
        int56 cumThen = _cumulativeAt(id, st, last, t - window);
        int56 delta;
        unchecked {
            delta = cumNow - cumThen;
        }
        int56 w = int56(uint56(window));
        int56 q = delta / w;
        if (delta < 0 && delta % w != 0) q--;
        // forge-lint: disable-next-line(unsafe-typecast)
        meanTick = int24(q); // a mean of valid ticks is a valid tick
        // forge-lint: disable-next-line(unsafe-typecast)
        lastWriteAge = uint32(t - last.timestamp);
    }

    /// @notice Tick cumulatives at `now - secondsAgos[i]`, Uniswap-v3 style. Any window; the caller
    /// owns the minimum-window decision when it uses this raw view. Reverts beyond the history.
    function observe(PoolId id, uint32[] calldata secondsAgos) external view returns (int56[] memory tickCumulatives) {
        OracleState memory st = _requireObserved(id);
        uint40 t = uint40(block.timestamp);
        Observation memory last = _observations[id][st.index];
        uint32 available = _available(id, st, t);
        tickCumulatives = new int56[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; ++i) {
            if (secondsAgos[i] > available) revert HistoryTooShort(available, secondsAgos[i]);
            tickCumulatives[i] = _cumulativeAt(id, st, last, t - secondsAgos[i]);
        }
    }

    function lastObservation(PoolId id) external view returns (Observation memory) {
        OracleState memory st = _requireObserved(id);
        return _observations[id][st.index];
    }

    /// @notice Seconds of history `consult` can cover now.
    function oldestObservationAge(PoolId id) external view returns (uint32) {
        OracleState memory st = _requireObserved(id);
        return _available(id, st, uint40(block.timestamp));
    }

    function stateOf(PoolId id) external view returns (uint16 index, uint16 cardinality, uint16 cardinalityNext) {
        OracleState memory st = _oracleStates[id];
        return (st.index, st.cardinality, st.cardinalityNext);
    }

    function observationAt(PoolId id, uint16 slot) external view returns (Observation memory) {
        return _observations[id][slot];
    }

    function kind() external pure returns (bytes32) {
        return ORACLE_KIND;
    }

    function _requireObserved(PoolId id) private view returns (OracleState memory st) {
        st = _oracleStates[id];
        if (st.cardinality == 0) revert PoolNotObserved(id);
    }

    function _oldest(PoolId id, OracleState memory st) private view returns (Observation memory o) {
        o = _observations[id][(uint256(st.index) + 1) % st.cardinality];
        if (!o.initialized) o = _observations[id][0];
    }

    function _available(PoolId id, OracleState memory st, uint40 t) private view returns (uint32) {
        uint256 age = t - _oldest(id, st).timestamp;
        // forge-lint: disable-next-line(unsafe-typecast)
        return age > type(uint32).max ? type(uint32).max : uint32(age);
    }

    /// @dev The cumulative at `target` (oldest.timestamp <= target <= now, checked by the caller).
    function _cumulativeAt(PoolId id, OracleState memory st, Observation memory last, uint40 target)
        private
        view
        returns (int56)
    {
        if (target >= last.timestamp) {
            if (target == last.timestamp) return last.tickCumulative;
            // Extrapolate over (last.timestamp, target] with the current tick, clamped like a write.
            int24 clamped = _clampTick(_oracleCurrentTick(id), last.tick);
            unchecked {
                return last.tickCumulative + int56(clamped) * int56(uint56(target - last.timestamp));
            }
        }
        (Observation memory a, Observation memory b) = _search(id, st, target);
        if (target == a.timestamp) return a.tickCumulative;
        if (target == b.timestamp) return b.tickCumulative;
        // The tick is constant over (a.timestamp, b.timestamp], equal to b.tick.
        unchecked {
            return a.tickCumulative + int56(b.tick) * int56(uint56(target - a.timestamp));
        }
    }

    /// @dev Binary search for the observations around `target`, which lies strictly before the last
    /// observation and at or after the oldest. Pre-paid, never-written slots are skipped.
    function _search(PoolId id, OracleState memory st, uint40 target)
        private
        view
        returns (Observation memory beforeOrAt, Observation memory atOrAfter)
    {
        uint256 card = st.cardinality;
        uint256 l = (uint256(st.index) + 1) % card;
        uint256 r = l + card - 1;
        while (true) {
            uint256 i = (l + r) / 2;
            beforeOrAt = _observations[id][i % card];
            if (!beforeOrAt.initialized) {
                l = i + 1;
                continue;
            }
            atOrAfter = _observations[id][(i + 1) % card];
            if (beforeOrAt.timestamp <= target) {
                if (target <= atOrAfter.timestamp) break;
                l = i + 1;
            } else {
                r = i - 1;
            }
        }
    }
}
