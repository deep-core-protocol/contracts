// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity ^0.8.24;

import {PoolId} from "infinity-core/src/types/PoolId.sol";

/// @title IDeepCoreOracle
/// @notice The read interface of DeepCore's truncated time-weighted average tick, implemented by every
/// hook that embeds `OracleModule` (`DeepCoreOracleHook`, `DeepCoreDexHook`). STABLE: consumers build
/// against this file; it changes only by addition.
///
/// RULES A CONSUMER MUST KNOW (all enforced or reported by the oracle, never assumed):
///  - `consult(id, window)` returns the arithmetic mean tick over `[now - window, now]` (the geometric
///    mean price, token1 per token0 as the pool's tick). It REVERTS `WindowTooShort` under
///    `ORACLE_MIN_WINDOW_SECONDS()` and `HistoryTooShort` when the recorded history is shorter than
///    the window; it never shortens a window. Rounds toward negative infinity.
///  - At most one observation per second, holding the tick BEFORE that second's first swap, clamped
///    to within `ORACLE_MAX_TICK_DELTA()` of the previous one. The answer LAGS real moves on purpose:
///    a move of N ticks needs about N / ORACLE_MAX_TICK_DELTA() observations to be recorded.
///  - From the last observation to now the oracle extrapolates with the pool's current tick, clamped
///    the same way; a swap in the reading transaction cannot move the answer.
///  - STALENESS IS THE CONSUMER'S CALL: `consult` returns `lastWriteAge`, the seconds since the last
///    observation (a quiet pool's answer is its last price, extrapolated). Refuse what is too old.
///  - HISTORY DEPTH is the ring's size times the pool's trading cadence: `oldestObservationAge(id)`
///    says how much history exists now. Anyone may pre-pay more slots with
///    `increaseCardinalityNext` (the caller pays the gas); the ring grows at its next wrap.
///  - `observe` is the raw Uniswap-v3-style view (any `secondsAgo`, including under the minimum
///    window); a consumer using it owns the minimum-window decision.
///  - `kind()` == keccak256("deepcore.oracle.truncated-twap.v1").
///  - It does NOT report liquidity: a thin pool's average is still a thin pool's price.
interface IDeepCoreOracle {
    struct Observation {
        uint40 timestamp;
        int56 tickCumulative;
        int24 tick; // the CLAMPED tick in force over the interval ending at `timestamp`
        bool initialized;
    }

    error InvalidOracleParameters(uint8 reason);
    error WindowTooShort(uint32 window, uint32 minimum);
    error HistoryTooShort(uint32 available, uint32 requested);
    error PoolNotObserved(PoolId poolId);
    error CardinalityNotIncreased(uint16 current, uint16 requested);

    event CardinalityNextIncreased(PoolId indexed poolId, uint16 previous, uint16 next);

    function consult(PoolId id, uint32 window) external view returns (int24 meanTick, uint32 lastWriteAge);
    function observe(PoolId id, uint32[] calldata secondsAgos) external view returns (int56[] memory tickCumulatives);
    function lastObservation(PoolId id) external view returns (Observation memory);
    function oldestObservationAge(PoolId id) external view returns (uint32);
    function stateOf(PoolId id) external view returns (uint16 index, uint16 cardinality, uint16 cardinalityNext);
    function observationAt(PoolId id, uint16 slot) external view returns (Observation memory);
    function increaseCardinalityNext(PoolId id, uint16 next) external;
    function kind() external pure returns (bytes32);

    function ORACLE_MAX_TICK_DELTA() external view returns (uint24);
    function ORACLE_MIN_WINDOW_SECONDS() external view returns (uint32);
    function ORACLE_INITIAL_CARDINALITY() external view returns (uint16);
}
