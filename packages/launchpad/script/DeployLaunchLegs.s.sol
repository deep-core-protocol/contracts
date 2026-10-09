// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {DeepCoreSignerScript} from "deepcore-hooks/script/DeepCoreSigner.sol";

import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";

/**
 * Deploys the `LaunchLegs` library through CreateX, at its own mined salt, BEFORE the kit.
 *
 * ############################ WHY THE LIBRARY NEEDS ITS OWN SCRIPT ############################
 *
 * `LaunchpadKitV2` reaches `LaunchLegs` by DELEGATECALL to an address fixed at LINK time, so the
 * library's address is baked into the kit's runtime bytecode. Three consequences decide this file:
 *
 *   1. The kit cannot be deployed through CreateX until the library address is KNOWN, because
 *      `type(LaunchpadKitV2).creationCode` must already be linked when the script runs. So the library
 *      goes first, in its own process.
 *   2. If the library's address differed per chain, the KIT's bytecode would differ per chain - two
 *      chains with the same kit address and different code. That is precisely the trap G-3 recorded, so
 *      the library gets a mined, permissioned, chain-id-free salt like everything else and is the same
 *      address on every chain. `DEEPCORE_ADDRESS_LAUNCH_LEGS_QF` is then a constant of the release.
 *   3. Letting forge auto-deploy the library instead (its default when it detects an unlinked artifact)
 *      would put a CREATE from the deployer's nonce in the middle of the plan - not vanity, not the same
 *      address twice, and the source of the duplicate-nonce plan CLAUDE.md records for foundry 1.8.1.
 *      `DeployLaunchpadKitV2.s.sol` refuses to run unless its creation code is linked to THIS address.
 *
 * A library's creation code patches its own address into the runtime before returning it (that is how
 * solc stops a library being called directly), so a CREATE3 deployment self-patches to the CREATE3
 * address. Nothing else about a library depends on who deployed it.
 *
 * THE LIBRARY HAS NO OWNER AND NO STATE (CLAUDE.md Ownership table: "n/a - do not add one"). It is
 * stateless code the kit trusts completely; verify it in the same session as the kit.
 *
 * Usage:
 *   eval "$(node ops/deploy/tools/salts-env.mjs ops/deploy/salts/salts.0x<deployer>.json)"
 *   forge script script/DeployLaunchLegs.s.sol --rpc-url $RPC            # dry run
 *   forge script script/DeployLaunchLegs.s.sol --rpc-url $RPC --broadcast --slow
 *
 * Then, for the kit:
 *   forge script script/DeployLaunchpadKitV2.s.sol --rpc-url $RPC --broadcast --slow \
 *     --libraries src/libraries/LaunchLegs.sol:LaunchLegs:$DEEPCORE_ADDRESS_LAUNCH_LEGS_QF
 */
contract DeployLaunchLegsScript is DeepCoreSignerScript {
    string internal constant LABEL = "LAUNCH_LEGS_QF";
    /// @dev The artifact this deploys. `vm.getCode` rather than `type(LaunchLegs).creationCode`, which
    /// solc does not offer for a library type.
    string internal constant ARTIFACT = "LaunchLegs.sol:LaunchLegs";

    struct Wiring {
        uint256 pk;
        DeepCoreDeploy.Target target;
    }

    function run() public returns (address legs) {
        uint256 pk = _pkFromEnv();
        return runWith(Wiring({pk: pk, target: DeepCoreDeploy.fromEnv(LABEL, _signerOf(pk))}));
    }

    function initCode() public view returns (bytes memory) {
        bytes memory code = vm.getCode(ARTIFACT);
        require(code.length > 0, "LaunchLegs artifact is empty - run forge build first");
        return code;
    }

    function runWith(Wiring memory w) public returns (address legs) {
        require(w.target.deployer == _signerOf(w.pk), "the salt target is not this deployer");
        DeepCoreDeploy.preflight(w.target, LABEL);

        bytes memory code = initCode();
        _startBroadcastAs(w.pk);
        legs = DeepCoreDeploy.deploy(w.target, code, LABEL);
        vm.stopBroadcast();

        require(legs == DeepCoreDeploy.predict(w.target), "LaunchLegs is not at the predicted address");
        require(legs.code.length > 0, "LaunchLegs has no code");

        console.log("=== LaunchLegs (library) ===");
        console.log("  chain id ", block.chainid);
        console.log("  address  ", legs, "(CREATE3 via CreateX: same on every chain for this deployer + salt)");
        console.log("  runtime  ", legs.code.length, "bytes");
        console.log("  salt");
        console.logBytes32(w.target.salt);
        console.log("");
        console.log("NEXT: deploy the kit with");
        console.log("  --libraries src/libraries/LaunchLegs.sol:LaunchLegs:<the address above>");
        console.log("and verify this library in the same session as the kit.");
    }
}
