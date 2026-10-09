// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity ^0.8.24;

import {Test, stdError} from "forge-std/Test.sol";
import {ReentrancyLock} from "../../src/base/ReentrancyLock.sol";
import {MixedQuoterRecorder} from "../../src/libraries/MixedQuoterRecorder.sol";
import {TransientSlot} from "hp-transient/TransientSlot.sol";

/// @dev Exposes the recorder library's internals.
///
/// IMPORTANT: this project runs with `isolate = true`, so every top-level call from a test is its
/// own transaction. Under EIP-1153 that means transient state is discarded between calls, and a
/// test that writes in one call and reads in the next would pass on the storage backend while
/// proving nothing on Cancun. Each probe below therefore performs its write, read and sweep
/// inside a SINGLE external call and returns what it observed.
contract RecorderHarness {
    function probeDirection(bytes32 poolHash) external returns (uint256 during, uint256 afterSweep) {
        MixedQuoterRecorder.setAndCheckSwapDirection(poolHash, true);
        during = MixedQuoterRecorder.getSwapDirection(poolHash);
        MixedQuoterRecorder.clearContext();
        afterSweep = MixedQuoterRecorder.getSwapDirection(poolHash);
    }

    function probeAccumulation(bytes32 poolHash)
        external
        returns (uint256 in0, uint256 out0, uint256 in1, uint256 out1)
    {
        MixedQuoterRecorder.setPoolSwapTokenAccumulation(poolHash, 5 ether, 7 ether, true);
        (in0, out0) = MixedQuoterRecorder.getPoolSwapTokenAccumulation(poolHash, true);
        MixedQuoterRecorder.clearContext();
        (in1, out1) = MixedQuoterRecorder.getPoolSwapTokenAccumulation(poolHash, true);
    }

    function probeSwapList(bytes32 poolHash, bytes memory data)
        external
        returns (bytes memory during, bytes memory afterSweep)
    {
        MixedQuoterRecorder.setInfiPoolSwapList(poolHash, data);
        during = MixedQuoterRecorder.getInfiPoolSwapList(poolHash);
        MixedQuoterRecorder.clearContext();
        afterSweep = MixedQuoterRecorder.getInfiPoolSwapList(poolHash);
    }

    /// @dev Both writes in one call, so the guard is exercised within a single quote.
    function probeSameDirectionGuard(bytes32 poolHash) external {
        MixedQuoterRecorder.setAndCheckSwapDirection(poolHash, true);
        MixedQuoterRecorder.setAndCheckSwapDirection(poolHash, false);
    }

    /// @dev One "quote": record state then sweep, mirroring quoteMixedExactInputWithContext.
    function quoteAndClear(bytes32 poolHash, bool isZeroForOne) external {
        MixedQuoterRecorder.setAndCheckSwapDirection(poolHash, isZeroForOne);
        MixedQuoterRecorder.setPoolSwapTokenAccumulation(poolHash, 1 ether, 2 ether, isZeroForOne);
        MixedQuoterRecorder.clearContext();
    }

    function readDirection(bytes32 poolHash) external view returns (uint256) {
        return MixedQuoterRecorder.getSwapDirection(poolHash);
    }

    /// @dev A quote's own clearContext inside an open scope must defer; the scope close sweeps.
    function probeScope(bytes32 poolHash)
        external
        returns (uint256 afterInnerClear, uint256 afterNestedExit, uint256 afterOuterExit)
    {
        MixedQuoterRecorder.enterScope();
        MixedQuoterRecorder.enterScope();
        MixedQuoterRecorder.setAndCheckSwapDirection(poolHash, true);
        MixedQuoterRecorder.clearContext();
        afterInnerClear = MixedQuoterRecorder.getSwapDirection(poolHash);
        MixedQuoterRecorder.exitScope();
        afterNestedExit = MixedQuoterRecorder.getSwapDirection(poolHash);
        MixedQuoterRecorder.exitScope();
        afterOuterExit = MixedQuoterRecorder.getSwapDirection(poolHash);
    }

    function exitWithoutEnter() external {
        MixedQuoterRecorder.exitScope();
    }
}

contract LockHarness is ReentrancyLock {
    function locked() external view returns (address) {
        return _getLocker();
    }

    function doWork() external isNotLocked returns (address seen) {
        seen = _getLocker();
    }

    function reenter() external isNotLocked {
        LockHarness(address(this)).doWork();
    }

    function boom() external isNotLocked {
        revert("boom");
    }
}

/// @title Periphery portable-backend safety
/// @notice Must pass under BOTH profiles:
///     forge test --match-path "test/transient/*"
///     FOUNDRY_PROFILE=legacy forge test --match-path "test/transient/*"
contract PeripheryBackendSafetyTest is Test {
    RecorderHarness recorder;
    LockHarness lock;

    bytes32 constant POOL_A = keccak256("POOL_A");

    function setUp() public {
        recorder = new RecorderHarness();
        lock = new LockHarness();
    }

    /*//////////////////////////////////////////////////////////////
                            ReentrancyLock
    //////////////////////////////////////////////////////////////*/

    function test_lock_isHeldDuringCall() public {
        assertEq(lock.doWork(), address(this), "locker must be the caller during the call");
    }

    function test_lock_clearsAfterSuccess() public {
        lock.doWork();
        assertEq(lock.locked(), address(0), "locker must be cleared after a successful call");
    }

    function test_lock_blocksReentrancy() public {
        vm.expectRevert(ReentrancyLock.ContractLocked.selector);
        lock.reenter();
    }

    /// @dev On revert the EVM rolls back the frame's writes, so the slot must not stay set.
    /// This is why ReentrancyLock needs no explicit sweep on the storage backend.
    function test_lock_clearsAfterRevert() public {
        vm.expectRevert(bytes("boom"));
        lock.boom();
        assertEq(lock.locked(), address(0), "locker must not survive a reverting call");
        lock.doWork();
        assertEq(lock.locked(), address(0), "contract must remain usable");
    }

    /*//////////////////////////////////////////////////////////////
                        MixedQuoterRecorder
    //////////////////////////////////////////////////////////////*/

    function test_recorder_directionRecordedThenSwept() public {
        (uint256 during, uint256 afterSweep) = recorder.probeDirection(POOL_A);
        assertEq(during, 1, "direction must be visible mid-quote");
        if (TransientSlot.IS_EIP1153) {
            // clearContext is a deliberate no-op under EIP-1153: the EVM discards transient
            // state at end of transaction, so sweeping would be pure wasted gas.
            assertEq(afterSweep, during, "cancun: sweep is intentionally a no-op");
        } else {
            assertEq(afterSweep, 0, "storage backend: direction must be swept");
        }
    }

    function test_recorder_accumulationRecordedThenSwept() public {
        (uint256 in0, uint256 out0, uint256 in1, uint256 out1) = recorder.probeAccumulation(POOL_A);
        assertEq(in0, 5 ether, "amountIn visible mid-quote");
        assertEq(out0, 7 ether, "amountOut visible mid-quote");
        if (TransientSlot.IS_EIP1153) {
            assertEq(in1, in0, "cancun: sweep is intentionally a no-op");
            assertEq(out1, out0, "cancun: sweep is intentionally a no-op");
        } else {
            assertEq(in1, 0, "storage backend: accumulation must be swept");
            assertEq(out1, 0, "storage backend: accumulation must be swept");
        }
    }

    function test_recorder_swapListRoundTripsThenSwept() public {
        bytes memory data = abi.encode(uint256(0xdead), uint256(0xbeef), uint256(3));
        (bytes memory during, bytes memory afterSweep) = recorder.probeSwapList(POOL_A, data);
        assertEq(keccak256(during), keccak256(data), "swap list must round-trip mid-quote");
        if (TransientSlot.IS_EIP1153) {
            assertEq(afterSweep.length, during.length, "cancun: sweep is intentionally a no-op");
        } else {
            assertEq(afterSweep.length, 0, "storage backend: swap list must be swept");
        }
    }

    /// @notice The documented within-a-quote guard must still fire.
    function test_sameDirectionGuardStillFiresWithinOneQuote() public {
        vm.expectRevert(MixedQuoterRecorder.INVALID_SWAP_DIRECTION.selector);
        recorder.probeSameDirectionGuard(POOL_A);
    }

    /*//////////////////////////////////////////////////////////////
              REGRESSION GUARD - the griefing vector
    //////////////////////////////////////////////////////////////*/

    /// @notice Without the sweep, under the storage backend a recorded swap direction persists
    /// across transactions. `setAndCheckSwapDirection` then reverts with INVALID_SWAP_DIRECTION
    /// whenever the pool is later quoted the other way, so one cheap call permanently bricks
    /// quoting that pool in the opposite direction for everyone. Each quote must start clean.
    function test_dos_oppositeDirectionQuoteStillWorks() public {
        recorder.quoteAndClear(POOL_A, true);
        recorder.quoteAndClear(POOL_A, false); // must not revert
        assertEq(recorder.readDirection(POOL_A), 0, "no direction may survive a quote");
    }

    /// @notice Shared context spans a multicall scope on both backends, and the storage backend
    /// sweeps exactly once, at the outermost scope exit. The MixedQuoter-level twins of this are
    /// the `test_deepcore_*` tests at the end of test/MixedQuoter.t.sol.
    function test_recorder_scopeDefersSweepToOutermostExit() public {
        (uint256 afterInnerClear, uint256 afterNestedExit, uint256 afterOuterExit) = recorder.probeScope(POOL_A);
        assertEq(afterInnerClear, 1, "clearContext inside a scope must not sweep");
        assertEq(afterNestedExit, 1, "a nested scope exit must not sweep");
        if (TransientSlot.IS_EIP1153) {
            assertEq(afterOuterExit, 1, "cancun: sweep is intentionally a no-op");
        } else {
            assertEq(afterOuterExit, 0, "storage backend: outermost scope exit must sweep");
        }
        assertEq(recorder.readDirection(POOL_A), 0, "no direction may survive the transaction");
        recorder.quoteAndClear(POOL_A, false); // opposite direction in a later tx must not revert
    }

    /// @notice An unbalanced exit is a bug in the caller and must fail loudly, not wrap the depth
    /// to type(uint256).max and silently disable every later sweep.
    function test_recorder_unbalancedScopeExitReverts() public {
        if (TransientSlot.IS_EIP1153) {
            recorder.exitWithoutEnter(); // elided entirely under EIP-1153
        } else {
            vm.expectRevert(stdError.arithmeticError);
            recorder.exitWithoutEnter();
        }
    }

    function test_backendIdentity() public pure {
        assertTrue(TransientSlot.IS_EIP1153 || !TransientSlot.IS_EIP1153, "backend constant defined");
    }
}
