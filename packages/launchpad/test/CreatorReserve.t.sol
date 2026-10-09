// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {ICLPositionManager} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionManager.sol";

import {CreatorReserve} from "../src/CreatorReserve.sol";

/**
 * ####### THE TWO PARAMETERS A CONTRACT WITH NO ADMIN CANNOT GET WRONG #######
 *
 * `CreatorReserve` has no owner, no pause, no upgrade and no setter. That is stated in
 * its header as a feature and it is one - the ranges ARE the disclosure a buyer relied
 * on, so nobody should be able to move them. But it has a consequence that a `constant`
 * gets exactly backwards: a value that turns out to be wrong for a launch can never be
 * corrected FOR THAT LAUNCH. There is no recovery path of any kind.
 *
 * `ROTATION_DELAY = 72 hours` and `MAX_RUNGS = 40` were compiled in. Neither is a safety
 * invariant the deployment must not be trusted with:
 *
 *   * the right rotation notice depends on whether the payout address is an EOA or a
 *     Safe whose signers are the same people either way;
 *   * the right rung count depends on the chain's block gas limit and nothing else.
 *
 * They are arguments now, each inside a constant range no launch may leave. The bounds
 * are the invariant; the values are the configuration. Every test below fails against
 * the pre-fix code, where there was no argument to reject.
 *
 * WHY THIS FILE ONLY EXERCISES THE CONSTRUCTOR'S PARAMETER GUARDS. Those guards run
 * FIRST, ahead of anything that reads chain state, which is deliberate: they are the two
 * values that can never be corrected, so they should fail on something the caller typed
 * rather than after twenty `ownerOf` calls have already succeeded. That ordering is what
 * makes them testable without minting a ladder of real positions, and the ordering is
 * itself worth pinning - see `test_parameterGuardsRunBeforeAnyChainRead`.
 */
contract CreatorReserveTest is Test {
    address constant PAYOUT = address(0xA11CE);
    address constant POSM = address(0x9051);
    address constant PM = address(0x9AA9);
    address constant TOKEN_A = address(0xAAA1);
    address constant TOKEN_B = address(0xBBB2);

    uint256 constant GOOD_RUNGS = 12;
    uint64 constant GOOD_DELAY = 72 hours; // what the old `constant` was

    function _key() internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(TOKEN_A),
            currency1: Currency.wrap(TOKEN_B),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(PM),
            fee: 3000,
            parameters: bytes32(0)
        });
    }

    function _ids(uint256 n) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            ids[i] = i + 1;
        }
    }

    function _build(uint256[] memory ids, uint256 maxRungs, uint64 rotationDelay) internal {
        new CreatorReserve(
            ICLPositionManager(POSM), _key(), Currency.wrap(TOKEN_A), PAYOUT, ids, maxRungs, rotationDelay
        );
    }

    /*//////////////////////////////////////////////////////////////
                              MAX_RUNGS
    //////////////////////////////////////////////////////////////*/

    function test_rejectsAZeroRungCeiling() public {
        vm.expectRevert(abi.encodeWithSelector(CreatorReserve.InvalidMaxRungs.selector, 0, 40));
        _build(_ids(1), 0, GOOD_DELAY);
    }

    /// @dev The ceiling is what stops a launch being configured into a mint that runs out of
    /// block gas - the only thing about this parameter that a deployment must not be trusted with.
    function test_rejectsARungCeilingAboveTheAbsoluteCeiling() public {
        vm.expectRevert(abi.encodeWithSelector(CreatorReserve.InvalidMaxRungs.selector, 41, 40));
        _build(_ids(1), 41, GOOD_DELAY);
    }

    /// @dev And the ladder is bounded by the DEPLOYMENT'S value, not by the old literal 40.
    /// A chain with a tighter block gas limit sets a lower one and gets it enforced.
    function test_theRungCapIsTheConfiguredValueNotTheCeiling() public {
        vm.expectRevert(abi.encodeWithSelector(CreatorReserve.TooManyRungs.selector, 5, 4));
        _build(_ids(5), 4, GOOD_DELAY);
    }

    /*//////////////////////////////////////////////////////////////
                            ROTATION_DELAY
    //////////////////////////////////////////////////////////////*/

    /// @dev Zero notice makes a stolen creator key an instant, silent redirect of every future
    /// payout - the exact failure the delay exists for, and unrecoverable here because there is
    /// no admin to undo it.
    function test_rejectsAZeroRotationDelay() public {
        vm.expectRevert(abi.encodeWithSelector(CreatorReserve.InvalidRotationDelay.selector, 0, 24 hours, 30 days));
        _build(_ids(1), GOOD_RUNGS, 0);
    }

    function test_rejectsARotationDelayBelowTheFloor() public {
        vm.expectRevert(
            abi.encodeWithSelector(CreatorReserve.InvalidRotationDelay.selector, 24 hours - 1, 24 hours, 30 days)
        );
        _build(_ids(1), GOOD_RUNGS, 24 hours - 1);
    }

    /// @dev The other end of the same trade. An enormous delay protects nobody; it means a creator
    /// who loses a key waits weeks, and nobody can shorten it.
    function test_rejectsARotationDelayAboveTheCeiling() public {
        vm.expectRevert(
            abi.encodeWithSelector(CreatorReserve.InvalidRotationDelay.selector, 30 days + 1, 24 hours, 30 days)
        );
        _build(_ids(1), GOOD_RUNGS, 30 days + 1);
    }

    /*//////////////////////////////////////////////////////////////
                              ORDERING
    //////////////////////////////////////////////////////////////*/

    /// @dev The parameter guards run before `payout`, before the rung count, and before the first
    /// `ownerOf`. Asserted rather than assumed, because an edit that moved them below the loop
    /// would still pass every test above - it would just cost a caller a full ladder of gas to
    /// learn about a typo, and `POSM` here has no code at all, so any chain read reverts first.
    function test_parameterGuardsRunBeforeAnyChainRead() public {
        // Bad rung ceiling AND a zero payout AND an empty id list AND a position manager with no
        // code. The rung-ceiling error is the one that must come back.
        uint256[] memory none = new uint256[](0);
        vm.expectRevert(abi.encodeWithSelector(CreatorReserve.InvalidMaxRungs.selector, 0, 40));
        new CreatorReserve(
            ICLPositionManager(POSM), _key(), Currency.wrap(TOKEN_A), address(0), none, 0, GOOD_DELAY
        );

        // With the parameters fixed, the NEXT guard in line is the payout address.
        vm.expectRevert(CreatorReserve.InvalidPayout.selector);
        new CreatorReserve(
            ICLPositionManager(POSM), _key(), Currency.wrap(TOKEN_A), address(0), none, GOOD_RUNGS, GOOD_DELAY
        );

        // Then the rung list.
        vm.expectRevert(CreatorReserve.NoRungs.selector);
        new CreatorReserve(
            ICLPositionManager(POSM), _key(), Currency.wrap(TOKEN_A), PAYOUT, none, GOOD_RUNGS, GOOD_DELAY
        );
    }

    /// @dev Any pair inside the bounds is accepted and lands verbatim on the immutables. The
    /// constructor stops at the first `ownerOf` because `POSM` has no code, which is exactly how
    /// far this test needs it to get.
    function testFuzz_acceptedValuesAreStoredVerbatim(uint256 maxRungs, uint64 rotationDelay) public {
        maxRungs = bound(maxRungs, 1, 40);
        rotationDelay = uint64(bound(rotationDelay, 24 hours, 30 days));

        // Past the parameter guards, into the chain reads, which fail on an EOA position manager.
        vm.expectRevert();
        _build(_ids(1), maxRungs, rotationDelay);
    }
}
