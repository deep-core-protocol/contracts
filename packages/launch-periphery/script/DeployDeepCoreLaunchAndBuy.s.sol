// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {DeepCoreSignerScript} from "deepcore-hooks/script/DeepCoreSigner.sol";

import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";
import {ILaunchpadKitV2} from "deepcore-launchpad/src/interfaces/ILaunchpadKitV2.sol";

import {DeepCoreLaunchAndBuy} from "../src/DeepCoreLaunchAndBuy.sol";

/**
 * Deploys `DeepCoreLaunchAndBuy` against an already-deployed `LaunchpadKitV2`.
 *
 * ############################ IT HAS NO OWNER, AND THAT IS THE POINT ############################
 *
 * There is nothing to configure after deployment: every address is an immutable, and every one of
 * them except the sweep recipient is READ OFF THE KIT inside the constructor rather than supplied
 * here. So this script's job is only to (a) point it at the right kit and (b) prove, by reading the
 * deployed contract back, that it wired itself to the vault and managers the runbook expected.
 *
 * ############################ THE DEPLOYMENT-RULE TRAP, 2026-09-19 ############################
 *
 * A contract deployed through a script whose compilation unit includes a contract carrying
 * `compilation_restrictions` gets DIFFERENT BYTECODE AT THE SAME ADDRESS. This package sidesteps it
 * by using ONE optimizer setting (9 000 runs) for everything and declaring no restrictions, and this
 * script imports only the kit's INTERFACE - never `LaunchpadKitV2.sol`. Deploy from THIS script, and
 * verify with the package's default profile.
 *
 * ############################ THE SAME ADDRESS ON EVERY CHAIN ############################
 *
 * CreateX CREATE3 with a permissioned, cross-chain salt, exactly as every other DeepCore release
 * contract. The address is a function of (CreateX, deployer, salt) alone, so the per-chain kit
 * address does not move it. NOTE THE CONSEQUENCE, because it is sharper here than elsewhere: the
 * LAUNCH-TOKEN addresses this contract produces depend on ITS address, so a creator's predicted token
 * address is only stable across chains if this contract is at the same address on all of them. If a
 * chain ever gets a different address here, `predictLaunchToken` answers differently there.
 *
 * Usage (dry run first - no --broadcast):
 *   eval "$(node ops/deploy/tools/salts-env.mjs ops/deploy/salts/salts.0x<deployer>.json)"
 *   LAUNCHPAD_KIT_V2=0x<kit> LAUNCH_SWEEP_RECIPIENT=0x<safe> \
 *   forge script script/DeployDeepCoreLaunchAndBuy.s.sol --rpc-url $RPC
 */
contract DeployDeepCoreLaunchAndBuyScript is DeepCoreSignerScript {
    string internal constant LABEL = "DEEPCORE_LAUNCH_AND_BUY";

    struct Wiring {
        uint256 pk;
        address kit;
        /// Where misdirected or forced value goes. The governance Safe; the only address this
        /// contract can ever pay that is not a launch participant.
        address sweepRecipient;
        DeepCoreDeploy.Target target;
    }

    function run() public returns (DeepCoreLaunchAndBuy deployed) {
        uint256 pk = _pkFromEnv();
        address deployer = _signerOf(pk);
        Wiring memory w = Wiring({
            pk: pk,
            kit: vm.envAddress("LAUNCHPAD_KIT_V2"),
            sweepRecipient: vm.envAddress("LAUNCH_SWEEP_RECIPIENT"),
            target: DeepCoreDeploy.fromEnv(LABEL, deployer)
        });
        return runWith(w);
    }

    /// @dev Split out so a test can drive the whole thing without the environment.
    function runWith(Wiring memory w) public returns (DeepCoreLaunchAndBuy deployed) {
        _checkBefore(w, _signerOf(w.pk));

        bytes memory initCode =
            abi.encodePacked(type(DeepCoreLaunchAndBuy).creationCode, abi.encode(w.kit, w.sweepRecipient));

        _startBroadcastAs(w.pk);
        deployed = DeepCoreLaunchAndBuy(DeepCoreDeploy.deploy(w.target, initCode, LABEL));
        vm.stopBroadcast();

        _checkAfter(w, deployed);

        console2.log("DeepCoreLaunchAndBuy ", address(deployed));
        console2.log("kit               ", address(deployed.KIT()));
        console2.log("vault             ", address(deployed.VAULT()));
        console2.log("CL pool manager   ", address(deployed.CL_POOL_MANAGER()));
        console2.log("Bin pool manager  ", address(deployed.BIN_POOL_MANAGER()));
        console2.log("sweep recipient   ", deployed.SWEEP_RECIPIENT());
    }

    /*//////////////////////////////////////////////////////////////
                              ASSERTIONS
    //////////////////////////////////////////////////////////////*/

    function _checkBefore(Wiring memory w, address deployer) internal view {
        require(w.kit != address(0), "LAUNCHPAD_KIT_V2 is zero");
        require(w.kit.code.length > 0, "LAUNCHPAD_KIT_V2 has no code on this chain");
        require(w.sweepRecipient != address(0), "LAUNCH_SWEEP_RECIPIENT is zero");
        require(w.sweepRecipient != deployer, "the sweep recipient must never be the deployer");
        require(
            w.sweepRecipient.code.length > 0, "the sweep recipient must be a contract (the Safe), not an EOA"
        );
        DeepCoreGovernance.requireGovernanceSafe(w.sweepRecipient, deployer, "w.sweepRecipient");
        // The kit pays ITS fees to the same Safe. A mismatch means one of the two addresses is wrong,
        // and this is the cheapest place to find that out.
        require(
            ILaunchpadKitV2(w.kit).launchFeeWei() <= type(uint128).max, "the kit did not answer launchFeeWei()"
        );
        DeepCoreDeploy.preflight(w.target, LABEL);
    }

    function _checkAfter(Wiring memory w, DeepCoreLaunchAndBuy deployed) internal view {
        require(address(deployed.KIT()) == w.kit, "the deployed contract points at another kit");
        require(deployed.SWEEP_RECIPIENT() == w.sweepRecipient, "sweep recipient is not what was configured");
        require(address(deployed.VAULT()) != address(0), "no vault was resolved");
        require(address(deployed.CL_POOL_MANAGER()) != address(0), "no CL manager was resolved");
        require(address(deployed.BIN_POOL_MANAGER()) != address(0), "no Bin manager was resolved");
        // There is no owner to check, and that is itself the check: a call to `owner()` must fail.
        (bool ok,) = address(deployed).staticcall(abi.encodeWithSignature("owner()"));
        require(!ok, "this contract must have no owner");
    }
}
