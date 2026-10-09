// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2024 PancakeSwap
pragma solidity 0.8.26;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {TransientSlot} from "hp-transient/TransientSlot.sol";

/// @dev Record all token accumulation and swap direction of the transaction for non-infinity pools.
/// @dev Record infinity swap history list for infinity pools.
library MixedQuoterRecorder {
    /// @dev uint256 internal constant SWAP_DIRECTION = uint256(keccak256("MIXED_QUOTER_SWAP_DIRECTION")) - 1;
    uint256 internal constant SWAP_DIRECTION = 0x420071594cddc2905acbd674683749db4c139d373cc290ba8d49c75296a9f1f9;

    /// @dev uint256 internal constant SWAP_TOKEN0_ACCUMULATION = uint256(keccak256("MIXED_QUOTER_SWAP_TOKEN0_ACCUMULATION")) - 1;
    uint256 internal constant SWAP_TOKEN0_ACCUMULATION =
        0x6859b060ba2f84c00df66c40e8848222c89b2fcc89d5edc84074b9878818ea86;

    /// @dev uint256 internal constant SWAP_TOKEN1_ACCUMULATION = uint256(keccak256("MIXED_QUOTER_SWAP_TOKEN1_ACCUMULATION")) - 1;
    uint256 internal constant SWAP_TOKEN1_ACCUMULATION =
        0x8039a0cfe43b448f327ddf378771d67fba431d4dbc5c8f9531fa80f8a45125e9;

    /// @dev uint256 internal SWAP_SS = uint256(keccak256("MIXED_QUOTER_SWAP_SS")) - 1;
    uint256 internal constant SWAP_SS = 0x0b6c8b64c3ab4ac7b96ca59ae1454278ba2d62c99873c03d98ae968df846210a;

    /// @dev uint256 internal SWAP_V2 = uint256(keccak256("MIXED_QUOTER_SWAP_V2")) - 1;
    uint256 internal constant SWAP_V2 = 0xfb50ad98219c08ac49c2f2012c28ee455be42a0adc9a9a5df9e0882de4cf56b5;

    /// @dev uint256 internal constant SWAP_V3 = uint256(keccak256("MIXED_QUOTER_SWAP_V3")) - 1;
    uint256 internal constant SWAP_V3 = 0xd9d373c35d602baa7832c86d4af60fe46a2e18634c87bebc20d0050afb7633b3;

    /// @dev uint256 internal constant SWAP_INFI_CL = uint256(keccak256("MIXED_QUOTER_SWAP_INFI_CL")) - 1;
    uint256 internal constant SWAP_INFI_CL = 0x4feb57dd10cb5162909904ca541d6f7c45508b5d9792044648a6eba88f79d97;

    /// @dev uint256 internal constant SWAP_INFI_BIN = uint256(keccak256("MIXED_QUOTER_SWAP_INFI_BIN")) - 1;
    uint256 internal constant SWAP_INFI_BIN = 0x5f3e6018e8b2ccef782c927f292822290a80de8ee586b625fcd9a2e443bf80b1;

    /// @dev uint256 internal constant SWAP_INFI_LIST = uint256(keccak256("MIXED_QUOTER_SWAP_INFI_LIST")) - 1;
    uint256 internal constant SWAP_INFI_LIST = 0x32f6ae18dd733261edd4a84eefa6e2b1fe927f73449d02df9df6ca8eaba3b6df;

    /// @dev DeepCoreProtocol: registry of every slot written during the current quote, so the
    /// storage backend can sweep them. uint256(keccak256("HP_MIXED_QUOTER_TOUCHED_COUNT")) - 1
    uint256 internal constant TOUCHED_COUNT = 0x6b061ba55090724efa350018a754f511c5355308c6478f0425c5cf5e78243419;

    /// @dev uint256(keccak256("HP_MIXED_QUOTER_TOUCHED_BASE")) - 1
    uint256 internal constant TOUCHED_BASE = 0xa86b85b74d41af8df7ca5b3a93365e5a56d81eba1cafd0cd67394c9c04330b5;

    /// @dev DeepCoreProtocol: nesting depth of open `multicall` scopes. Non-zero only inside a
    /// multicall frame, and self-clearing: incremented on entry, decremented on the success path,
    /// rolled back by the EVM on revert. uint256(keccak256("HP_MIXED_QUOTER_SCOPE_DEPTH")) - 1
    uint256 internal constant SCOPE_DEPTH = 0x73a2ef557c58a515cfc611f6795ccb109c1a3c629303da23ebc6e7a1b5bc3a9c;

    enum SwapDirection {
        NONE,
        ZeroForOne,
        OneForZero
    }

    error INVALID_SWAP_DIRECTION();

    /// @notice DeepCoreProtocol: clear every slot written during this quote, unless an enclosing
    /// `multicall` scope owns the sweep.
    ///
    /// @dev Under EIP-1153 the EVM discards these at end of transaction and this compiles away
    /// entirely — `IS_EIP1153` is a compile-time constant, so the whole body is dead-code
    /// eliminated and the Cancun build is byte-identical to before, with no gas change.
    ///
    /// Under the storage backend the slots would otherwise PERSIST FOREVER, which is not merely
    /// stale data but an exploitable griefing vector: `setAndCheckSwapDirection` reverts with
    /// INVALID_SWAP_DIRECTION when a pool is quoted in the opposite direction to a recorded one.
    /// A single cheap call recording a direction would permanently break quoting that pool the
    /// other way, for everyone. Accumulations and swap lists would also grow without bound,
    /// silently corrupting every later quote.
    ///
    /// WHERE THE SWEEP HAPPENS. The invariant only requires every slot to be zero by the time
    /// control leaves the OUTERMOST call into the quoter. It does not require a sweep per quote.
    /// `quoteMixedExactInputSharedContext` exists to be batched through `multicall` — each call
    /// in the batch must see the pool impact of the ones before it, which is how a split route is
    /// priced. Sweeping per quote call silently turned that into independent quotes on legacy,
    /// OVER-quoting every split route that reuses a pool. So:
    ///   - inside a multicall scope (`SCOPE_DEPTH > 0`) this is a no-op, and
    ///   - `exitScope` sweeps once when the outermost multicall returns.
    /// A quote called directly, outside any multicall, still sweeps before it returns.
    ///
    /// RESIDUAL DIVERGENCE, and it cannot be closed without an end-of-transaction hook: two
    /// SEPARATE top-level calls into the quoter from one transaction (not via multicall) share
    /// context on Cancun and do not on legacy.
    function clearContext() internal {
        if (TransientSlot.IS_EIP1153) return;
        if (TransientSlot.getUint(SCOPE_DEPTH) != 0) return;
        _sweep();
    }

    /// @notice DeepCoreProtocol: open a multicall scope. Quotes inside it share context, and their
    /// per-quote `clearContext` defers to the matching `exitScope`. Elided under EIP-1153.
    function enterScope() internal {
        if (TransientSlot.IS_EIP1153) return;
        TransientSlot.setUint(SCOPE_DEPTH, TransientSlot.getUint(SCOPE_DEPTH) + 1);
    }

    /// @notice DeepCoreProtocol: close a multicall scope; the outermost close sweeps everything
    /// recorded inside it. Must be paired with `enterScope` on the success path — the revert
    /// path needs nothing, because the EVM rolls back both the depth and every recorded slot.
    function exitScope() internal {
        if (TransientSlot.IS_EIP1153) return;
        uint256 depth = TransientSlot.getUint(SCOPE_DEPTH) - 1; // checked: underflow reverts
        TransientSlot.setUint(SCOPE_DEPTH, depth);
        if (depth == 0) _sweep();
    }

    function _sweep() private {
        uint256 count = TransientSlot.getUint(TOUCHED_COUNT);
        for (uint256 i = 0; i < count; ++i) {
            uint256 slot = TransientSlot.getUint(TOUCHED_BASE + i);
            TransientSlot.setUint(slot, 0);
            TransientSlot.setUint(TOUCHED_BASE + i, 0);
        }
        TransientSlot.setUint(TOUCHED_COUNT, 0);
    }

    /// @dev Register a written slot for the end-of-quote sweep. No-op (and fully elided) under
    /// EIP-1153. A slot may be registered more than once; zeroing twice is idempotent.
    function _markTouched(uint256 slot) private {
        if (TransientSlot.IS_EIP1153) return;

        uint256 count = TransientSlot.getUint(TOUCHED_COUNT);
        TransientSlot.setUint(TOUCHED_BASE + count, slot);
        TransientSlot.setUint(TOUCHED_COUNT, count + 1);
    }

    /// @dev Record and check the swap direction of the transaction.
    /// @dev Only support one direction for same non-infinity pool in one transaction.
    /// @param poolHash The hash of the pool.
    /// @param isZeroForOne The direction of the swap.
    function setAndCheckSwapDirection(bytes32 poolHash, bool isZeroForOne) internal {
        uint256 swapDirection = isZeroForOne ? uint256(SwapDirection.ZeroForOne) : uint256(SwapDirection.OneForZero);

        uint256 currentDirection = getSwapDirection(poolHash);
        if (currentDirection == uint256(SwapDirection.NONE)) {
            uint256 directionSlot = uint256(keccak256(abi.encode(poolHash, SWAP_DIRECTION)));
            TransientSlot.setUint(directionSlot, swapDirection);
            _markTouched(directionSlot);
        } else if (currentDirection != swapDirection) {
            revert INVALID_SWAP_DIRECTION();
        }
    }

    /// @dev Get the swap direction of the transaction.
    /// @param poolHash The hash of the pool.
    /// @return swapDirection The direction of the swap.
    function getSwapDirection(bytes32 poolHash) internal view returns (uint256 swapDirection) {
        uint256 directionSlot = uint256(keccak256(abi.encode(poolHash, SWAP_DIRECTION)));
        swapDirection = TransientSlot.getUint(directionSlot);
    }

    /// @dev Record the swap token accumulation of the pool.
    /// @param poolHash The hash of the pool.
    /// @param amountIn The amount of tokenIn.
    /// @param amountOut The amount of tokenOut.
    /// @param isZeroForOne The direction of the swap.
    function setPoolSwapTokenAccumulation(bytes32 poolHash, uint256 amountIn, uint256 amountOut, bool isZeroForOne)
        internal
    {
        uint256 token0Slot = uint256(keccak256(abi.encode(poolHash, SWAP_TOKEN0_ACCUMULATION)));
        uint256 token1Slot = uint256(keccak256(abi.encode(poolHash, SWAP_TOKEN1_ACCUMULATION)));
        uint256 amount0;
        uint256 amount1;
        if (isZeroForOne) {
            amount0 = amountIn;
            amount1 = amountOut;
        } else {
            amount0 = amountOut;
            amount1 = amountIn;
        }
        TransientSlot.setUint(token0Slot, amount0);
        TransientSlot.setUint(token1Slot, amount1);
        _markTouched(token0Slot);
        _markTouched(token1Slot);
    }

    // @dev Get the swap token accumulation of the pool.
    // @param poolHash The hash of the pool.
    // @param isZeroForOne The direction of the swap.
    // @return accAmountIn The accumulation amount of tokenIn.
    // @return accAmountOut The accumulation amount of tokenOut.
    function getPoolSwapTokenAccumulation(bytes32 poolHash, bool isZeroForOne)
        internal
        view
        returns (uint256, uint256)
    {
        uint256 token0Slot = uint256(keccak256(abi.encode(poolHash, SWAP_TOKEN0_ACCUMULATION)));
        uint256 token1Slot = uint256(keccak256(abi.encode(poolHash, SWAP_TOKEN1_ACCUMULATION)));
        uint256 amount0 = TransientSlot.getUint(token0Slot);
        uint256 amount1 = TransientSlot.getUint(token1Slot);
        if (isZeroForOne) {
            return (amount0, amount1);
        } else {
            return (amount1, amount0);
        }
    }

    /// @dev Record the swap history list of infinity pool.
    /// @param poolHash The hash of the pool.
    /// @param swapListBytes The swap history list bytes.
    function setInfiPoolSwapList(bytes32 poolHash, bytes memory swapListBytes) internal {
        uint256 swapListSlot = uint256(keccak256(abi.encode(poolHash, SWAP_INFI_LIST)));
        uint256 length = swapListBytes.length;

        // save the length of the bytes
        TransientSlot.setUint(swapListSlot, length);
        _markTouched(swapListSlot);

        // save data in next slot
        uint256 dataSlot = swapListSlot + 1;
        for (uint256 i = 0; i < length; i += 32) {
            uint256 word;
            assembly ("memory-safe") {
                word := mload(add(swapListBytes, add(0x20, i)))
            }
            TransientSlot.setUint(dataSlot + i / 32, word);
            _markTouched(dataSlot + i / 32);
        }
    }

    /// @dev Get the swap history list of infinity pool.
    /// @param poolHash The hash of the pool.
    /// @return swapListBytes The swap history list bytes.
    function getInfiPoolSwapList(bytes32 poolHash) internal view returns (bytes memory swapListBytes) {
        uint256 swapListSlot = uint256(keccak256(abi.encode(poolHash, SWAP_INFI_LIST)));
        uint256 length = TransientSlot.getUint(swapListSlot);

        /// @dev allocates ceil(length/32)*32 bytes, so the full-word writes below stay in bounds
        swapListBytes = new bytes(length);

        uint256 dataSlot = swapListSlot + 1;
        for (uint256 i = 0; i < length; i += 32) {
            uint256 word = TransientSlot.getUint(dataSlot + i / 32);
            assembly ("memory-safe") {
                mstore(add(swapListBytes, add(0x20, i)), word)
            }
        }
    }

    /// @dev Get the stable swap pool hash.
    /// @param token0 The address of token0.
    /// @param token1 The address of token1.
    /// @return poolHash The hash of the pool.
    function getSSPoolHash(address token0, address token1) internal pure returns (bytes32) {
        if (token0 == token1) revert();
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);
        return keccak256(abi.encode(token0, token1, SWAP_SS));
    }

    /// @dev Get the v2 pool hash.
    /// @param token0 The address of token0.
    /// @param token1 The address of token1.
    /// @return poolHash The hash of the pool.
    function getV2PoolHash(address token0, address token1) internal pure returns (bytes32) {
        if (token0 == token1) revert();
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);
        return keccak256(abi.encode(token0, token1, SWAP_V2));
    }

    /// @dev Get the v3 pool hash.
    /// @param token0 The address of token0.
    /// @param token1 The address of token1.
    /// @param fee The fee of the pool.
    function getV3PoolHash(address token0, address token1, uint24 fee) internal pure returns (bytes32) {
        if (token0 == token1) revert();
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);
        return keccak256(abi.encode(token0, token1, fee, SWAP_V3));
    }

    /// @dev Get the infinity cl pool hash.
    /// @param key The pool key.
    /// @return poolHash The hash of the pool.
    function getInfiCLPoolHash(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, SWAP_INFI_CL));
    }

    /// @dev Get the infinity bin pool hash.
    /// @param key The pool key.
    /// @return poolHash The hash of the pool.
    function getInfiBinPoolHash(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key, SWAP_INFI_BIN));
    }
}
