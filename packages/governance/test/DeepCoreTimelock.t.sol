// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {DeepCoreTimelock} from "../src/DeepCoreTimelock.sol";
import {DeepCoreProtocolFeeController} from "deepcore-fees/src/DeepCoreProtocolFeeController.sol";

/// @title DeepCoreTimelock behaviour
/// @notice This contract governs the Vault, whose `registerApp` is irreversible. The tests below
/// exist to prove the delay is real and cannot be configured away, because a timelock that does
/// not delay is worse than none: it looks like governance on a block explorer and provides none.
contract DeepCoreTimelockTest is Test {
    DeepCoreTimelock internal custody;
    DeepCoreTimelock internal policy;
    DeepCoreProtocolFeeController internal fees;

    address internal multisig = address(0x5AFE);
    address internal stranger = address(0xBAD);
    address internal guardian = address(0x69A2D);

    /// @dev An independent veto. `TimelockController` grants CANCELLER only to proposers,
    /// so with a sole proposer there was nobody who could stop a compromised one. It is a
    /// constructor argument now, and the constructor refuses to let it BE the proposer.
    address internal canceller = address(0xCA11);

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }

    function setUp() public {
        custody = new DeepCoreTimelock(DeepCoreTimelock.Tier.Custody, 48 hours, _one(multisig), _one(multisig), canceller);
        policy = new DeepCoreTimelock(DeepCoreTimelock.Tier.Policy, 6 hours, _one(multisig), _one(multisig), canceller);

        // The policy timelock owns fee policy; the guardian is a separate, one-way de-risking path.
        fees = new DeepCoreProtocolFeeController(address(policy), guardian);
    }

    /*//////////////////////////////////////////////////////////////
                    THE FLOOR — WHY THIS SUBCLASS EXISTS
    //////////////////////////////////////////////////////////////*/

    /// @notice OZ's TimelockController accepts minDelay = 0 without complaint. That is the exact
    /// misconfiguration this subclass exists to make impossible.
    function test_rejectsZeroDelay() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepCoreTimelock.DelayBelowTierFloor.selector, DeepCoreTimelock.Tier.Custody, 0, 48 hours
            )
        );
        new DeepCoreTimelock(DeepCoreTimelock.Tier.Custody, 0, _one(multisig), _one(multisig), canceller);
    }

    function test_rejectsDelayJustBelowCustodyFloor() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepCoreTimelock.DelayBelowTierFloor.selector, DeepCoreTimelock.Tier.Custody, 48 hours - 1, 48 hours
            )
        );
        new DeepCoreTimelock(DeepCoreTimelock.Tier.Custody, 48 hours - 1, _one(multisig), _one(multisig), canceller);
    }

    function test_rejectsDelayJustBelowPolicyFloor() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepCoreTimelock.DelayBelowTierFloor.selector, DeepCoreTimelock.Tier.Policy, 6 hours - 1, 6 hours
            )
        );
        new DeepCoreTimelock(DeepCoreTimelock.Tier.Policy, 6 hours - 1, _one(multisig), _one(multisig), canceller);
    }

    /// @notice A custody delay must never be accepted merely because it clears the policy floor.
    function test_policyFloorDoesNotSatisfyCustodyTier() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepCoreTimelock.DelayBelowTierFloor.selector, DeepCoreTimelock.Tier.Custody, 6 hours, 48 hours
            )
        );
        new DeepCoreTimelock(DeepCoreTimelock.Tier.Custody, 6 hours, _one(multisig), _one(multisig), canceller);
    }

    function testFuzz_anyAcceptedDelayMeetsItsFloor(uint32 delay, bool isCustody) public {
        DeepCoreTimelock.Tier tier = isCustody ? DeepCoreTimelock.Tier.Custody : DeepCoreTimelock.Tier.Policy;
        uint256 floor = isCustody ? 48 hours : 6 hours;

        if (delay < floor) {
            vm.expectRevert();
            new DeepCoreTimelock(tier, delay, _one(multisig), _one(multisig), canceller);
        } else {
            DeepCoreTimelock t = new DeepCoreTimelock(tier, delay, _one(multisig), _one(multisig), canceller);
            assertGe(t.getMinDelay(), t.minDelayFloor(), "accepted delay must meet its own floor");
        }
    }

    function test_floorsAreReportedPerTier() public view {
        assertEq(custody.minDelayFloor(), 48 hours);
        assertEq(policy.minDelayFloor(), 6 hours);
        assertEq(uint8(custody.tier()), uint8(DeepCoreTimelock.Tier.Custody));
        assertEq(uint8(policy.tier()), uint8(DeepCoreTimelock.Tier.Policy));
    }

    /*//////////////////////////////////////////////////////////////
                       A LIVE TIMELOCK CANNOT BE EMPTY
    //////////////////////////////////////////////////////////////*/

    function test_rejectsNoProposers() public {
        address[] memory none = new address[](0);
        vm.expectRevert(DeepCoreTimelock.NoProposers.selector);
        new DeepCoreTimelock(DeepCoreTimelock.Tier.Policy, 6 hours, none, _one(multisig), canceller);
    }

    function test_rejectsNoExecutors() public {
        address[] memory none = new address[](0);
        vm.expectRevert(DeepCoreTimelock.NoExecutors.selector);
        new DeepCoreTimelock(DeepCoreTimelock.Tier.Policy, 6 hours, _one(multisig), none, canceller);
    }

    /*//////////////////////////////////////////////////////////////
                       NO ADMIN BACKDOOR, EVER
    //////////////////////////////////////////////////////////////*/

    /// @notice OZ allows an optional `admin` that can grant and revoke roles directly, bypassing
    /// every delay. It is hardcoded to address(0) so it can never be a deployment decision.
    /// Only the timelock itself holds DEFAULT_ADMIN_ROLE.
    function test_noExternalAdminHoldsDefaultAdminRole() public view {
        bytes32 adminRole = custody.DEFAULT_ADMIN_ROLE();
        assertTrue(custody.hasRole(adminRole, address(custody)), "timelock self-administers");
        assertFalse(custody.hasRole(adminRole, multisig), "multisig must not be admin");
        assertFalse(custody.hasRole(adminRole, stranger));
        assertFalse(custody.hasRole(adminRole, address(0)));
    }

    function test_proposerCannotGrantItselfAdmin() public {
        bytes32 adminRole = custody.DEFAULT_ADMIN_ROLE();
        vm.prank(multisig);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, multisig, adminRole)
        );
        custody.grantRole(adminRole, multisig);
    }

    /*//////////////////////////////////////////////////////////////
              THE DELAY IS REAL — PROVEN THROUGH A REAL CALL
    //////////////////////////////////////////////////////////////*/

    /// @notice Queue a genuine fee change through the policy timelock and prove it cannot land
    /// early, does land after the delay, and actually took effect on the controller.
    function test_feeChangeIsDelayedThenExecutes() public {
        bytes memory data = abi.encodeCall(DeepCoreProtocolFeeController.setDefaultFee, (250, 250));
        bytes32 salt = bytes32(0);
        bytes32 predecessor = bytes32(0);

        vm.prank(multisig);
        policy.schedule(address(fees), 0, data, predecessor, salt, 6 hours);

        // one second early is still early
        vm.warp(block.timestamp + 6 hours - 1);
        vm.prank(multisig);
        vm.expectRevert();
        policy.execute(address(fees), 0, data, predecessor, salt);

        (, uint16 zeroForOneBefore,) = fees.defaultFee();
        assertEq(zeroForOneBefore, 1000, "fee must be untouched while queued");

        vm.warp(block.timestamp + 1);
        vm.prank(multisig);
        policy.execute(address(fees), 0, data, predecessor, salt);

        (, uint16 zeroForOneAfter,) = fees.defaultFee();
        assertEq(zeroForOneAfter, 250, "fee must change once the delay has elapsed");
    }

    function test_strangerCannotSchedule() public {
        bytes memory data = abi.encodeCall(DeepCoreProtocolFeeController.setDefaultFee, (250, 250));
        // Hoist the role read: an external call made after vm.prank consumes the prank, so
        // reading PROPOSER_ROLE() inside the expectRevert argument would send `schedule` from
        // the test contract instead of `stranger`.
        bytes32 proposerRole = policy.PROPOSER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, proposerRole
            )
        );
        policy.schedule(address(fees), 0, data, bytes32(0), bytes32(0), 6 hours);
    }

    /// @notice Scheduling below the timelock's own minimum must be refused, or the delay is
    /// advisory rather than enforced.
    function test_cannotScheduleBelowMinDelay() public {
        bytes memory data = abi.encodeCall(DeepCoreProtocolFeeController.setDefaultFee, (250, 250));
        vm.prank(multisig);
        vm.expectRevert();
        policy.schedule(address(fees), 0, data, bytes32(0), bytes32(0), 6 hours - 1);
    }

    /*//////////////////////////////////////////////////////////////
        THE GUARDIAN BYPASSES THE DELAY — DELIBERATELY, ONE WAY
    //////////////////////////////////////////////////////////////*/

    /// @notice The whole point of the split: de-risking must not wait on governance. The guardian
    /// zeroes fees instantly while the timelock still owns every escalating power.
    function test_guardianDisablesFeesWithoutWaitingForTheTimelock() public {
        vm.prank(guardian);
        fees.emergencyDisableFees();
        assertTrue(fees.feesDisabled(), "guardian must not need the timelock to stop fees");
    }

    /// @notice ...and re-enabling is an escalation, so it must go through the full delay.
    function test_reEnablingFeesRequiresTheTimelock() public {
        vm.prank(guardian);
        fees.emergencyDisableFees();

        // guardian has no route back
        vm.prank(guardian);
        vm.expectRevert();
        fees.setFeesDisabled(false);
        assertTrue(fees.feesDisabled());

        // the timelock does, after its delay
        bytes memory data = abi.encodeCall(DeepCoreProtocolFeeController.setFeesDisabled, (false));
        vm.prank(multisig);
        policy.schedule(address(fees), 0, data, bytes32(0), bytes32(0), 6 hours);
        vm.warp(block.timestamp + 6 hours);
        vm.prank(multisig);
        policy.execute(address(fees), 0, data, bytes32(0), bytes32(0));

        assertFalse(fees.feesDisabled(), "only the timelock reopens the tap");
    }

    /*//////////////////////////////////////////////////////////////
                              CANCELLATION
    //////////////////////////////////////////////////////////////*/

    /// @notice A queued operation must be cancellable during its window. Without this, a mistake
    /// spotted at hour one still lands at hour six.
    function test_queuedOperationCanBeCancelledInFlight() public {
        bytes memory data = abi.encodeCall(DeepCoreProtocolFeeController.setDefaultFee, (4000, 4000));
        bytes32 id = policy.hashOperation(address(fees), 0, data, bytes32(0), bytes32(0));

        vm.prank(multisig);
        policy.schedule(address(fees), 0, data, bytes32(0), bytes32(0), 6 hours);
        assertTrue(policy.isOperationPending(id));

        vm.prank(multisig);
        policy.cancel(id);

        vm.warp(block.timestamp + 6 hours);
        vm.prank(multisig);
        vm.expectRevert();
        policy.execute(address(fees), 0, data, bytes32(0), bytes32(0));

        (, uint16 zeroForOne,) = fees.defaultFee();
        assertEq(zeroForOne, 1000, "cancelled operation must never take effect");
    }

    /*//////////////////////////////////////////////////////////////
       updateDelay(0) - THE TIER FLOOR THAT WAS CHECKED ONCE AND NEVER AGAIN
    //////////////////////////////////////////////////////////////*/

    /// @dev THE HOLE. OZ's `updateDelay` is `external virtual`, gated only on
    /// `msg.sender == address(this)`, and re-validates nothing; the tier floor was checked in the
    /// constructor and nowhere else. So ONE queued operation targeting the timelock itself set
    /// `_minDelay = 0`, after which every later operation - `Vault.registerApp` included -
    /// executed in the block it was queued. The tier stopped existing, and with `CANCELLER_ROLE`
    /// held only by the compromised proposer there was nobody left to stop it.
    ///
    /// It is rejected at `_execute`, not in an override of `updateDelay`: Solidity cannot reach an
    /// `external` base function through `super` and OZ's `_minDelay` is private, so an override
    /// could refuse a bad delay but never apply a good one. `_execute` is the only place the
    /// timelock ever calls out, so nothing reaches the base implementation around it.
    ///
    /// FAILS AGAINST THE PRE-FIX CODE: the execution succeeds and `getMinDelay()` returns 0.
    function test_updateDelayToZeroIsRejectedAtExecution() public {
        bytes memory data = abi.encodeWithSignature("updateDelay(uint256)", uint256(0));

        vm.prank(multisig);
        custody.schedule(address(custody), 0, data, bytes32(0), bytes32(0), 48 hours);
        vm.warp(block.timestamp + 48 hours);

        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreTimelock.DelayBelowTierFloor.selector, DeepCoreTimelock.Tier.Custody, 0, 48 hours)
        );
        vm.prank(multisig);
        custody.execute(address(custody), 0, data, bytes32(0), bytes32(0));

        assertEq(custody.getMinDelay(), 48 hours, "the tier still exists");
    }

    /// @dev Anything under the floor, not only zero. 47h59m is the same attack with a less obvious
    /// number, and 47 hours of warning is not what the Custody tier promises.
    function test_updateDelayJustBelowTheFloorIsRejected() public {
        bytes memory data = abi.encodeWithSignature("updateDelay(uint256)", uint256(48 hours - 1));

        vm.prank(multisig);
        custody.schedule(address(custody), 0, data, bytes32(0), bytes32(0), 48 hours);
        vm.warp(block.timestamp + 48 hours);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeepCoreTimelock.DelayBelowTierFloor.selector, DeepCoreTimelock.Tier.Custody, 48 hours - 1, 48 hours
            )
        );
        vm.prank(multisig);
        custody.execute(address(custody), 0, data, bytes32(0), bytes32(0));
    }

    /// @dev RAISING the delay is untouched. The guard has to be a floor, not a freeze: governance
    /// that cannot lengthen its own delay has been handed a different problem.
    function test_updateDelayUpwardsStillWorks() public {
        bytes memory data = abi.encodeWithSignature("updateDelay(uint256)", uint256(72 hours));

        vm.prank(multisig);
        custody.schedule(address(custody), 0, data, bytes32(0), bytes32(0), 48 hours);
        vm.warp(block.timestamp + 48 hours);
        vm.prank(multisig);
        custody.execute(address(custody), 0, data, bytes32(0), bytes32(0));

        assertEq(custody.getMinDelay(), 72 hours);

        // And the raised delay is real: a 48h schedule is refused afterwards.
        bytes memory noop = abi.encodeCall(DeepCoreProtocolFeeController.setFeesDisabled, (true));
        vm.prank(multisig);
        vm.expectRevert();
        custody.schedule(address(fees), 0, noop, bytes32(0), bytes32(0), 48 hours);
    }

    /// @dev The second layer, and the reason the guard is not one-deep. `_schedule` reads
    /// `getMinDelay()` rather than the storage slot, so even a `_minDelay` driven below the floor
    /// by some route nobody has thought of leaves every future `schedule` still demanding it.
    function test_getMinDelayNeverReportsBelowTheTierFloor() public view {
        assertGe(custody.getMinDelay(), custody.minDelayFloor());
        assertGe(policy.getMinDelay(), policy.minDelayFloor());
    }

    /// @dev A batch is the same door. `executeBatch` loops through the same `_execute`, so an
    /// `updateDelay(0)` hidden among innocuous calls is rejected along with them.
    function test_updateDelayToZeroIsRejectedInsideABatch() public {
        address[] memory targets = new address[](2);
        uint256[] memory values = new uint256[](2);
        bytes[] memory payloads = new bytes[](2);

        // A legitimate raise first, so the batch is not obviously hostile, then the drop to zero.
        targets[0] = address(custody);
        payloads[0] = abi.encodeWithSignature("updateDelay(uint256)", uint256(72 hours));
        targets[1] = address(custody);
        payloads[1] = abi.encodeWithSignature("updateDelay(uint256)", uint256(0));

        vm.prank(multisig);
        custody.scheduleBatch(targets, values, payloads, bytes32(0), bytes32(0), 48 hours);
        vm.warp(block.timestamp + 48 hours);

        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreTimelock.DelayBelowTierFloor.selector, DeepCoreTimelock.Tier.Custody, 0, 48 hours)
        );
        vm.prank(multisig);
        custody.executeBatch(targets, values, payloads, bytes32(0), bytes32(0));

        assertEq(custody.getMinDelay(), 48 hours);
    }

    /*//////////////////////////////////////////////////////////////
       AN INDEPENDENT VETO - CANCELLER_ROLE AS A CONSTRUCTOR ARGUMENT
    //////////////////////////////////////////////////////////////*/

    /// @dev `TimelockController` grants `CANCELLER_ROLE` to proposers and nobody else. With the
    /// Safe as sole proposer, a 2-of-3 compromise that queued anything bought the public 48 hours
    /// of VISIBILITY with no party able to act on it. The role is an explicit argument now, and
    /// its holder is the right thing to keep on a lone hot key precisely because its only power is
    /// refusal: losing it costs nothing a queued `grantRole` cannot restore, and stealing it
    /// achieves griefing and nothing else.
    ///
    /// FAILS AGAINST THE PRE-FIX CODE: there was no such argument, and no such holder.
    function test_theCancellerCanVetoWhatTheProposerQueued() public {
        bytes memory data = abi.encodeCall(DeepCoreProtocolFeeController.setDefaultFee, (4000, 4000));
        bytes32 id = custody.hashOperation(address(fees), 0, data, bytes32(0), bytes32(0));

        vm.prank(multisig);
        custody.schedule(address(fees), 0, data, bytes32(0), bytes32(0), 48 hours);
        assertTrue(custody.isOperationPending(id));

        vm.prank(canceller);
        custody.cancel(id);

        assertFalse(custody.isOperation(id), "the veto landed");
    }

    /// @dev And the canceller can do nothing else. That is the entire safety argument for handing
    /// it to a key that is not behind a multisig.
    function test_theCancellerCanOnlyCancel() public {
        bytes memory data = abi.encodeCall(DeepCoreProtocolFeeController.setDefaultFee, (4000, 4000));

        vm.prank(canceller);
        vm.expectRevert();
        custody.schedule(address(fees), 0, data, bytes32(0), bytes32(0), 48 hours);

        assertFalse(custody.hasRole(custody.PROPOSER_ROLE(), canceller));
        assertFalse(custody.hasRole(custody.DEFAULT_ADMIN_ROLE(), canceller));
        assertTrue(custody.hasRole(custody.CANCELLER_ROLE(), canceller));
    }

    /// @dev A zero canceller reproduces the exact hole the argument exists to close, while making
    /// the deployment look like it had been closed. `schedule` uses `onlyRole`, NOT
    /// `onlyRoleOrOpenRole`, so a zero address here is a dead role rather than an open one.
    function test_rejectsAZeroCanceller() public {
        vm.expectRevert(DeepCoreTimelock.ZeroCanceller.selector);
        new DeepCoreTimelock(DeepCoreTimelock.Tier.Custody, 48 hours, _one(multisig), _one(multisig), address(0));
    }

    /// @dev A canceller that IS the sole proposer cannot veto a compromised proposer, which is the
    /// only scenario the role was added for.
    function test_rejectsACancellerThatIsAProposer() public {
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTimelock.CancellerMustNotBeAProposer.selector, multisig));
        new DeepCoreTimelock(DeepCoreTimelock.Tier.Custody, 48 hours, _one(multisig), _one(multisig), multisig);
    }

    /// @dev Length alone was checked, which `[address(0)]` passes. The result looks correctly
    /// configured, clears `NoProposers`, and can queue nothing for anybody - and because OZ grants
    /// `CANCELLER_ROLE` to each proposer, it hands that to nobody either.
    function test_rejectsAZeroProposer() public {
        vm.expectRevert(DeepCoreTimelock.ZeroProposer.selector);
        new DeepCoreTimelock(DeepCoreTimelock.Tier.Custody, 48 hours, _one(address(0)), _one(multisig), canceller);
    }

    /*//////////////////////////////////////////////////////////////
          THE ROLES THAT MAKE IT A TIMELOCK CANNOT BE DROPPED (audit C)
    //////////////////////////////////////////////////////////////*/

    /// The sole proposer renouncing DIRECTLY (no queue, no canceller) used to end governance for good:
    /// the timelock is its own admin, so nobody could ever grant a proposer again.
    function test_FIX_proposerExecutorAndAdminRolesAreNotRenounceable() public {
        bytes32 proposer = custody.PROPOSER_ROLE();
        bytes32 executor = custody.EXECUTOR_ROLE();
        vm.startPrank(multisig);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTimelock.RoleIsNotRenounceable.selector, proposer));
        custody.renounceRole(proposer, multisig);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTimelock.RoleIsNotRenounceable.selector, executor));
        custody.renounceRole(executor, multisig);
        vm.stopPrank();
        assertTrue(custody.hasRole(proposer, multisig), "still a proposer");
        assertEq(custody.roleHolderCount(proposer), 1);
        assertEq(custody.roleHolderCount(executor), 1);
    }

    /// The canceller's only power is refusal; it may still step down.
    function test_FIX_theCancellerMayStillRenounce() public {
        bytes32 role = custody.CANCELLER_ROLE();
        vm.prank(canceller);
        custody.renounceRole(role, canceller);
        assertFalse(custody.hasRole(role, canceller));
    }

    /// A queued revoke of the LAST proposer is refused at execution; rotation is grant-then-revoke.
    function test_FIX_theLastProposerCannotBeRevoked_butRotationWorks() public {
        bytes32 proposer = custody.PROPOSER_ROLE();
        address successor = address(0x5AFE2);
        bytes memory revokeOld = abi.encodeCall(custody.revokeRole, (proposer, multisig));
        bytes memory grantNew = abi.encodeCall(custody.grantRole, (proposer, successor));

        // Absolute times: under via-IR `block.timestamp` is cached inside one test function, so a second
        // `vm.warp(block.timestamp + ...)` would not advance.
        uint256 t0 = block.timestamp;

        // revoke alone: survives the delay, refused when executed
        vm.prank(multisig);
        custody.schedule(address(custody), 0, revokeOld, bytes32(0), bytes32("revoke-alone"), 48 hours);
        vm.warp(t0 + 48 hours);
        vm.prank(multisig);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreTimelock.LastHolderCannotBeRemoved.selector, proposer));
        custody.execute(address(custody), 0, revokeOld, bytes32(0), bytes32("revoke-alone"));
        assertTrue(custody.hasRole(proposer, multisig));

        // grant the successor, then revoke the predecessor
        vm.prank(multisig);
        custody.schedule(address(custody), 0, grantNew, bytes32(0), bytes32("grant"), 48 hours);
        vm.warp(t0 + 96 hours);
        vm.prank(multisig);
        custody.execute(address(custody), 0, grantNew, bytes32(0), bytes32("grant"));
        assertEq(custody.roleHolderCount(proposer), 2);
        vm.prank(multisig);
        custody.execute(address(custody), 0, revokeOld, bytes32(0), bytes32("revoke-alone"));
        assertFalse(custody.hasRole(proposer, multisig));
        assertTrue(custody.hasRole(proposer, successor));
        assertEq(custody.roleHolderCount(proposer), 1);
    }
}
