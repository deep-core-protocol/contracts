/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

/// @title IDeepCoreLaunchOrigin
/// @notice The three lines a launchpad implements so its launches can be attributed to it.
///
/// @dev ################## WHY THIS EXISTS AT ALL ##################
///
/// Nothing in core records who opened a pool. `CLPoolManager.initialize` writes
/// `poolIdToPoolKey[id]` and emits an event; the SENDER survives only in the log, and a contract
/// cannot read a log. So "this token was launched by Acme's launchpad" is not a fact any third
/// party can prove after the fact — it is a fact only Acme's own contract holds.
///
/// That leaves exactly two ways for a launch record to name a launchpad without the name being
/// hearsay, and `DeepCoreLaunchRegistry` accepts both and nothing else:
///
///   1. the launchpad registers the launch itself, so `msg.sender` IS the launchpad. Unforgeable,
///      needs no interface, and — because the registration can sit in the same transaction as the
///      pool's `initialize` — cannot be front-run. This is the path a new launchpad should take.
///
///   2. the launchpad answers this interface. A launchpad that shipped before the launch registry
///      existed, or one whose launches are being indexed retroactively by somebody else, has no
///      way to be the `msg.sender` any more. Implementing `launchOriginOf` lets it still vouch.
///
/// ###################### WHAT IMPLEMENTING THIS PROMISES ######################
///
/// Answering with a non-zero address for a pool id is a statement, on chain, in your own bytecode,
/// that YOU created that pool and that the address you returned is the account that asked you to.
/// The launch registry writes both into a permanent record and shows your name above them.
///
/// The corollary is the one that matters for anybody reading a marketplace: a launchpad can only
/// ever be named by a record when the launchpad's own code agreed to be named. Nobody can hang a
/// scam launch off your reputation. The reverse is NOT prevented — a launchpad that answers `true`
/// for pools it did not create can steal attribution for somebody else's launch — which is why the
/// answer is only as good as the launchpad's own listing, and why `provenanceOf` returns the
/// launchpad's verification and listing status alongside the attribution rather than after it.
///
/// ############################### IMPLEMENTING IT ###############################
///
/// For a kit that already keeps a per-pool record — `LaunchpadKit` keeps
/// `_records[poolId].operator` — this is a one-line forward:
///
///     function launchOriginOf(bytes32 poolId) external view returns (address) {
///         return _records[PoolId.wrap(poolId)].operator;
///     }
///
/// `bytes32` rather than `PoolId` on purpose: the registry must be able to call this on a contract
/// it has never seen, compiled against a version of core it does not share.
///
/// The registry calls this through a gas-capped `staticcall` with a fixed 32-byte output buffer, so
/// an implementation that reverts, loops forever or returns a bomb costs the CALLER its probe
/// budget and nothing more — it does not brick anybody else's registration. Keep the implementation
/// `view` and cheap; anything that cannot answer inside the probe budget reads as "did not vouch".
interface IDeepCoreLaunchOrigin {
    /// @notice Who this contract created `poolId` for.
    /// @param poolId The pool id, i.e. `keccak256` over the `PoolKey`.
    /// @return creator The account this launchpad recorded as the launch's creator, or
    /// `address(0)` if this contract did not create that pool. Returning a non-zero address for a
    /// pool you did not create is a lie your own address is permanently attached to.
    function launchOriginOf(bytes32 poolId) external view returns (address creator);
}
