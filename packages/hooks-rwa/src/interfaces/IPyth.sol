/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

/// @title IPyth (minimal)
/// @notice Only the two members `PythPriceBandAdapter` calls, declared here rather than pulled in
/// as a dependency.
///
/// @dev Two reasons this is hand-written instead of importing `@pythnetwork/pyth-sdk-solidity`:
///
///   1. This package sits under a GPL-2.0-or-later licence and a build with two pinned transient
///      backends. Adding a third-party Solidity dependency for two function selectors is cost
///      without benefit.
///   2. The adapter's whole security posture is that it can only ask Pyth the questions listed
///      here. A narrow interface IS the allowlist.
///
/// The struct layout and both signatures match Pyth's published `IPyth`/`PythStructs` exactly; a
/// mismatch would revert at decode time rather than return a wrong number, because the adapter
/// checks nothing about the shape and Solidity's ABI decoder does.
interface IPyth {
    /// @param price The price, scaled by `10**expo`. Signed: Pyth can and does publish negatives
    ///        for some feeds, and this adapter rejects anything not strictly positive.
    /// @param conf The confidence interval, in the same scale as `price`. A wide confidence is
    ///        Pyth saying "the market disagrees with itself right now" — the adapter treats that
    ///        as a reason to withhold a reference, not a detail to average away.
    /// @param expo The base-10 exponent. Almost always negative.
    /// @param publishTime Unix seconds at which publishers agreed this price.
    struct Price {
        int64 price;
        uint64 conf;
        int32 expo;
        uint256 publishTime;
    }

    /// @notice The latest price, WITHOUT any staleness check.
    /// @dev Deliberately the "unsafe" variant. The safe variant reverts on age using Pyth's own
    /// window, which would move a policy decision into a dependency; the adapter enforces its own
    /// `maxPublishAge` and, separately, the consuming module enforces `maxPriceAge` against the
    /// timestamp this adapter reports. Two independent staleness gates, both ours.
    function getPriceUnsafe(bytes32 id) external view returns (Price memory price);

    /// @notice Fee required to submit `updateData` to `updatePriceFeeds`.
    /// @dev Exposed so a keeper can quote the cost before posting. This adapter never calls
    /// `updatePriceFeeds` itself — see the note on `refresh` about why posting is not its job.
    function getUpdateFee(bytes[] calldata updateData) external view returns (uint256 feeAmount);
}
