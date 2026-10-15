// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {CreateXTest} from "deepcore-hooks/test/helpers/CreateXLike.sol";
import {DeployDeepCoreTunerGateScript} from "../script/DeployDeepCoreTunerGate.s.sol";
import {DeepCoreTunerGate} from "../src/DeepCoreTunerGate.sol";

contract GateSafeStandIn {}

contract DeployDeepCoreTunerGateTest is Test {
    uint256 internal constant PK = 0xA11CE;
    address internal constant OPS = address(0x0B5);
    address internal deployer;
    address internal safe;
    DeployDeepCoreTunerGateScript internal script;

    function setUp() public {
        deployer = vm.addr(PK);
        CreateXTest.etch();
        safe = address(new GateSafeStandIn());
        script = new DeployDeepCoreTunerGateScript();
    }

    function _p() internal view returns (DeployDeepCoreTunerGateScript.Params memory) {
        return DeployDeepCoreTunerGateScript.Params({
            pk: PK,
            owner: safe,
            guardian: OPS,
            recipient: safe,
            agentNotice: 1 days,
            policyNotice: 1 days,
            maxDeviationBps: 1_000,
            target: CreateXTest.target(deployer, bytes11("gate"))
        });
    }

    function test_deploys_readsBack_noAgentNoPolicy() public {
        DeepCoreTunerGate gate = script.runWith(_p());
        assertEq(gate.owner(), safe);
        assertEq(gate.guardian(), OPS);
        assertEq(gate.agent(), address(0));
        assertFalse(gate.paused());
    }

    function test_refusesAnEoaOwner_andAGuardianThatIsTheOwnerOrDeployer() public {
        DeployDeepCoreTunerGateScript.Params memory p = _p();
        p.owner = address(0xE0A);
        vm.expectRevert(bytes("GATE_OWNER has no code - the Safe, not an EOA"));
        script.runWith(p);
        p = _p();
        p.guardian = safe;
        vm.expectRevert(bytes("GATE_GUARDIAN must be Ops, not the owner or the deployer"));
        script.runWith(p);
        p = _p();
        p.guardian = deployer;
        vm.expectRevert(bytes("GATE_GUARDIAN must be Ops, not the owner or the deployer"));
        script.runWith(p);
    }

    function test_onProduction_refusesAnOwnerThatIsNotTheSafeOfRecord() public {
        vm.chainId(999);
        vm.expectRevert(bytes("GATE_OWNER is not the governance Safe of record"));
        script.checkInputs(_p(), deployer);
    }

    function test_refusesASecondDeployAtTheSameSalt() public {
        script.runWith(_p());
        vm.expectRevert(bytes("the predicted address already has code on this chain (DEEPCORE_TUNER_GATE)"));
        script.runWith(_p());
    }
}
