// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

/// @title RewardMath
/// @notice Arithmetic that CANNOT revert, for the code paths a liquidity removal runs through.
/// @dev Every function here saturates or wraps instead of reverting. A wrong number on these paths is a
/// mis-counted reward; a revert is an LP who cannot withdraw. The hook prefers the first, always.
library RewardMath {
    uint256 internal constant MAX = type(uint256).max;

    /// @dev `a + b`, clamped at `type(uint256).max`.
    function satAdd(uint256 a, uint256 b) internal pure returns (uint256 c) {
        unchecked {
            c = a + b;
            if (c < a) c = MAX;
        }
    }

    /// @dev `a - b`, clamped at zero.
    function satSub(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            return a > b ? a - b : 0;
        }
    }

    /// @dev `a + b` for liquidity, clamped at `type(uint128).max`.
    function satAdd128(uint128 a, uint256 b) internal pure returns (uint128) {
        unchecked {
            uint256 c = uint256(a) + (b > type(uint128).max ? type(uint128).max : b);
            return c > type(uint128).max ? type(uint128).max : uint128(c);
        }
    }

    /// @dev `a - b` for liquidity, clamped at zero.
    function satSub128(uint128 a, uint256 b) internal pure returns (uint128) {
        unchecked {
            return b >= a ? 0 : uint128(uint256(a) - b);
        }
    }

    /// @dev `a + d` for a signed liquidity net, clamped to the int128 range.
    function satAddNet(int128 a, int256 d) internal pure returns (int128) {
        unchecked {
            // |a| < 2^127 and |d| is bounded by the callers to 2^128, so the int256 sum cannot overflow.
            int256 c = int256(a) + d;
            if (c > type(int128).max) return type(int128).max;
            if (c < type(int128).min) return type(int128).min;
            return int128(c);
        }
    }

    /// @dev `liquidity + net` (or `- net`) for active liquidity, clamped to [0, 2^128 - 1].
    function applyNet(uint128 liquidity, int128 net, bool add) internal pure returns (uint128) {
        unchecked {
            int256 d = add ? int256(net) : -int256(net);
            int256 c = int256(uint256(liquidity)) + d;
            if (c <= 0) return 0;
            if (c > int256(uint256(type(uint128).max))) return type(uint128).max;
            return uint128(uint256(c));
        }
    }

    /// @dev `floor(a * b / 2^128)` over the full 512-bit product, clamped at `type(uint256).max`.
    function mulShr128Sat(uint256 a, uint256 b) internal pure returns (uint256 r) {
        uint256 lo;
        uint256 hi;
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            lo := mul(a, b)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
        // the result is (hi:lo) >> 128; it overflows 256 bits when hi >= 2^128
        if (hi >> 128 != 0) return MAX;
        unchecked {
            r = (hi << 128) | (lo >> 128);
        }
    }

    /// @dev `floor(a * b / 2^64)`, clamped at `type(uint256).max`.
    function mulShr64Sat(uint256 a, uint256 b) internal pure returns (uint256 r) {
        uint256 lo;
        uint256 hi;
        assembly ("memory-safe") {
            let mm := mulmod(a, b, not(0))
            lo := mul(a, b)
            hi := sub(sub(mm, lo), lt(mm, lo))
        }
        if (hi >> 64 != 0) return MAX;
        unchecked {
            r = (hi << 192) | (lo >> 64);
        }
    }

    /// @dev Floor division toward negative infinity, as core's `TickBitmap.compress`. `s > 0`.
    function compress(int256 t, int256 s) internal pure returns (int256 q) {
        unchecked {
            q = t / s;
            if (t < 0 && t % s != 0) q--;
        }
    }
}
