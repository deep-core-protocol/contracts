// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {ContractClockProbe} from "deepcore-hooks/script/ContractClock.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";
import {AllowlistComplianceOracle} from "../src/oracles/AllowlistComplianceOracle.sol";
import {RwaReleaseBase} from "./RwaReleaseBase.sol";

/**
 * Deploys `AllowlistComplianceOracle` (CreateX label 21, `ALLOWLIST_COMPLIANCE_ORACLE`).
 *
 * OWNERSHIP (CLAUDE.md: `AllowlistComplianceOracle | owner | Safe` — allowlist edits are reversible).
 * Set in the constructor; nothing to accept. Powers: `setRecord(s)`, `revoke`, `rescueERC20`, two-step
 * transfer. It holds no value and answers `checkCompliance` from its own records only. It is consulted
 * only by a `StockPairHook` pool the Safe points at it through `configurePool`, and only on ENTRY.
 *
 * No listing: it is an oracle, not a hook, and the registry lists hooks.
 *
 * Env: PRIVATE_KEY | DEPLOYER, the ALLOWLIST_COMPLIANCE_ORACLE salt pair, RWA_OWNER.
 */
contract DeployAllowlistComplianceOracleScript is RwaReleaseBase {
    string internal constant LABEL = "ALLOWLIST_COMPLIANCE_ORACLE";

    struct Params {
        Signer signer;
        address owner;
        DeepCoreDeploy.Target target;
    }

    function run() public returns (AllowlistComplianceOracle oracle) {
        ContractClockProbe.Reading memory clock = ContractClockProbe.check();
        console.log("chain clock: block.timestamp (EVM) ", clock.evmTimestamp);
        Signer memory s = _signerFromEnv();
        return runWith(Params({signer: s, owner: vm.envAddress("RWA_OWNER"), target: DeepCoreDeploy.fromEnv(LABEL, s.deployer)}));
    }

    function initCode(Params memory p) public pure returns (bytes memory) {
        return abi.encodePacked(type(AllowlistComplianceOracle).creationCode, abi.encode(p.owner));
    }

    function runWith(Params memory p) public returns (AllowlistComplianceOracle oracle) {
        address deployer = p.signer.deployer;
        _preflightTarget(p.target, deployer, LABEL);
        _requireOwner(p.owner, deployer);

        console.log("=== AllowlistComplianceOracle ===");
        console.log("  chain id        ", block.chainid);
        console.log("  deployer        ", deployer);
        console.log("  owner (Safe)    ", p.owner);
        console.log("  will deploy to  ", DeepCoreDeploy.predict(p.target), "(CREATE3 via CreateX)");

        bytes memory code = initCode(p);
        _begin(p.signer);
        oracle = AllowlistComplianceOracle(DeepCoreDeploy.deploy(p.target, code, LABEL));
        vm.stopBroadcast();

        require(address(oracle) == DeepCoreDeploy.predict(p.target), "oracle is not at the predicted address");
        require(address(oracle).code.length > 0, "oracle has no code");
        _requireOwnership(address(oracle), p.owner);
        // Empty at birth: nobody is permitted, including the deployer and the Safe.
        require(!oracle.isPermitted(deployer), "deployer is permitted at birth");
        require(!oracle.isPermitted(p.owner), "owner is permitted at birth");

        console.log("AllowlistComplianceOracle", address(oracle));
        console.log("  owner           ", oracle.owner());
        console.log("  runtime bytes   ", address(oracle).code.length);
    }
}
