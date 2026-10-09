// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {KitV2Fixture, FakeSafe} from "../kitv2/KitV2Fixture.sol";
import {CreateXTest} from "deepcore-hooks/test/helpers/CreateXLike.sol";
import {CreateXCreate3, DeepCoreDeploy} from "../../script/CreateX.sol";
import {DeepCorePadFactory} from "../../src/pad/DeepCorePadFactory.sol";
import {LaunchpadKitV2} from "../../src/LaunchpadKitV2.sol";
import {DeployDeepCorePadFactoryScript} from "../../script/DeployDeepCorePadFactory.s.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";

/// @notice The pad-factory deploy script end to end as a contract: CREATE3 through CreateX at a salt
/// permissioned to the deployer, the Safe from birth, every fee argument read back, the multi-chain
/// identity asserted, and each pre-flight guard tripped. Driven through `runWith`, never the environment.
contract DeployDeepCorePadFactoryTest is KitV2Fixture {
    uint256 internal constant PK = 0xBEEF_0004;

    DeployDeepCorePadFactoryScript internal script;

    function setUp() public {
        _deployAll();
        CreateXTest.etch();
        script = new DeployDeepCorePadFactoryScript();
    }

    function _wiring() internal view returns (DeployDeepCorePadFactoryScript.Wiring memory w) {
        w = DeployDeepCorePadFactoryScript.Wiring({
            pk: PK,
            kit: address(kit),
            safe: safe,
            padFeeWei: 0.003 ether,
            padFeeCapWei: 0.03 ether,
            padFeeNoticeSeconds: 7 days,
            target: CreateXTest.target(vm.addr(PK), bytes11("dcore.pads"))
        });
    }

    function test_SCRIPT_deploysOwnedByTheSafeAndReadsEveryNumberBack() public {
        DeployDeepCorePadFactoryScript.Wiring memory w = _wiring();
        address predicted = script.predictFactory(w);
        DeepCorePadFactory f = script.runWith(w);
        assertEq(address(f), predicted, "CREATE3 prediction");
        assertEq(address(f.IMPLEMENTATION()), vm.computeCreateAddress(address(f), 1));
        assertEq(f.owner(), safe);
        assertEq(f.protocolFeeRecipient(), safe);
        assertEq(f.padFeeWei(), 0.003 ether);
        assertEq(f.maxPadFeeWei(), 0.03 ether);
        assertEq(f.padFeeNoticeSeconds(), 7 days);
        assertEq(address(f.KIT()), address(kit));
        assertEq(f.IMPLEMENTATION().owner(), address(0xdead));
        assertEq(f.padCount(), 0);
    }

    /// Two "chains": the same deployer and salt, different kit, Safe, fee, cap and notice. One address.
    /// @dev Both legs run on non-production chain ids (HyperEVM testnet 998, Sepolia): DeepCore has no
    /// governance Safe of record yet, so every production chain refuses before deploying (see
    /// `test_SCRIPT_productionrefusesAnOwnerThatIsNotTheSafeOfRecord`). The address property under test does
    /// not depend on the chain id - CreateX's CREATE3 salt here mixes no chain id in.
    function test_SCRIPT_sameDeployerAndSaltGiveTheSameFactoryOnEveryChain() public {
        uint256 clean = vm.snapshotState();
        vm.chainId(998);
        DeployDeepCorePadFactoryScript.Wiring memory wa = _wiring();
        DeepCorePadFactory a = script.runWith(wa);
        address padA = a.predictPad(address(0xC0FFEE), keccak256("mochi"));
        vm.revertToState(clean);

        vm.chainId(11155111);
        address safeB = address(new FakeSafe());
        LaunchpadKitV2.Deployment memory d = _deploymentFor(safeB);
        LaunchpadKitV2 kitB = new LaunchpadKitV2(d);
        DeployDeepCorePadFactoryScript.Wiring memory w = _wiring();
        w.kit = address(kitB);
        w.safe = safeB;
        w.padFeeWei = 7 ether;
        w.padFeeCapWei = 70 ether;
        w.padFeeNoticeSeconds = 2 days;
        w.target.expected = address(a); // the first chain's address, as the salts file records it
        DeepCorePadFactory b = script.runWith(w);

        assertEq(address(b), address(a), "same factory");
        assertEq(address(b.IMPLEMENTATION()), address(a.IMPLEMENTATION()), "same implementation");
        assertEq(b.predictPad(address(0xC0FFEE), keccak256("mochi")), padA, "same pad address");
        assertEq(address(b.KIT()), address(kitB));
        assertEq(b.padFeeWei(), 7 ether);
    }

    function test_SCRIPT_preflightRefusals() public {
        DeployDeepCorePadFactoryScript.Wiring memory w = _wiring();

        w.safe = vm.addr(PK); // the deployer: an EOA, so it fails the code check first
        vm.expectRevert(bytes("PAD_FEE_RECIPIENT has no code - a Safe is a contract"));
        script.preflight(w);

        w = _wiring();
        w.safe = address(this); // has code, but is not what the kit pays
        vm.expectRevert(bytes("the kit pays a different recipient"));
        script.preflight(w);

        w = _wiring();
        w.padFeeCapWei = 0;
        vm.expectRevert(bytes("PAD_FEE_CAP_WEI is zero - the owner could never charge"));
        script.preflight(w);

        w = _wiring();
        w.padFeeWei = w.padFeeCapWei + 1;
        vm.expectRevert(bytes("PAD_FEE_WEI above the cap"));
        script.preflight(w);

        w = _wiring();
        w.padFeeNoticeSeconds = 12 hours;
        vm.expectRevert(bytes("PAD_FEE_NOTICE_SECONDS outside 1..30 days"));
        script.preflight(w);

        w = _wiring();
        w.kit = address(clLocker); // has code, is not a kit
        vm.expectRevert();
        script.preflight(w);
    }

    function test_SCRIPT_create3Refusals() public {
        DeployDeepCorePadFactoryScript.Wiring memory w = _wiring();

        // A CreateX whose code is not the expected code.
        w.target.createXCodeHash = keccak256("not createx");
        vm.expectRevert(bytes("CreateX runtime code is not the canonical CreateX (DEEPCORE_PAD_FACTORY_QF)"));
        script.preflight(w);

        // No CreateX at all on this chain.
        w = _wiring();
        w.target.createX = address(0xC0DE);
        vm.expectRevert(bytes("CreateX has no code on this chain (DEEPCORE_PAD_FACTORY_QF)"));
        script.preflight(w);

        // A salt that is not permissioned to the deployer (anyone could front-run it on a new chain).
        w = _wiring();
        w.target.salt = CreateXCreate3.permissionedCrossChainSalt(address(0xD00D), bytes11("dcore.pads"));
        vm.expectRevert(bytes("DEEPCORE_SALT_DEEPCORE_PAD_FACTORY_QF must be <deployer> ++ 0x00 ++ 11 bytes (permissioned, no chain id)"));
        script.preflight(w);

        // A salt with redeploy protection (the chain id mixed in: a different address per chain).
        w = _wiring();
        w.target.salt = bytes32(abi.encodePacked(vm.addr(PK), bytes1(0x01), bytes11("dcore.pads")));
        vm.expectRevert(bytes("DEEPCORE_SALT_DEEPCORE_PAD_FACTORY_QF must be <deployer> ++ 0x00 ++ 11 bytes (permissioned, no chain id)"));
        script.preflight(w);

        // The address the first chain produced must be reproduced exactly.
        w = _wiring();
        w.target.expected = address(0xFAC7);
        vm.expectRevert(bytes("predicted address differs from DEEPCORE_ADDRESS_DEEPCORE_PAD_FACTORY_QF (other deployer or salt?)"));
        script.preflight(w);

        // A salt mined for somebody else's key cannot be used by this deployer.
        w = _wiring();
        w.target.deployer = address(0xD00D);
        vm.expectRevert(bytes("the salt target is not this deployer"));
        script.preflight(w);

        // Deployed once: the same salt is refused, never "reuse whatever is there".
        w = _wiring();
        script.runWith(w);
        vm.expectRevert(bytes("the predicted address already has code on this chain (DEEPCORE_PAD_FACTORY_QF)"));
        script.preflight(w);
    }

    /// The governance Safe of record is set (`DeepCoreGovernance.SAFE`, 2026-10-07): every production
    /// chain, HyperEVM 999 included, refuses the test's stub Safe as not being it. The 7-day notice is checked after.
    function test_SCRIPT_productionrefusesAnOwnerThatIsNotTheSafeOfRecord() public {
        assertTrue(DeepCoreGovernance.SAFE != address(0), "the governance Safe of record is set (owner, 2026-10-07)");
        DeployDeepCorePadFactoryScript.Wiring memory w = _wiring();
        vm.chainId(999);
        vm.expectRevert(bytes("PAD_FEE_RECIPIENT is not the governance Safe of record"));
        script.preflight(w);

        w.padFeeNoticeSeconds = 2 days;
        vm.expectRevert(bytes("PAD_FEE_NOTICE_SECONDS is not 7 days on mainnet"));
        script.preflight(w);
    }
}
