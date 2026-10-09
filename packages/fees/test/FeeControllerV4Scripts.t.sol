// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";
import {CreateXTest} from "deepcore-hooks/test/helpers/CreateXLike.sol";

import {DeepCoreProtocolFeeControllerV2} from "../src/DeepCoreProtocolFeeControllerV2.sol";
import {DeepCoreProtocolFeeControllerV3} from "../src/DeepCoreProtocolFeeControllerV3.sol";
import {DeepCoreProtocolFeeControllerV4} from "../src/DeepCoreProtocolFeeControllerV4.sol";
import {DeployFeeControllerV4Script} from "../script/DeployFeeControllerV4.s.sol";
import {BuildInstallFeeControllerV4Script, InstallV4Calldata} from "../script/BuildInstallFeeControllerV4.s.sol";
import {MockLaunchOracle, NotAnOracle} from "./utils/V3Mocks.sol";

/// @dev Stands in for the Safe: a contract, so the "owner must not be an EOA" check is meaningful.
contract SafeStubV4 {}

/// @dev A kit as far as the deploy gate can see it: an owner, and `isLockedLaunch`.
contract OwnedOracleV4 is MockLaunchOracle {
    address public owner;

    constructor(address owner_) {
        owner = owner_;
    }
}

/// @dev The part of a pool manager the install gate reads.
contract ManagerStubV4 {
    address public protocolFeeController;

    function setProtocolFeeController(address c) external {
        protocolFeeController = c;
    }
}

/// @dev The part of `*PoolManagerOwner` the install touches, in front of its manager.
contract WrapperStubV4 {
    address public owner;
    ManagerStubV4 public immutable poolManager;

    constructor(address owner_) {
        owner = owner_;
        poolManager = new ManagerStubV4();
    }

    function setProtocolFeeController(address c) external {
        require(msg.sender == owner, "owner");
        poolManager.setProtocolFeeController(c);
    }
}

contract FeeControllerV4ScriptsTest is Test {
    uint256 internal constant PK = 0xBEEF_0044;

    DeployFeeControllerV4Script deployScript;
    BuildInstallFeeControllerV4Script installScript;

    address safe;
    DeepCoreProtocolFeeControllerV2 v2;
    OwnedOracleV4 kitA;
    OwnedOracleV4 kitB;
    DeepCoreProtocolFeeControllerV4 v4;

    TimelockController timelock;
    WrapperStubV4 clWrapper;
    WrapperStubV4 binWrapper;

    address stranger = makeAddr("stranger");

    function setUp() public {
        deployScript = new DeployFeeControllerV4Script();
        installScript = new BuildInstallFeeControllerV4Script();

        safe = address(new SafeStubV4());
        v2 = new DeepCoreProtocolFeeControllerV2(safe, makeAddr("guardian"));
        kitA = new OwnedOracleV4(safe);
        kitB = new OwnedOracleV4(safe);
        v4 = new DeepCoreProtocolFeeControllerV4(safe, IProtocolFeeController(address(v2)), _kits(), new address[](0), 7 days);

        address[] memory proposers = new address[](1);
        proposers[0] = safe;
        address[] memory executors = new address[](1);
        executors[0] = address(0);
        timelock = new TimelockController(InstallV4Calldata.CUSTODY_DELAY, proposers, executors, address(0));

        clWrapper = new WrapperStubV4(address(timelock));
        binWrapper = new WrapperStubV4(address(timelock));
    }

    function _kits() internal view returns (address[] memory l) {
        l = new address[](2);
        l[0] = address(kitA);
        l[1] = address(kitB);
    }

    function _one(address a) internal pure returns (address[] memory l) {
        l = new address[](1);
        l[0] = a;
    }

    function _installed(address c) internal {
        vm.startPrank(address(timelock));
        clWrapper.setProtocolFeeController(c);
        binWrapper.setProtocolFeeController(c);
        vm.stopPrank();
    }

    /* ------------------------- deploy gate ------------------------- */

    function test_Deploy_GatePassesForTheRealShape() public view {
        deployScript.checkInputs(safe, address(v2), _kits());
        deployScript.verifyDeployment(v4, safe, address(v2), _kits());
    }

    function test_Deploy_GatePassesForOneKitAndForFour() public {
        deployScript.checkInputs(safe, address(v2), _one(address(kitA)));

        address[] memory four = new address[](4);
        four[0] = address(kitA);
        four[1] = address(kitB);
        four[2] = address(new OwnedOracleV4(safe));
        four[3] = address(new OwnedOracleV4(safe));
        deployScript.checkInputs(safe, address(v2), four);
        DeepCoreProtocolFeeControllerV4 c = new DeepCoreProtocolFeeControllerV4(safe, IProtocolFeeController(address(v2)), four, new address[](0), 7 days);
        deployScript.verifyDeployment(c, safe, address(v2), four);
    }

    /// The script end to end as a contract: CREATE3 through CreateX at a salt permissioned to the
    /// deployer, owned by the Safe from birth, every immutable read back.
    function test_Deploy_RunWith_DeploysThroughCreateXAndReadsEverythingBack() public {
        CreateXTest.etch();
        DeepCoreDeploy.Target memory target = CreateXTest.target(vm.addr(PK), bytes11("dcore.feev4"));
        address predicted = DeepCoreDeploy.predict(target);

        DeepCoreProtocolFeeControllerV4 c = deployScript.runWith(PK, safe, address(v2), _kits(), target);

        assertEq(address(c), predicted, "CREATE3 prediction");
        assertEq(c.owner(), safe, "the deployer never owned it");
        assertEq(c.treasury(), safe);
        assertEq(address(c.policy()), address(v2));
        assertEq(c.launchOracleCount(), 2);
        assertEq(c.launchOracle0(), address(kitA));
        assertEq(c.launchOracle1(), address(kitB));
        assertEq(c.launchOracle2(), address(0));
        assertEq(c.launchOracle3(), address(0));

        /* Deployed once: the same salt is refused, never "reuse whatever is there". */
        vm.expectRevert(bytes("the predicted address already has code on this chain (DEEPCORE_FEE_CONTROLLER_V4_ZH)"));
        deployScript.runWith(PK, safe, address(v2), _kits(), target);
    }

    /// The address is a function of (CreateX, deployer, salt) alone: another chain's kits and policy
    /// do not move it.
    function test_Deploy_RunWith_SameAddressWithOtherConstructorArguments() public {
        CreateXTest.etch();
        DeepCoreDeploy.Target memory target = CreateXTest.target(vm.addr(PK), bytes11("dcore.feev4"));

        uint256 clean = vm.snapshotState();
        address first = address(deployScript.runWith(PK, safe, address(v2), _kits(), target));
        vm.revertToState(clean);

        target.expected = first;
        address second = address(deployScript.runWith(PK, safe, address(v2), _one(address(kitB)), target));
        assertEq(second, first);
    }

    function test_Deploy_RunWith_RefusesASaltMinedForAnotherKey() public {
        CreateXTest.etch();
        DeepCoreDeploy.Target memory target = CreateXTest.target(address(0xD00D), bytes11("dcore.feev4"));
        vm.expectRevert(bytes("the salt target is not this deployer"));
        deployScript.runWith(PK, safe, address(v2), _kits(), target);
    }

    /// On a production chain the owner must be the governance Safe of record, not merely a contract.
    /// The Safe of record is set (`DeepCoreGovernance.SAFE`, 2026-10-07), so on every production chain -
    /// HyperEVM 999 included - the test's stub Safe is refused as not being it.
    function test_Deploy_RunWith_ProductionChainrefusesAnOwnerThatIsNotTheSafeOfRecord() public {
        assertTrue(DeepCoreGovernance.SAFE != address(0), "the governance Safe of record is set (owner, 2026-10-07)");
        CreateXTest.etch();
        DeepCoreDeploy.Target memory target = CreateXTest.target(vm.addr(PK), bytes11("dcore.feev4"));
        vm.chainId(999);
        vm.expectRevert(bytes("FEE_OWNER_SAFE is not the governance Safe of record"));
        deployScript.runWith(PK, safe, address(v2), _kits(), target);
    }

    function test_Deploy_RefusesV2OwnedBySomeoneElse() public {
        DeepCoreProtocolFeeControllerV2 foreign = new DeepCoreProtocolFeeControllerV2(address(new SafeStubV4()), address(0));
        vm.expectRevert(bytes("V2 is not owned by the Safe: V4 would compose over foreign policy"));
        deployScript.checkInputs(safe, address(foreign), _kits());
    }

    function test_Deploy_RefusesAnEmptyListAndTooMany() public {
        vm.expectRevert(bytes("LAUNCH_ORACLES is empty: name every kit whose pools must keep their zero"));
        deployScript.checkInputs(safe, address(v2), new address[](0));

        address[] memory five = new address[](5);
        for (uint256 i; i < 5; ++i) {
            five[i] = address(new OwnedOracleV4(safe));
        }
        vm.expectRevert(bytes("LAUNCH_ORACLES names more than 4 kits"));
        deployScript.checkInputs(safe, address(v2), five);
    }

    /// Every refusal names the position of the entry that failed, first or last.
    function test_Deploy_RefusesATenantKit_AtEitherPosition() public {
        OwnedOracleV4 tenantKit = new OwnedOracleV4(stranger);
        address[] memory l = _kits();
        l[0] = address(tenantKit);
        vm.expectRevert(bytes("LAUNCH_ORACLES[0] is not owned by the Safe: not DeepCore's kit"));
        deployScript.checkInputs(safe, address(v2), l);

        l = _kits();
        l[1] = address(tenantKit);
        vm.expectRevert(bytes("LAUNCH_ORACLES[1] is not owned by the Safe: not DeepCore's kit"));
        deployScript.checkInputs(safe, address(v2), l);
    }

    function test_Deploy_RefusesAKitWithoutOwner() public {
        address[] memory l = _kits();
        l[1] = address(new MockLaunchOracle());
        vm.expectRevert(bytes("LAUNCH_ORACLES[1] has no owner(): not a DeepCore kit"));
        deployScript.checkInputs(safe, address(v2), l);
    }

    function test_Deploy_RefusesNonOracleAndLiars() public {
        address[] memory l = _kits();
        l[1] = address(new NotAnOracle());
        vm.expectRevert(bytes("LAUNCH_ORACLES[1] does not implement isLockedLaunch"));
        deployScript.checkInputs(safe, address(v2), l);

        OwnedOracleV4 liar = new OwnedOracleV4(safe);
        liar.setMode(MockLaunchOracle.Mode.TrueForEverything);
        l = _kits();
        l[0] = address(liar);
        vm.expectRevert(bytes("LAUNCH_ORACLES[0] does not implement isLockedLaunch"));
        deployScript.checkInputs(safe, address(v2), l);
    }

    function test_Deploy_RefusesZeroEOAPolicyAndSafeEntries() public {
        address[] memory l = _kits();
        l[1] = address(0);
        vm.expectRevert(bytes("LAUNCH_ORACLES[1] is the zero address"));
        deployScript.checkInputs(safe, address(v2), l);

        l[1] = stranger;
        vm.expectRevert(bytes("LAUNCH_ORACLES[1] has no code"));
        deployScript.checkInputs(safe, address(v2), l);

        l[1] = address(v2);
        vm.expectRevert(bytes("LAUNCH_ORACLES[1] is the policy or the Safe, not a kit"));
        deployScript.checkInputs(safe, address(v2), l);

        l[1] = safe;
        vm.expectRevert(bytes("LAUNCH_ORACLES[1] is the policy or the Safe, not a kit"));
        deployScript.checkInputs(safe, address(v2), l);
    }

    function test_Deploy_RefusesADuplicate() public {
        address[] memory l = _kits();
        l[1] = l[0];
        vm.expectRevert(bytes("LAUNCH_ORACLES[1] is listed twice: a kit is probably missing from the list"));
        deployScript.checkInputs(safe, address(v2), l);
    }

    function test_Deploy_RefusesEOAOwner() public {
        vm.expectRevert(bytes("owner must be the Safe contract, not an EOA"));
        deployScript.checkInputs(stranger, address(v2), _kits());
    }

    function test_Deploy_ReadBackCatchesAWrongImmutable() public {
        address[] memory l = _kits();
        l[1] = address(new OwnedOracleV4(safe));
        vm.expectRevert(bytes("launchOracles entry or order mismatch"));
        deployScript.verifyDeployment(v4, safe, address(v2), l);

        /* The right kits in the wrong order are a different deployment. */
        l = _kits();
        (l[0], l[1]) = (l[1], l[0]);
        vm.expectRevert(bytes("launchOracles entry or order mismatch"));
        deployScript.verifyDeployment(v4, safe, address(v2), l);

        vm.expectRevert(bytes("launchOracleCount mismatch"));
        deployScript.verifyDeployment(v4, safe, address(v2), _one(address(kitA)));

        DeepCoreProtocolFeeControllerV2 otherV2 = new DeepCoreProtocolFeeControllerV2(safe, address(0));
        vm.expectRevert(bytes("policy immutable mismatch"));
        deployScript.verifyDeployment(v4, safe, address(otherV2), _kits());

        vm.expectRevert(bytes("owner is not the Safe"));
        deployScript.verifyDeployment(v4, stranger, address(v2), _kits());
    }

    /* --------------------- the custody operation --------------------- */

    function test_Install_SaltIsTheConvention() public pure {
        assertEq(InstallV4Calldata.SALT, keccak256("deepcore.install.feeControllerV4"));
        /* Its own operation: never the salt V3's install used. */
        assertTrue(InstallV4Calldata.SALT != keccak256("deepcore.install.feeControllerV3"));
        assertTrue(InstallV4Calldata.SALT != 0xec2bd2bbd4480d21219a0ee4eff85fe05849357898360aab2895b8d7a4a5a9f4);
    }

    function test_Install_RefusesZeroV4() public {
        vm.expectRevert(bytes("zero address"));
        installScript.checkOperation(address(0), safe, address(v2), address(timelock), address(clWrapper), address(binWrapper));
    }

    function test_Install_RefusesV2AsV4() public {
        vm.expectRevert(bytes("that is V2, not V4"));
        installScript.checkOperation(address(v2), safe, address(v2), address(timelock), address(clWrapper), address(binWrapper));

        /* Another V2, not the policy: named, not a bare revert. */
        DeepCoreProtocolFeeControllerV2 otherV2 = new DeepCoreProtocolFeeControllerV2(safe, address(0));
        vm.expectRevert(bytes("no launchOracleCount(): not a DeepCoreProtocolFeeControllerV4"));
        installScript.checkOperation(
            address(otherV2), safe, address(v2), address(timelock), address(clWrapper), address(binWrapper)
        );
    }

    function test_Install_RefusesV3AsV4() public {
        DeepCoreProtocolFeeControllerV3 v3 =
            new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(v2)), address(kitA));
        vm.expectRevert(bytes("that is a V3 (it answers launchOracle()), not V4"));
        installScript.checkOperation(address(v3), safe, address(v2), address(timelock), address(clWrapper), address(binWrapper));
    }

    function test_Install_RefusesAV4OverForeignPolicyOrOwner() public {
        DeepCoreProtocolFeeControllerV2 otherV2 = new DeepCoreProtocolFeeControllerV2(safe, address(0));
        vm.expectRevert(bytes("V4.policy is not the installed V2"));
        installScript.checkOperation(
            address(v4), safe, address(otherV2), address(timelock), address(clWrapper), address(binWrapper)
        );

        address otherSafe = address(new SafeStubV4());
        vm.expectRevert(bytes("V4 owner is not the Safe"));
        installScript.checkOperation(
            address(v4), otherSafe, address(v2), address(timelock), address(clWrapper), address(binWrapper)
        );
    }

    function test_Install_RefusesAV4NamingATenantKit() public {
        OwnedOracleV4 tenantKit = new OwnedOracleV4(stranger);
        address[] memory l = _kits();
        l[1] = address(tenantKit);
        DeepCoreProtocolFeeControllerV4 c = new DeepCoreProtocolFeeControllerV4(safe, IProtocolFeeController(address(v2)), l, new address[](0), 7 days);
        vm.expectRevert(bytes("a V4 launch oracle is not owned by the Safe: not DeepCore's kit"));
        installScript.checkOperation(address(c), safe, address(v2), address(timelock), address(clWrapper), address(binWrapper));
    }

    /// The Safe still owning the wrappers would let the install bypass the custody tier.
    function test_Install_RefusesWhileTheSafeStillOwnsTheWrappers() public {
        WrapperStubV4 safeOwned = new WrapperStubV4(safe);
        vm.expectRevert(
            bytes("wrappers are not owned by the custody timelock yet: execute and verify the queued acceptOwnership first")
        );
        installScript.checkOperation(address(v4), safe, address(v2), address(timelock), address(safeOwned), address(binWrapper));
    }

    function test_Install_RefusesAddressesWithoutCode() public {
        vm.expectRevert(bytes("CUSTODY_TIMELOCK has no code on this chain: check the address and the RPC"));
        installScript.checkOperation(address(v4), safe, address(v2), stranger, address(clWrapper), address(binWrapper));

        vm.expectRevert(bytes("a pool manager owner wrapper has no code on this chain"));
        installScript.checkOperation(address(v4), safe, address(v2), address(timelock), stranger, address(binWrapper));
    }

    /* ------------- the gate that is specific to V4: no kit is dropped ------------- */

    function test_Install_RecognisedKits() public {
        DeepCoreProtocolFeeControllerV3 v3 =
            new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(v2)), address(kitA));

        address[] memory got = installScript.recognisedKits(address(v3));
        assertEq(got.length, 1);
        assertEq(got[0], address(kitA));

        got = installScript.recognisedKits(address(v4));
        assertEq(got.length, 2);
        assertEq(got[0], address(kitA));
        assertEq(got[1], address(kitB));

        assertEq(installScript.recognisedKits(address(v2)).length, 0, "V2 recognises no kit");
    }

    function test_Install_NothingInstalledOrV2Installed_NothingToKeep() public {
        installScript.checkNoKitIsDropped(address(v4), address(clWrapper));
        _installed(address(v2));
        installScript.checkNoKitIsDropped(address(v4), address(clWrapper));
        installScript.checkNoKitIsDropped(address(v4), address(binWrapper));
    }

    /// The case V4 was built for: a V3 bound to the first kit is installed, and the V4 names it.
    function test_Install_V3Installed_PassesWhenV4KeepsItsKit() public {
        DeepCoreProtocolFeeControllerV3 v3 =
            new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(v2)), address(kitA));
        _installed(address(v3));
        installScript.checkNoKitIsDropped(address(v4), address(clWrapper));
        installScript.checkNoKitIsDropped(address(v4), address(binWrapper));
    }

    /// And the mistake it guards against: a V4 that names only the new kit.
    function test_Install_V3Installed_RefusesAV4ThatDropsItsKit() public {
        DeepCoreProtocolFeeControllerV3 v3 =
            new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(v2)), address(kitA));
        _installed(address(v3));
        DeepCoreProtocolFeeControllerV4 newKitOnly =
            new DeepCoreProtocolFeeControllerV4(safe, IProtocolFeeController(address(v2)), _one(address(kitB)), new address[](0), 7 days);

        /* Everything about the new controller alone is in order... */
        installScript.checkOperation(
            address(newKitOnly), safe, address(v2), address(timelock), address(clWrapper), address(binWrapper)
        );
        /* ...and it would still cost the first kit's pools their refusal. */
        bytes memory refusal = bytes(
            string.concat(
                "V4 drops kit ",
                vm.toString(address(kitA)),
                ", which the installed controller recognises: its pools would lose the zero-fee refusal"
            )
        );
        vm.expectRevert(refusal);
        installScript.checkNoKitIsDropped(address(newKitOnly), address(clWrapper));
        vm.expectRevert(refusal);
        installScript.checkNoKitIsDropped(address(newKitOnly), address(binWrapper));
    }

    function test_Install_V4Installed_RefusesAV4ThatDropsOneOfItsKits() public {
        _installed(address(v4));
        OwnedOracleV4 kitC = new OwnedOracleV4(safe);

        address[] memory grown = new address[](3);
        grown[0] = address(kitA);
        grown[1] = address(kitB);
        grown[2] = address(kitC);
        DeepCoreProtocolFeeControllerV4 superset =
            new DeepCoreProtocolFeeControllerV4(safe, IProtocolFeeController(address(v2)), grown, new address[](0), 7 days);
        installScript.checkNoKitIsDropped(address(superset), address(clWrapper));

        address[] memory swapped = new address[](2);
        swapped[0] = address(kitA);
        swapped[1] = address(kitC);
        DeepCoreProtocolFeeControllerV4 dropsB =
            new DeepCoreProtocolFeeControllerV4(safe, IProtocolFeeController(address(v2)), swapped, new address[](0), 7 days);
        vm.expectRevert(
            bytes(
                string.concat(
                    "V4 drops kit ",
                    vm.toString(address(kitB)),
                    ", which the installed controller recognises: its pools would lose the zero-fee refusal"
                )
            )
        );
        installScript.checkNoKitIsDropped(address(dropsB), address(clWrapper));
    }

    /// Full rehearsal against a real OpenZeppelin TimelockController: the Safe schedules the printed
    /// bytes, nobody can execute early, a stranger executes after 48h, and both wrappers point at V4.
    function test_Install_RehearsalAgainstARealTimelock() public {
        DeepCoreProtocolFeeControllerV3 v3 =
            new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(v2)), address(kitA));
        _installed(address(v3));

        installScript.checkOperation(address(v4), safe, address(v2), address(timelock), address(clWrapper), address(binWrapper));
        installScript.checkNoKitIsDropped(address(v4), address(clWrapper));
        installScript.checkNoKitIsDropped(address(v4), address(binWrapper));

        bytes32 id = InstallV4Calldata.operationId(address(clWrapper), address(binWrapper), address(v4));
        (address[] memory t, uint256[] memory v, bytes[] memory p) =
            InstallV4Calldata.batch(address(clWrapper), address(binWrapper), address(v4));
        assertEq(id, timelock.hashOperationBatch(t, v, p, bytes32(0), InstallV4Calldata.SALT));

        vm.prank(stranger);
        (bool ok,) = address(timelock).call(
            InstallV4Calldata.scheduleCalldata(address(clWrapper), address(binWrapper), address(v4))
        );
        assertFalse(ok, "only the Safe proposes");

        vm.prank(safe);
        (ok,) = address(timelock).call(
            InstallV4Calldata.scheduleCalldata(address(clWrapper), address(binWrapper), address(v4))
        );
        assertTrue(ok, "Safe schedules");
        assertTrue(timelock.isOperationPending(id));

        bytes memory exec = InstallV4Calldata.executeCalldata(address(clWrapper), address(binWrapper), address(v4));
        vm.warp(block.timestamp + InstallV4Calldata.CUSTODY_DELAY - 1);
        vm.prank(stranger);
        (ok,) = address(timelock).call(exec);
        assertFalse(ok, "not before 48h");

        vm.warp(block.timestamp + 1);
        vm.prank(stranger);
        (ok,) = address(timelock).call(exec);
        assertTrue(ok, "anyone executes after 48h");

        assertEq(clWrapper.poolManager().protocolFeeController(), address(v4));
        assertEq(binWrapper.poolManager().protocolFeeController(), address(v4));
        assertTrue(timelock.isOperationDone(id));
    }
}
