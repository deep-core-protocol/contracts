/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {PoolId} from "infinity-core/src/types/PoolId.sol";

/// @title IPriceBandOracle
/// @notice The pluggable reference-price source consulted by `MarketHoursModule`'s circuit breaker.
///
/// @dev ############################ IMPLEMENTER'S CONTRACT ############################
///
/// The consumer calls this from inside `afterSwap`, i.e. inside a Vault lock, on the critical path
/// of every trade. The same four rules that govern `IComplianceOracle` govern this, for the same
/// reasons, and none of them are optional:
///
///   1. `referencePrice` MUST be a `view` and MUST NOT depend on the caller. The consumer queries
///      it with a `staticcall`; any state write reverts the call and reads as "unavailable".
///
///   2. It MUST fit inside `MarketHoursModule.PRICE_ORACLE_GAS_LIMIT`. The consumer caps the gas it
///      forwards so a broken or hostile feed cannot consume the whole transaction. An oracle that
///      exceeds that budget reads as unavailable and the swap is rejected. Do not iterate unbounded
///      arrays; do not call out to contracts that might.
///
///   3. The return MUST be exactly the two values below, ABI-encoded (64 bytes). The consumer
///      checks `returndatasize` and rejects anything else, which is also what defeats a
///      return-data bomb. Adding a field makes this a DIFFERENT interface - write an adapter.
///
///   4. Reverting is a legitimate answer and means "no reference price". The consumer treats that
///      as a reason to STOP TRADING, not as a reason to skip the check. A circuit breaker whose
///      failure mode is "let every price through" is not a circuit breaker.
///
/// ###################### THE UNIT. THIS IS THE PART THAT GOES WRONG. ######################
///
/// `sqrtPriceX96` is in the POOL's units, not the feed's: it is
///
///     sqrt(amount of currency1 per 1 unit of currency0, in each token's own smallest unit) * 2**96
///
/// exactly as core stores it in `CLPool.slot0`. It is NOT a USD price, NOT 8-decimal Chainlink
/// scale, and NOT independent of which token sorted lower.
///
/// That conversion is deliberately pushed into the implementation, because the implementation is
/// the only party that knows both the feed's decimals and the pool's token ordering, and because
/// an on-chain `sqrt` of a rescaled feed value on the swap hot path is an expense every trader
/// would pay on every trade. An adapter computes it once per feed update instead.
///
/// GETTING THIS BACKWARDS INVERTS THE BAND. If an implementation returns the reciprocal price, the
/// consumer will read a pool trading at fair value as being wildly off it, and will reject every
/// swap in one direction while permitting any swap in the other. Test an adapter against a real
/// pool's `getSlot0` output before it governs anything.
///
/// ############################ WHAT THIS IS NOT ############################
///
/// Nothing here is legal advice, and nothing here asserts that any band width, any reference
/// source, or any resulting trading behaviour satisfies any market-structure rule, exchange
/// obligation, best-execution duty or price-discovery requirement in any jurisdiction. This is a
/// mechanism for asking a contract what price it thinks something is worth. What an issuer is
/// obliged to do with that answer is a question for the issuer's counsel.
/// ##########################################################################
interface IPriceBandOracle {
    /// @notice The reference price against which the pool's price is judged.
    /// @param poolId The pool being priced, so one oracle can serve several offerings.
    /// @return sqrtPriceX96 The reference price in the pool's own units (see the note above).
    ///         Return 0 for "no reference price available"; the consumer treats 0 as unavailable
    ///         and rejects the swap rather than skipping the band check.
    /// @return updatedAt Unix timestamp at which this reference was last established. The consumer
    ///         enforces its own staleness window against this, so an implementation that genuinely
    ///         has no notion of freshness must say so by returning `block.timestamp`; returning 0
    ///         reads as "the epoch", which any non-zero staleness window rejects.
    function referencePrice(PoolId poolId) external view returns (uint160 sqrtPriceX96, uint64 updatedAt);
}
