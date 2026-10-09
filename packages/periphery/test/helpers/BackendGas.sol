// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity ^0.8.24;

import {TransientSlot} from "hp-transient/TransientSlot.sol";

/// @notice Per-backend gas ceilings for upstream quoter tests.
///
/// @dev The quoters report `gasEstimate = gasBefore - gasleft()` around a `vault.lock`. Under
/// the storage backend (FOUNDRY_PROFILE=legacy) the Vault's lock, delta and reserve slots are
/// SSTORE/SLOAD instead of TSTORE/TLOAD, which costs ~85-120k more per locked hop. The quoted
/// AMOUNTS are identical on both backends and stay asserted exactly by the calling tests; only
/// the gas band moves.
///
/// Rules:
///   - `eip1153Ceiling` is always the upstream literal, unchanged. The default build asserts
///     exactly what upstream asserts.
///   - `storageCeiling` is derived from a measured legacy run (forge 1.8.1, 2026-09-13):
///         storageCeiling = ceil(measured * 1.05 / 10_000) * 10_000
///     i.e. at least 5% headroom, at upstream's 10k granularity. A regression larger than that
///     on the storage backend should fail, not be absorbed. Re-measure rather than bump.
library BackendGas {
    function ceiling(uint256 eip1153Ceiling, uint256 storageCeiling) internal pure returns (uint256) {
        return TransientSlot.IS_EIP1153 ? eip1153Ceiling : storageCeiling;
    }
}
