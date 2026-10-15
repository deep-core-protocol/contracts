// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";
import {DeepCoreSignerScript} from "deepcore-hooks/script/DeepCoreSigner.sol";
import {DeepCoreTunerGate} from "../src/DeepCoreTunerGate.sol";

/**
 * Deploys DeepCore's own `DeepCoreTunerGate` (CreateX label `DEEPCORE_TUNER_GATE`): the limits in front of an
 * agent key that tunes DeepCore-owned dynamic-fee pools. A tenant deploys its own gate with its own owner;
 * this script is for the protocol's.
 *
 * The gate is born with NO agent and NO policy: both are escalations the owner proposes afterwards, each
 * behind the gate's notice. Nothing an agent can do is possible at deployment.
 *
 * Inputs, no defaults:
 *   GATE_OWNER                    the Safe (on a production chain: the governance Safe of record)
 *   GATE_GUARDIAN                 Ops: may only revoke the agent and pause. Must differ from the owner.
 *   GATE_RECIPIENT                the Safe: where misdirected value is swept
 *   GATE_AGENT_NOTICE_SECONDS     >= 86,400 (design: 86,400)
 *   GATE_POLICY_NOTICE_SECONDS    >= 86,400 (design: 86,400)
 *   GATE_MAX_DEVIATION_BPS        1 .. 1,000 (price bps per reference update; design ceiling 1,000)
 * Also PRIVATE_KEY | DEPLOYER and the DEEPCORE_TUNER_GATE salt pair.
 */
contract DeployDeepCoreTunerGateScript is DeepCoreSignerScript {
    string internal constant LABEL = "DEEPCORE_TUNER_GATE";
    bytes4 internal constant RENOUNCE_DISABLED = bytes4(keccak256("RenounceDisabled()"));

    struct Params {
        uint256 pk;
        address owner;
        address guardian;
        address recipient;
        uint32 agentNotice;
        uint32 policyNotice;
        uint16 maxDeviationBps;
        DeepCoreDeploy.Target target;
    }

    function run() public returns (DeepCoreTunerGate gate) {
        uint256 pk = _pkFromEnv();
        return runWith(
            Params({
                pk: pk,
                owner: vm.envAddress("GATE_OWNER"),
                guardian: vm.envAddress("GATE_GUARDIAN"),
                recipient: vm.envAddress("GATE_RECIPIENT"),
                agentNotice: uint32(_bounded("GATE_AGENT_NOTICE_SECONDS", type(uint32).max)),
                policyNotice: uint32(_bounded("GATE_POLICY_NOTICE_SECONDS", type(uint32).max)),
                maxDeviationBps: uint16(_bounded("GATE_MAX_DEVIATION_BPS", type(uint16).max)),
                target: DeepCoreDeploy.fromEnv(LABEL, _signerOf(pk))
            })
        );
    }

    function _bounded(string memory name, uint256 max) internal view returns (uint256 v) {
        v = vm.envUint(name);
        require(v <= max, string.concat(name, " overflows its type"));
    }

    function checkInputs(Params memory p, address deployer) public view {
        DeepCoreGovernance.requireGovernanceSafe(p.owner, deployer, "GATE_OWNER");
        DeepCoreGovernance.requireGovernanceSafe(p.recipient, deployer, "GATE_RECIPIENT");
        require(p.guardian != address(0), "GATE_GUARDIAN is unset");
        require(p.guardian != p.owner && p.guardian != deployer, "GATE_GUARDIAN must be Ops, not the owner or the deployer");
    }

    function initCode(Params memory p) public pure returns (bytes memory) {
        return abi.encodePacked(
            type(DeepCoreTunerGate).creationCode,
            abi.encode(p.owner, p.guardian, p.recipient, p.agentNotice, p.policyNotice, p.maxDeviationBps)
        );
    }

    function runWith(Params memory p) public returns (DeepCoreTunerGate gate) {
        address deployer = _signerOf(p.pk);
        require(p.target.deployer == deployer, "the salt target is not this deployer");
        DeepCoreDeploy.preflight(p.target, LABEL);
        checkInputs(p, deployer);

        console.log("=== DeepCoreTunerGate ===");
        console.log("  chain id          ", block.chainid);
        console.log("  owner (Safe)      ", p.owner);
        console.log("  guardian (Ops)    ", p.guardian);
        console.log("  recipient (Safe)  ", p.recipient);
        console.log("  notices, s        ", p.agentNotice, p.policyNotice);
        console.log("  max deviation bps ", p.maxDeviationBps);
        console.log("  will deploy to    ", DeepCoreDeploy.predict(p.target), "(CREATE3 via CreateX)");

        bytes memory code = initCode(p);
        _startBroadcastAs(p.pk);
        gate = DeepCoreTunerGate(DeepCoreDeploy.deploy(p.target, code, LABEL));
        vm.stopBroadcast();

        require(address(gate) == DeepCoreDeploy.predict(p.target), "gate is not at the predicted address");
        require(gate.owner() == p.owner, "owner mismatch");
        require(gate.pendingOwner() == address(0), "a pending owner exists at birth");
        require(gate.guardian() == p.guardian, "guardian mismatch");
        require(gate.protocolRecipient() == p.recipient, "recipient mismatch");
        require(gate.agent() == address(0), "an agent exists at birth");
        require(!gate.paused(), "paused at birth");
        require(gate.AGENT_NOTICE_SECONDS() == p.agentNotice && gate.POLICY_NOTICE_SECONDS() == p.policyNotice, "notice mismatch");
        require(gate.MAX_DEVIATION_CEILING_BPS() == p.maxDeviationBps, "deviation ceiling mismatch");
        (bool renounced, bytes memory reason) = address(gate).staticcall(abi.encodeWithSignature("renounceOwnership()"));
        require(!renounced && reason.length == 4 && bytes4(reason) == RENOUNCE_DISABLED, "renounceOwnership does not revert");
        console.log("DeepCoreTunerGate", address(gate));
        console.log("  runtime bytes     ", address(gate).code.length);
    }
}
