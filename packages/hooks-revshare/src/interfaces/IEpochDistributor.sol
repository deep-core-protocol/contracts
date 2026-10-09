/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

/// @title EpochDistributorKind
/// @notice The two values `IEpochDistributor.kind()` is allowed to return.
///
/// @dev These are domain-separated hashes rather than an enum, and that choice is the whole point
/// of the mechanism. An enum would be a `uint8`, and `0` - the value every wrong answer produces -
/// would be a VALID kind:
///
///   * An address with a catch-all `fallback()` that returns 32 zero bytes decodes as kind 0.
///   * A proxy pointing at an empty implementation does the same.
///   * An EOA, or a self-destructed contract, returns no data at all; some clients surface that as
///     a zero-filled decode rather than an error.
///
/// With a keccak constant there is no such value. Zero is not a kind, an unrecognised hash is not a
/// kind, and a caller that does not get an exact match on one of these two constants knows it is
/// talking to something it does not understand. "I could not tell" and "it is a snapshot
/// distributor" stop being the same 32 bytes.
///
/// The `.v1` suffix is deliberate. If a future distributor changes the `Epoch` struct - which is
/// precisely the thing a consumer is switching on - it gets a NEW constant, not a reused one, so an
/// old consumer fails to match rather than decoding a new layout with an old ABI.
library EpochDistributorKind {
    /// @notice `SnapshotEpochDistributor`. Epoch index 4 is `totalVotingSupply`, index 5 is a
    /// `uint48` token-clock timepoint.
    bytes32 internal constant SNAPSHOT = keccak256("deepcore.revshare.distributor.snapshot.v1");

    /// @notice `MerkleEpochDistributor`. Epoch index 4 is `root`, index 5 is `closedAt`, and the
    /// tree the root commits to is pointed at by `getRootSource`.
    bytes32 internal constant MERKLE = keccak256("deepcore.revshare.distributor.merkle.v1");
}

/// @title IEpochDistributor
/// @notice One call that tells a consumer which epoch distributor it is holding.
///
/// @dev ###################### WHY THIS EXISTS AT ALL ######################
///
/// `RevShareHook.distributorOf` returns a bare address, and the two distributors this repo ships
/// share no base contract. Before this interface the only way to tell them apart was to PROBE -
/// call `token()` (answers only on the snapshot one) and `challengeDelay()` (only on the merkle
/// one) and require exactly one to succeed. Three separate consumers had reimplemented that probe.
///
/// The probe was not a convenience. It was load-bearing for CORRECTNESS, because BOTH `Epoch`
/// structs are nine all-static fields, so a shared `getEpoch` ABI decodes WITHOUT ERROR while
/// silently reinterpreting:
///
///   idx  SnapshotEpochDistributor     MerkleEpochDistributor
///   ---  ---------------------------  ----------------------
///    4   totalVotingSupply (uint256)  root (bytes32)
///    5   timepoint (uint48)           closedAt (uint64)
///    6   closedAt (uint64)            claimableAt (uint64)
///
/// Read a merkle epoch through the snapshot ABI and you do not get an exception, you get a
/// `totalVotingSupply` of 2^250-ish (the root) and a `closedAt` that is really `claimableAt`. A
/// consumer that divides by that supply produces a confident, plausible, wrong number. Guessing is
/// strictly worse than refusing, and a probe of two selectors is guessing with extra steps: any
/// contract that happens to expose a `token()` getter answers the snapshot question.
///
/// ------------------------------- WHY NOT ERC-165 -------------------------------
///
/// ERC-165 answers "do you support interface X", which is the wrong question. Both distributors
/// support this same `IEpochDistributor`, so its interface id distinguishes nothing; telling them
/// apart with 165 would mean minting a marker interface per variant and then probing for each in
/// turn - the same round trips as today's probe, with a registry of empty interfaces to maintain.
/// `kind()` is ONE static call that returns the answer directly, and adding a third distributor
/// costs one constant rather than one interface plus an edit to every consumer's probe ladder.
interface IEpochDistributor {
    /// @notice Which distributor this is: one of the `EpochDistributorKind` constants, and never
    /// zero.
    /// @dev `pure` and constant-folded, so it is a `staticcall` returning an immediate. Call this
    /// FIRST and decode `getEpoch` with the matching ABI second; the two structs are not
    /// interchangeable and nothing on either contract will tell you when you have got it wrong.
    function kind() external pure returns (bytes32);
}
