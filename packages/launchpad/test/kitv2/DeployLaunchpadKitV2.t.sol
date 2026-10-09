// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";

import {LaunchGuardHook, ILaunchTokenOrigin} from "deepcore-hooks/src/launch/LaunchGuardHook.sol";
import {BinLaunchGuardHook} from "deepcore-hooks/src/launch/BinLaunchGuardHook.sol";
import {DeepCoreProtocolFeeControllerV3} from "deepcore-fees/src/DeepCoreProtocolFeeControllerV3.sol";

import {LaunchpadKitV2} from "../../src/LaunchpadKitV2.sol";
import {DeepCoreLPLocker} from "../../src/DeepCoreLPLocker.sol";
import {LaunchParamsV2, LaunchResultV2, LegParams} from "../../src/interfaces/ILaunchpadKitV2.sol";
import {DeployLaunchpadKitV2Script} from "../../script/DeployLaunchpadKitV2.s.sol";
import {DeployBinLaunchGuardHookScript} from "../../script/DeployBinLaunchGuardHook.s.sol";

import {KitV2Fixture, FakeSafe} from "./KitV2Fixture.sol";
import {CreateXTest} from "deepcore-hooks/test/helpers/CreateXLike.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";

/// @notice Both new deploy scripts run end to end as contracts, with representative pre-flight guards tripped.
/// @dev Driven through `runWith`, never the environment (see test/DeployScripts.t.sol for why).
contract DeployLaunchpadKitV2Test is KitV2Fixture {
    uint256 internal constant PK = 0xBEEF_0003;

    DeployLaunchpadKitV2Script internal script;

    function setUp() public {
        _deployAll();
        script = new DeployLaunchpadKitV2Script();
        CreateXTest.etch();
    }

    function _wiring() internal view returns (DeployLaunchpadKitV2Script.Wiring memory w) {
        w = DeployLaunchpadKitV2Script.Wiring({
            pk: PK,
            clPoolManager: address(clPM),
            binPoolManager: address(binPM),
            clPositionManager: address(clPosm),
            binPositionManager: address(binPosm),
            clHook: address(clHook),
            binHook: address(binHook),
            clLocker: address(clLocker),
            binLocker: address(binLocker),
            tokenFactory: address(factory),
            launchRegistry: address(launchRegistry),
            safe: safe,
            launchpadSteward: LAUNCHPAD_STEWARD,
            initialLaunchFeeWei: 0.0005 ether,
            maxLaunchFeeWei: 0.01 ether,
            maxIntegratorLaunchFeeWei: 0.005 ether,
            feePolicyV2: address(v2),
            /* Zero on purpose: forge links the kit under test to a `LaunchLegs` IT deployed, at an address
               no test can name, so the linked-library guard is exercised by
               `test_SCRIPT_requireLinkedToRefusesUnlinkedAndForeignCode` instead. The production path
               (`run()`) reads DEEPCORE_ADDRESS_LAUNCH_LEGS_QF and `vm.envAddress` reverts when it is unset. */
            launchLegs: address(0),
            target: CreateXTest.target(vm.addr(PK), "kit.v2")
        });
    }

    function test_SCRIPT_deploysReadsBackAndSatisfiesTheV3DeployChecks() public {
        LaunchpadKitV2 k = script.runWith(_wiring());
        assertEq(k.owner(), safe);
        assertEq(k.maxLegs(), 4, "gas-sized: matches LaunchpadKitV2Gas DEPLOY_MAX_LEGS");
        assertEq(k.maxBinsPerLeg(), 20, "gas-sized: matches LaunchpadKitV2Gas DEPLOY_MAX_BINS_PER_LEG");
        assertEq(k.launchFeeNoticeSeconds(), 7 days);

        // Step 6 of the order: a V3 bound to this kit constructs (its constructor probes isLockedLaunch(0)).
        DeepCoreProtocolFeeControllerV3 bound = new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(v2)), address(k));
        assertEq(bound.launchOracle(), address(k));
    }

    /// @dev Owner decision #2: before V3 names this kit, a launch still works and is born at V2's fee - the
    /// Safe zeroes it by hand. The kit's zero-fee assertion must not block that window.
    function test_SCRIPT_kitIsUsableBeforeItsV3IsInstalled() public {
        LaunchpadKitV2 k = script.runWith(_wiring());
        bytes32 salt = keccak256("pre-v3");
        LaunchParamsV2 memory p = _oneCL(salt, address(quote));
        p.legs[0] = _clLeg(k.predictLaunchToken(LAUNCHER, salt), address(quote), 10_000);
        vm.deal(LAUNCHER, 1 ether);
        vm.prank(LAUNCHER);
        LaunchResultV2 memory r = k.createLaunch{value: 0.0005 ether}(p);
        assertTrue(k.isLockedLaunch(r.poolIds[0]));
        assertEq(_clProtocolFee(r.poolIds[0]), PACKED_999, "installed V3 is bound to a different kit");
        assertTrue(clLocker.isLocked(r.lockIds[0]));
    }

    function test_SCRIPT_refusesAnEoaSafe() public {
        DeployLaunchpadKitV2Script.Wiring memory w = _wiring();
        w.safe = address(0x5AFE);
        vm.expectRevert(bytes("an input address has no code"));
        script.runWith(w);
    }

    function test_SCRIPT_refusesFeeAboveCap() public {
        DeployLaunchpadKitV2Script.Wiring memory w = _wiring();
        w.initialLaunchFeeWei = w.maxLaunchFeeWei + 1;
        vm.expectRevert(bytes("INITIAL_LAUNCH_FEE_WEI above the cap"));
        script.runWith(w);
    }

    function test_SCRIPT_refusesAPrePortBinGuard() public {
        DeployLaunchpadKitV2Script.Wiring memory w = _wiring();
        w.binHook = address(new BinLaunchGuardHook(IBinPoolManager(address(binPM)), ILaunchTokenOrigin(address(0)), safe, 0));
        vm.expectRevert(bytes("Bin guard: reservation factory - the pre-port hook?"));
        script.runWith(w);
    }

    /// @dev One kit, one rule for where a launch's fee goes: both guards must leave the pool the same share.
    function test_SCRIPT_refusesGuardsWithDifferentLpShares() public {
        DeployLaunchpadKitV2Script.Wiring memory w = _wiring();
        w.binHook =
            address(new BinLaunchGuardHook(IBinPoolManager(address(binPM)), ILaunchTokenOrigin(address(factory)), safe, 1));
        vm.expectRevert(bytes("the two guards carry different LP_SHARE_BPS"));
        script.runWith(w);
    }

    /// @dev The guard's own constructor is the bound: a share above the cap never deploys.
    function test_SCRIPT_binGuardRefusesAShareAboveTheCap() public {
        DeployBinLaunchGuardHookScript binScript = new DeployBinLaunchGuardHookScript();
        vm.expectRevert();
        binScript.runWith(
            PK, address(binPM), address(factory), address(deepcoreRegistry), LAUNCHPAD_STEWARD, safe, 5_001,
            CreateXTest.target(vm.addr(PK), "guard.bin4")
        );
    }

    function test_SCRIPT_binGuardDeploysWithTheShareItWasGiven() public {
        DeployBinLaunchGuardHookScript binScript = new DeployBinLaunchGuardHookScript();
        BinLaunchGuardHook h = binScript.runWith(
            PK, address(binPM), address(factory), address(deepcoreRegistry), LAUNCHPAD_STEWARD, safe, 2_000,
            CreateXTest.target(vm.addr(PK), "guard.bin5")
        );
        assertEq(h.LP_SHARE_BPS(), 2_000);
        assertEq(h.getHooksRegistrationBitmap(), 0x0CC5, "the share does not change the bitmap");
    }

    function test_SCRIPT_refusesALockerPayingSomeoneElse() public {
        DeployLaunchpadKitV2Script.Wiring memory w = _wiring();
        w.clLocker = address(new DeepCoreLPLocker(clPosm, address(new FakeSafe()), 2_000, 5_000, 2_000));
        vm.expectRevert(bytes("a locker pays someone other than the Safe"));
        script.runWith(w);
    }

    function test_SCRIPT_refusesAKitNotOwnedByTheV2Safe() public {
        DeployLaunchpadKitV2Script.Wiring memory w = _wiring();
        w.feePolicyV2 = address(clHook); // not V2
        vm.expectRevert();
        script.runWith(w);
    }

    function test_SCRIPT_binGuardDeploysListedWithTheReservation() public {
        DeployBinLaunchGuardHookScript binScript = new DeployBinLaunchGuardHookScript();
        BinLaunchGuardHook h = binScript.runWith(
            PK, address(binPM), address(factory), address(deepcoreRegistry), LAUNCHPAD_STEWARD, safe, 0,
            CreateXTest.target(vm.addr(PK), "guard.bin")
        );
        assertEq(h.protocolRecipient(), safe);
        assertEq(h.getHooksRegistrationBitmap(), 0x0CC5);
        assertEq(address(h.LAUNCH_TOKEN_FACTORY()), address(factory));
        assertTrue(deepcoreRegistry.isRegistered(address(h)));

        vm.expectRevert(bytes("LAUNCH_TOKEN_FACTORY has no code"));
        binScript.runWith(
            PK, address(binPM), address(0), address(deepcoreRegistry), LAUNCHPAD_STEWARD, safe, 0,
            CreateXTest.target(vm.addr(PK), "guard.bin2")
        );
        vm.expectRevert(bytes("TAX_PROTOCOL_RECIPIENT has no code - a Safe, not an EOA"));
        binScript.runWith(
            PK, address(binPM), address(factory), address(deepcoreRegistry), LAUNCHPAD_STEWARD, address(0xCAFE), 0,
            CreateXTest.target(vm.addr(PK), "guard.bin3")
        );
    }

    /// @notice The kit's address is the mined one, and a second run at the same salt is refused rather
    /// than quietly reusing whatever is already there.
    function test_SCRIPT_kitLandsOnTheMinedAddressAndTheSaltIsOneShot() public {
        DeployLaunchpadKitV2Script.Wiring memory w = _wiring();
        LaunchpadKitV2 k = script.runWith(w);
        assertEq(address(k), _predict(w), "kit is not at the CREATE3 address the salt predicts");
        vm.expectRevert(bytes("the predicted address already has code on this chain (LAUNCHPAD_KIT_V2_QF)"));
        script.preflight(w);
    }

    function _predict(DeployLaunchpadKitV2Script.Wiring memory w) internal pure returns (address) {
        return DeepCoreDeploy.predict(w.target);
    }

    /// @notice The linked-library guard: an unlinked blob and a blob linked elsewhere are both refused,
    /// and a blob carrying the address passes. Driven with synthetic code because the real artifact's
    /// link target is chosen by forge.
    function test_SCRIPT_requireLinkedToRefusesUnlinkedAndForeignCode() public {
        address legs = address(new FakeSafe()); // any address with code
        bytes memory unlinked = abi.encodePacked(hex"60806040", "__$3a7f0d2c9b1e4a6f8d5c2b0e7a9f4d1c3e$__", hex"5b50");
        vm.expectRevert(bytes("LaunchpadKitV2 is UNLINKED: re-run with --libraries src/libraries/LaunchLegs.sol:LaunchLegs:<LaunchLegs>"));
        script.requireLinkedTo(legs, unlinked);

        bytes memory foreign = abi.encodePacked(hex"6080604073", bytes20(address(0xBEEF)), hex"5b50");
        vm.expectRevert(bytes("LaunchpadKitV2 is linked to a different LaunchLegs than DEEPCORE_ADDRESS_LAUNCH_LEGS_QF"));
        script.requireLinkedTo(legs, foreign);

        bytes memory linked = abi.encodePacked(hex"6080604073", bytes20(legs), hex"5b50");
        script.requireLinkedTo(legs, linked); // no revert

        vm.expectRevert(bytes("DEEPCORE_ADDRESS_LAUNCH_LEGS_QF has no code - deploy LaunchLegs first"));
        script.requireLinkedTo(address(0xD00D), linked);
    }
}
