/*
  DeepCore Protocol

  Launch a DEX or a launchpad in one transaction, on a shared core that's already live.

  Website:  https://deepcore.fun
  Docs:     https://deepcore.fun/docs
*/
// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {BinShape} from "../interfaces/ILaunchpadKitV2.sol";

/// @title BinLaunchShapes
/// @notice Builds and validates the single-sided bin distributions a `LaunchpadKitV2` Bin leg seeds.
///
/// @dev Everything here is in FILL ORDER - offset 1 is the bin next to the active bin on the launch
/// token's side - so the rules read the same whichever currency the launch token sorts to. The kit maps
/// offsets onto ids (above active for currency0, below for currency1) after validation.
///
/// THE RULES (docs/kit-v2-integration.md "Kit v2 (implemented)", refining section 7):
///   R1 single-sided   every offset >= 1, so no bin is the active bin or on the quote side
///   R2 monotonic      offsets strictly increasing, so bin prices move strictly away from spot
///   R3 no floor gap   offsets[k] == k + 1 for every k < floorBins, with 1 <= floorBins <= n
///   R4 bin cap        1 <= n <= maxBins (<= the Bin locker's maxBinsPerLock), lengths equal
///   R5 totals         sum(weights) == 1e18 exactly
///   R6 per-bin        every weight > 0 AND floor(amount * weight / 1e18) > 0, so no bin is empty
///
/// Named shapes compute floored weights and give the LAST bin `1e18 - sum(previous)`, so R5 holds exactly.
/// Their parameters are fixed per name on purpose: a named shape is a promise a UI can describe in one
/// word. Anything else is `Custom`, which passes the identical validator.
library BinLaunchShapes {
    uint256 internal constant PRECISION = 1e18;

    /// @notice Exponential: each bin holds 9/10 of the previous one.
    uint256 internal constant EXP_RATIO_NUM = 9;
    uint256 internal constant EXP_RATIO_DEN = 10;

    /// @notice Stepped: tiers of 4 contiguous bins separated by 2 empty bins, tier weight decreasing.
    uint256 internal constant STEP_TIER_BINS = 4;
    uint256 internal constant STEP_GAP_BINS = 2;

    error BinShapeBadCount(uint256 count, uint256 maxBins);
    error BinShapeLengthMismatch(uint256 offsets, uint256 weights);
    error BinShapeNotSingleSided(uint256 index);
    error BinShapeNotMonotonic(uint256 index);
    error BinShapeInvalidFloor(uint256 floorBins, uint256 count);
    error BinShapeGapBelowFloor(uint256 index);
    error BinShapeZeroWeight(uint256 index);
    error BinShapeDustBin(uint256 index);
    error BinShapeWeightsDoNotSum(uint256 sum);

    /// @notice The arrays a named shape resolves to.
    function build(BinShape shape, uint256 n, uint256 maxBins)
        internal
        pure
        returns (uint24[] memory offsets, uint64[] memory weights, uint16 floorBins)
    {
        if (n == 0 || n > maxBins) revert BinShapeBadCount(n, maxBins);
        offsets = new uint24[](n);
        weights = new uint64[](n);
        uint256[] memory raw = new uint256[](n);
        uint256 total;
        uint256 tiers = (n + STEP_TIER_BINS - 1) / STEP_TIER_BINS;
        uint256 r = PRECISION;
        for (uint256 k; k < n; ++k) {
            if (shape == BinShape.Linear) {
                raw[k] = n - k;
            } else if (shape == BinShape.Exponential) {
                raw[k] = r;
                r = r * EXP_RATIO_NUM / EXP_RATIO_DEN;
            } else if (shape == BinShape.Stepped) {
                raw[k] = tiers - k / STEP_TIER_BINS;
            } else {
                // Flat. `Custom` never reaches here: the kit validates caller arrays instead.
                raw[k] = 1;
            }
            total += raw[k];
            // n <= maxBins <= 256, so offsets stay far below 2^24.
            // forge-lint: disable-next-line(unsafe-typecast)
            offsets[k] = uint24(shape == BinShape.Stepped ? 1 + k + STEP_GAP_BINS * (k / STEP_TIER_BINS) : 1 + k);
        }
        uint256 sum;
        for (uint256 k; k + 1 < n; ++k) {
            // raw[k] <= total, so each weight <= 1e18 < 2^64.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint64 w = uint64(raw[k] * PRECISION / total);
            weights[k] = w;
            sum += w;
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        weights[n - 1] = uint64(PRECISION - sum);
        // forge-lint: disable-next-line(unsafe-typecast)
        floorBins = uint16(shape == BinShape.Stepped && n > STEP_TIER_BINS ? STEP_TIER_BINS : n);
    }

    /// @notice R1-R6 for one leg seeding `amount` launch-token units.
    function validate(uint24[] memory offsets, uint64[] memory weights, uint256 floorBins, uint256 maxBins, uint256 amount)
        internal
        pure
    {
        uint256 n = offsets.length;
        if (n == 0 || n > maxBins) revert BinShapeBadCount(n, maxBins); // R4
        if (weights.length != n) revert BinShapeLengthMismatch(n, weights.length); // R4
        if (floorBins == 0 || floorBins > n) revert BinShapeInvalidFloor(floorBins, n); // R3
        uint256 sum;
        for (uint256 k; k < n; ++k) {
            uint256 off = offsets[k];
            if (off == 0) revert BinShapeNotSingleSided(k); // R1
            if (k != 0 && off <= offsets[k - 1]) revert BinShapeNotMonotonic(k); // R2
            if (k < floorBins && off != k + 1) revert BinShapeGapBelowFloor(k); // R3
            uint256 w = weights[k];
            if (w == 0) revert BinShapeZeroWeight(k); // R6
            if (amount * w / PRECISION == 0) revert BinShapeDustBin(k); // R6
            sum += w;
        }
        if (sum != PRECISION) revert BinShapeWeightsDoNotSum(sum); // R5
    }
}
