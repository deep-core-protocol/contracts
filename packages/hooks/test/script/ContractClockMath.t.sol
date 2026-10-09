// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {ContractClockMath} from "../../script/ContractClock.sol";

/// @dev External wrapper, so `vm.expectRevert` sees a call boundary.
contract ContractClockMathHarness {
    function requireSaneTimestamp(uint256 evm, uint256 header, uint256 wall) external pure {
        ContractClockMath.requireSaneTimestamp(evm, header, wall);
    }
}

/// @title ContractClockMathTest
/// @notice The deploy-time guard for timestamp-based contracts: the chain's `block.timestamp` must
/// agree with the forked header and with the operator's wall clock before anything is broadcast.
/// @dev Fixture time is a real Robinhood (4663) header timestamp, 1,789,346,507 (2026-09-13).
contract ContractClockMathTest is Test {
    ContractClockMathHarness h;

    uint256 constant T = 1_789_346_507;

    function setUp() public {
        h = new ContractClockMathHarness();
    }

    function test_acceptsAHealthyChain() public view {
        // Probe answered a couple of blocks after the fork point, operator clock 3 s behind.
        h.requireSaneTimestamp(T + 2, T, T - 1);
    }

    /// @dev MUTATION-CHECKED: dropping the header comparison makes this pass silently.
    function test_refusesAProbeFromDifferentState() public {
        vm.expectRevert(abi.encodeWithSelector(ContractClockMath.EvmTimestampDisagreesWithHeader.selector, T + 61, T));
        h.requireSaneTimestamp(T + 61, T, T + 61);
    }

    function test_headerBoundaryIsInclusive() public {
        h.requireSaneTimestamp(T + 60, T, T + 60);
        h.requireSaneTimestamp(T, T + 60, T);
        vm.expectRevert(abi.encodeWithSelector(ContractClockMath.EvmTimestampDisagreesWithHeader.selector, T, T + 61));
        h.requireSaneTimestamp(T, T + 61, T);
    }

    /// @dev The Nitro forward bound. A sequencer stamping an hour ahead is legal on chain and is
    /// exactly when a deployment of time-bounded contracts should wait.
    function test_refusesASequencerAnHourAhead() public {
        vm.expectRevert(abi.encodeWithSelector(ContractClockMath.ChainClockOffWallClock.selector, T + 3600, T));
        h.requireSaneTimestamp(T + 3600, T + 3600, T);
    }

    /// @dev The Nitro backward bound. A sequencer catching up after an outage can be hours behind.
    function test_refusesAChainCatchingUpFromAnOutage() public {
        vm.expectRevert(abi.encodeWithSelector(ContractClockMath.ChainClockOffWallClock.selector, T - 7200, T));
        h.requireSaneTimestamp(T - 7200, T - 7200, T);
    }

    function test_wallClockBoundaryIsInclusive() public {
        h.requireSaneTimestamp(T + 300, T + 300, T);
        h.requireSaneTimestamp(T - 300, T - 300, T);
        vm.expectRevert(abi.encodeWithSelector(ContractClockMath.ChainClockOffWallClock.selector, T + 301, T));
        h.requireSaneTimestamp(T + 301, T + 301, T);
    }

    function testFuzz_acceptedIffBothWithinTolerance(uint256 evm, uint256 header, uint256 wall) public {
        evm = bound(evm, T - 10 days, T + 10 days);
        header = bound(header, T - 10 days, T + 10 days);
        wall = bound(wall, T - 10 days, T + 10 days);
        uint256 dh = evm > header ? evm - header : header - evm;
        uint256 dw = evm > wall ? evm - wall : wall - evm;
        // A specific selector, not a bare expectRevert: with `allow_internal_expect_revert` a bare
        // one can be satisfied by the wrong failure. The header check runs first.
        if (dh > 60) {
            vm.expectRevert(abi.encodeWithSelector(ContractClockMath.EvmTimestampDisagreesWithHeader.selector, evm, header));
        } else if (dw > 300) {
            vm.expectRevert(abi.encodeWithSelector(ContractClockMath.ChainClockOffWallClock.selector, evm, wall));
        }
        h.requireSaneTimestamp(evm, header, wall);
    }
}
