// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {DeepCoreProtocolFeeController} from "../src/DeepCoreProtocolFeeController.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {ProtocolFeeLibrary} from "infinity-core/src/libraries/ProtocolFeeLibrary.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";

contract DeepCoreProtocolFeeControllerTest is Test {
    using PoolIdLibrary for PoolKey;
    using ProtocolFeeLibrary for uint24;

    DeepCoreProtocolFeeController internal controller;
    address internal governance = address(0x6011);
    address internal guardian = address(0x69A2D);

    /// 0.1% in both directions, packed as core expects
    uint24 internal constant EXPECTED_DEFAULT = uint24(1000) | (uint24(1000) << 12);

    function setUp() public {
        controller = new DeepCoreProtocolFeeController(governance, guardian);
    }

    function _key(uint24 fee) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(0xAAAA)),
            fee: fee,
            parameters: bytes32(0)
        });
    }

    /*//////////////////////////////////////////////////////////////
                        THE 0.1% LAUNCH DEFAULT
    //////////////////////////////////////////////////////////////*/

    function test_default_isOnePointOnePercent() public view {
        uint24 fee = controller.protocolFeeForPool(_key(3000));
        assertEq(fee, EXPECTED_DEFAULT, "default must be 0.1% both directions");
        assertEq(fee.getZeroForOneFee(), 1000, "zeroForOne must be 1000 pips");
        assertEq(fee.getOneForZeroFee(), 1000, "oneForZero must be 1000 pips");
    }

    /// @notice The returned value must pass core's own validator, or pool creation reverts.
    function test_default_passesCoreValidation() public view {
        assertTrue(controller.protocolFeeForPool(_key(3000)).validate(), "core must accept our fee");
    }

    /// @notice Documents the real cost to swappers. The protocol fee is taken from the input FIRST
    /// and the LP fee from the remainder, so it is additive rather than carved out of LP earnings.
    function test_totalSwapCost_isAdditive() public view {
        uint16 protocolFee = controller.protocolFeeForPool(_key(3000)).getZeroForOneFee();

        // 0.01% stable pool -> ~0.11% total, about 11x the pool's own fee
        assertEq(ProtocolFeeLibrary.calculateSwapFee(protocolFee, 100), 1100);
        // 0.05% pool -> ~0.15% total, roughly 3x
        assertEq(ProtocolFeeLibrary.calculateSwapFee(protocolFee, 500), 1500);
        // 0.30% pool -> ~0.40% total, +33%
        assertEq(ProtocolFeeLibrary.calculateSwapFee(protocolFee, 3000), 3997);
        // 1.00% pool -> ~1.10% total, +10%
        assertEq(ProtocolFeeLibrary.calculateSwapFee(protocolFee, 10000), 10990);
    }

    /*//////////////////////////////////////////////////////////////
              MUST NEVER REVERT - CALLED DURING POOL INIT
    //////////////////////////////////////////////////////////////*/

    /// @notice Core staticcalls this while initializing a pool. A revert here bricks pool creation
    /// protocol-wide, so it must tolerate ANY key, including malformed or adversarial ones.
    function testFuzz_neverReverts(
        address c0,
        address c1,
        address hooks,
        address pm,
        uint24 fee,
        bytes32 parameters
    ) public view {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            hooks: IHooks(hooks),
            poolManager: IPoolManager(pm),
            fee: fee,
            parameters: parameters
        });

        uint24 result = controller.protocolFeeForPool(key);
        assertTrue(result.validate(), "every returned fee must pass core validation");
    }

    /*//////////////////////////////////////////////////////////////
                              PRECEDENCE
    //////////////////////////////////////////////////////////////*/

    function test_precedence_poolOverridesTierAndDefault() public {
        PoolKey memory key = _key(3000);

        vm.prank(governance);
        controller.setTierFee(3000, true, 500, 500);
        assertEq(controller.protocolFeeForPool(key).getZeroForOneFee(), 500, "tier should apply");

        vm.prank(governance);
        controller.setPoolFee(key.toId(), true, 250, 250);
        assertEq(controller.protocolFeeForPool(key).getZeroForOneFee(), 250, "pool must win over tier");
    }

    /// @notice The intended fix for tight pools: a lower protocol fee on low-fee tiers.
    function test_tierFee_keepsStablePoolsCompetitive() public {
        vm.prank(governance);
        controller.setTierFee(100, true, 20, 20); // 0.002% on the 0.01% stable tier

        uint16 stableFee = controller.protocolFeeForPool(_key(100)).getZeroForOneFee();
        assertEq(ProtocolFeeLibrary.calculateSwapFee(stableFee, 100), 120, "stable pool stays tight");

        // an untouched tier still pays the 0.1% default
        assertEq(controller.protocolFeeForPool(_key(3000)).getZeroForOneFee(), 1000);
    }

    function test_dynamicFeePools_useDynamicOverride() public {
        PoolKey memory key = _key(LPFeeLibrary.DYNAMIC_FEE_FLAG);
        assertEq(controller.protocolFeeForPool(key).getZeroForOneFee(), 1000, "default applies first");

        vm.prank(governance);
        controller.setDynamicFee(true, 300, 300);
        assertEq(controller.protocolFeeForPool(key).getZeroForOneFee(), 300, "dynamic override applies");
    }

    function test_asymmetricFees_packIndependently() public {
        vm.prank(governance);
        controller.setDefaultFee(1000, 250);

        uint24 fee = controller.protocolFeeForPool(_key(3000));
        assertEq(fee.getZeroForOneFee(), 1000);
        assertEq(fee.getOneForZeroFee(), 250);
        assertTrue(fee.validate());
    }

    /*//////////////////////////////////////////////////////////////
                            EMERGENCY SWITCH
    //////////////////////////////////////////////////////////////*/

    function test_killSwitch_zeroesEveryPool() public {
        vm.startPrank(governance);
        controller.setPoolFee(_key(3000).toId(), true, 4000, 4000);
        controller.setFeesDisabled(true);
        vm.stopPrank();

        assertEq(controller.protocolFeeForPool(_key(3000)), 0, "kill switch must override everything");
        assertEq(controller.protocolFeeForPool(_key(100)), 0);
    }

    function test_killSwitch_isReversible() public {
        vm.startPrank(governance);
        controller.setFeesDisabled(true);
        controller.setFeesDisabled(false);
        vm.stopPrank();
        assertEq(controller.protocolFeeForPool(_key(3000)), EXPECTED_DEFAULT);
    }

    /*//////////////////////////////////////////////////////////////
                          BOUNDS AND ACCESS
    //////////////////////////////////////////////////////////////*/

    function test_cannotExceedCoreMaximum() public {
        vm.prank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreProtocolFeeController.FeeExceedsMaximum.selector, uint16(4001), uint16(4000))
        );
        controller.setDefaultFee(4001, 1000);
    }

    function testFuzz_anySetterValueIsEitherRejectedOrCoreValid(uint16 z, uint16 o) public {
        vm.prank(governance);
        if (z > 4000 || o > 4000) {
            vm.expectRevert();
            controller.setDefaultFee(z, o);
        } else {
            controller.setDefaultFee(z, o);
            assertTrue(controller.protocolFeeForPool(_key(3000)).validate(), "stored value must stay core-valid");
        }
    }

    function test_onlyOwnerCanSetFees() public {
        address attacker = address(0xBAD);

        vm.startPrank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        controller.setDefaultFee(0, 0);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        controller.setFeesDisabled(true);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        controller.setTierFee(3000, true, 0, 0);
        vm.stopPrank();
    }

    /// @notice Ownership must move in two steps, so it cannot be stranded on an address that
    /// never accepts it. This contract governs protocol revenue.
    function test_ownershipTransferIsTwoStep() public {
        address multisig = address(0x5AFE);

        vm.prank(governance);
        controller.transferOwnership(multisig);
        assertEq(controller.owner(), governance, "owner must not change until accepted");

        vm.prank(multisig);
        controller.acceptOwnership();
        assertEq(controller.owner(), multisig);
    }

    /*//////////////////////////////////////////////////////////////
                        GUARDIAN - ONE-WAY ONLY
    //////////////////////////////////////////////////////////////*/

    function test_guardian_canDisableFeesImmediately() public {
        vm.prank(guardian);
        controller.emergencyDisableFees();
        assertTrue(controller.feesDisabled());
        assertEq(controller.protocolFeeForPool(_key(3000)), 0);
    }

    function test_owner_canAlsoUseEmergencyPath() public {
        vm.prank(governance);
        controller.emergencyDisableFees();
        assertTrue(controller.feesDisabled());
    }

    /// @notice The guardian must have no route back. Re-enabling fees is an escalation and
    /// belongs behind the timelock; a compromised guardian may only cost revenue.
    function test_guardian_cannotReEnableFees() public {
        vm.prank(guardian);
        controller.emergencyDisableFees();

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        controller.setFeesDisabled(false);

        assertTrue(controller.feesDisabled(), "guardian must not be able to switch fees back on");
    }

    function test_guardian_cannotChangeAnyFee() public {
        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        controller.setDefaultFee(4000, 4000);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        controller.setTierFee(3000, true, 4000, 4000);
        vm.stopPrank();
    }

    function test_guardian_cannotAppointANewGuardian() public {
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        controller.setGuardian(address(0xBAD));
    }

    function test_strangerCannotUseEmergencyPath() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(DeepCoreProtocolFeeController.NotGuardianOrOwner.selector);
        controller.emergencyDisableFees();
    }

    function test_ownerCanRotateGuardian() public {
        address next = address(0xC0FFEE);
        vm.prank(governance);
        controller.setGuardian(next);
        assertEq(controller.guardian(), next);

        vm.prank(guardian);
        vm.expectRevert(DeepCoreProtocolFeeController.NotGuardianOrOwner.selector);
        controller.emergencyDisableFees();
    }

    /// @notice Only the owner reopens the tap, and on a live chain that owner is the timelock.
    function test_ownerCanReEnableAfterEmergency() public {
        vm.prank(guardian);
        controller.emergencyDisableFees();
        vm.prank(governance);
        controller.setFeesDisabled(false);
        assertEq(controller.protocolFeeForPool(_key(3000)), EXPECTED_DEFAULT);
    }
}
