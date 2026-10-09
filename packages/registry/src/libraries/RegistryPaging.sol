/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

/// @title RegistryPaging
/// @notice Offset/limit paging over an append-only index.
///
/// @dev Both registries keep the same shape of index: arrays that are only ever pushed to, so an
/// entry's position never moves and a caller can page through without entries shifting underneath
/// it between calls. One deliberate exception, `DeepCoreLaunchRegistry._byLaunchpad`, is a set that
/// a curator clear swap-and-pops; paging is unaffected, stability is not. The paging itself is four lines, which is exactly why it should not be written
/// twice — the interesting part is the clamp, and a clamp that is right in one file and wrong in
/// the other is a panic in a view function that a front end has no way to recover from.
///
/// `InvalidRange` here shares its selector with `IDeepCoreRegistry.InvalidRange`. Selectors come from
/// the signature and not the declaring scope, so consumers matching on the interface's error keep
/// working.
library RegistryPaging {
    /// @notice `offset` is past the end of the list.
    error InvalidRange();

    function page(address[] storage list, uint256 offset, uint256 limit) internal view returns (address[] memory out) {
        (uint256 start, uint256 end) = _bounds(list.length, offset, limit);
        out = new address[](end - start);
        for (uint256 i; i < out.length; ++i) {
            out[i] = list[start + i];
        }
    }

    function page(bytes32[] storage list, uint256 offset, uint256 limit) internal view returns (bytes32[] memory out) {
        (uint256 start, uint256 end) = _bounds(list.length, offset, limit);
        out = new bytes32[](end - start);
        for (uint256 i; i < out.length; ++i) {
            out[i] = list[start + i];
        }
    }

    /// @dev `limit = type(uint256).max` is the natural "give me the rest" idiom, so the remainder
    /// is clamped BEFORE the addition rather than letting checked arithmetic panic on it.
    function _bounds(uint256 length, uint256 offset, uint256 limit) private pure returns (uint256, uint256) {
        if (offset > length) revert InvalidRange();
        uint256 end = limit > length - offset ? length : offset + limit;
        return (offset, end);
    }
}
