// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {DeepCoreRegistry} from "../src/DeepCoreRegistry.sol";

/**
 * Deploys the hook registry — the contract backing the marketplace.
 *
 * Role model, deliberately asymmetric:
 *   DEFAULT_ADMIN  only decides who holds the other two roles. On mainnet this MUST
 *                  be the 48h custody DeepCoreTimelock, since granting CURATOR is how a
 *                  bad actor would mint audit badges.
 *   CURATOR        attests in both directions (promote and demote).
 *   GUARDIAN       can ONLY move a listing to a more cautious state. A compromised
 *                  guardian can slander a hook — visible, reversible, costs nobody
 *                  funds — but cannot mint an audit badge or clear a warning.
 *
 * Curators are deliberately NOT timelocked: a six-hour queue on "this hook is
 * draining people" makes the flag useless.
 *
 * TESTNET: deployer holds all three so the marketplace can be exercised.
 *
 * VAULT: the registry believes a pool manager iff this Vault has registered it as an
 * app. That is the trust anchor for `attestFromPool`, which is the only permission
 * source a hook cannot lie to. Point it at the wrong Vault and every attestation
 * becomes worthless, so it is required rather than defaulted.
 *
 *   REGISTRY_VAULT=0x...
 */
contract DeployRegistryScript is Script {
    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address vault = vm.envAddress("REGISTRY_VAULT");
        require(vault.code.length > 0, "REGISTRY_VAULT has no code - not a Vault");

        address[] memory curators = new address[](1);
        curators[0] = deployer;
        address[] memory guardians = new address[](1);
        guardians[0] = deployer;

        vm.startBroadcast(pk);
        DeepCoreRegistry registry = new DeepCoreRegistry(deployer, vault, curators, guardians);
        vm.stopBroadcast();

        require(registry.hasRole(registry.CURATOR_ROLE(), deployer), "curator not set");
        require(registry.hasRole(registry.GUARDIAN_ROLE(), deployer), "guardian not set");
        require(address(registry.vault()) == vault, "vault not wired");

        console.log("DeepCoreRegistry  ", address(registry));
        console.log("  admin            ", deployer);
        console.log("  vault            ", vault);
        console.log("  deepcoreCount        ", registry.deepcoreCount());
    }
}
