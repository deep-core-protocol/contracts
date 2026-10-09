// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";
import {DeepCoreLaunchRegistry} from "../src/DeepCoreLaunchRegistry.sol";

/**
 * Deploys `DeepCoreLaunchRegistry` — the shared index of tokens launched through any DeepCore-based
 * launchpad — through CreateX at the mined salt.
 *
 * ONE SCRIPT, NOT TWO. `DeepCoreRegistry` needs a testnet variant and a mainnet variant because it
 * takes role holders as constructor arguments, and the sensible testnet default (deployer holds
 * everything) is a bad mainnet one. This contract takes NO role holders: it reads `CURATOR_ROLE`
 * and `GUARDIAN_ROLE` off the DeepCore registry, so whichever registry you point it at, its
 * governance is already whatever that registry's governance is. There is nothing here to get
 * wrong differently per environment.
 *
 * THE ADDRESS. CreateX `deployCreate3` at `DEEPCORE_SALT_DEEPCORE_LAUNCH_REGISTRY`, permissioned to the
 * deployer and chain-id free, so it is the same address on every chain (`ops/deploy/salts/README.md`).
 *
 * THE TWO ADDRESSES, and why both are asserted rather than accepted.
 *
 *   REGISTRY_VAULT -> the DeepCoreProtocol Vault. The trust anchor: a pool manager is believed iff
 *     `vault.isAppRegistered(manager)`, which is onlyOwner on the 48h custody timelock. A wrong
 *     Vault here silently voids every pool proof this registry will ever record, and the field is
 *     immutable, so reading it back afterwards is too late.
 *
 *   DEEPCORE_REGISTRY -> the live `DeepCoreRegistry`. Supplies this contract's curator and guardian
 *     roles and receives the hook attestations it forwards.
 *
 * THE ASSERTION THAT MATTERS: the two must share a Vault. A launch registry anchored to Vault A
 * while its DeepCore registry is anchored to Vault B would look completely healthy — every view
 * answers, every role resolves — while attesting pools from one protocol and taking governance
 * from another. That is not a configuration anybody would notice from a block explorer.
 *
 * Usage:
 *   eval "$(node ops/deploy/tools/salts-env.mjs ops/deploy/salts/salts.0x<deployer>.json)"
 *   REGISTRY_VAULT=0x...        (the Vault)
 *   DEEPCORE_REGISTRY=0x...        (the live DeepCoreRegistry)
 *   REGISTRY_POOL_MANAGER=0x... (a live pool manager, to prove the Vault is the right one)
 *   forge script script/DeployLaunchRegistry.s.sol --rpc-url <chain> --broadcast --slow
 */
interface IVaultAppCheck {
    function isAppRegistered(address app) external view returns (bool);
}

interface IDeepCoreRegistryCheck {
    function vault() external view returns (address);
    function CURATOR_ROLE() external view returns (bytes32);
    function GUARDIAN_ROLE() external view returns (bytes32);
    function deepcoreCount() external view returns (uint256);
}

contract DeployLaunchRegistryScript is Script {
    /// @dev The env suffix and the line in `ops/deploy/salts/labels.txt`.
    string internal constant LABEL = "DEEPCORE_LAUNCH_REGISTRY";

    struct Wiring {
        uint256 pk;
        address vault;
        address deepcoreRegistry;
        address poolManager;
        DeepCoreDeploy.Target target;
    }

    function run() public returns (DeepCoreLaunchRegistry registry) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        return runWith(
            Wiring({
                pk: pk,
                vault: vm.envAddress("REGISTRY_VAULT"),
                deepcoreRegistry: vm.envAddress("DEEPCORE_REGISTRY"),
                poolManager: vm.envAddress("REGISTRY_POOL_MANAGER"),
                target: DeepCoreDeploy.fromEnv(LABEL, vm.addr(pk))
            })
        );
    }

    function initCode(Wiring memory w) public pure returns (bytes memory) {
        return abi.encodePacked(type(DeepCoreLaunchRegistry).creationCode, abi.encode(w.vault, w.deepcoreRegistry));
    }

    function runWith(Wiring memory w) public returns (DeepCoreLaunchRegistry registry) {
        preflight(w);

        bytes memory code = initCode(w);
        vm.startBroadcast(w.pk);
        registry = DeepCoreLaunchRegistry(DeepCoreDeploy.deploy(w.target, code, LABEL));
        vm.stopBroadcast();

        postflight(registry, w);
    }

    /// @notice Every check that must pass before anything is broadcast. Public so tests drive it.
    function preflight(Wiring memory w) public view {
        require(w.target.deployer == vm.addr(w.pk), "the salt target is not this deployer");
        DeepCoreDeploy.preflight(w.target, LABEL);

        require(w.vault.code.length > 0, "REGISTRY_VAULT has no code");
        require(w.deepcoreRegistry.code.length > 0, "DEEPCORE_REGISTRY has no code");

        /* Prove the Vault is the real one BEFORE deploying against it. A Vault that does not know
           the live pool manager is either the wrong address or an impostor. */
        require(
            IVaultAppCheck(w.vault).isAppRegistered(w.poolManager),
            "REGISTRY_VAULT does not know REGISTRY_POOL_MANAGER - wrong Vault"
        );

        /* And prove the two registries are anchored to the same protocol. */
        require(IDeepCoreRegistryCheck(w.deepcoreRegistry).vault() == w.vault, "DEEPCORE_REGISTRY is anchored to a different Vault");
    }

    /// @notice Assert the deployed reality, not the intent. Public so tests drive it.
    function postflight(DeepCoreLaunchRegistry registry, Wiring memory w) public view {
        require(address(registry) == DeepCoreDeploy.predict(w.target), "launch registry is not at the predicted address");
        require(address(registry.vault()) == w.vault, "vault not wired");
        require(address(registry.deepcoreRegistry()) == w.deepcoreRegistry, "deepcore registry not wired");
        require(
            registry.CURATOR_ROLE() == IDeepCoreRegistryCheck(w.deepcoreRegistry).CURATOR_ROLE(),
            "curator role hash diverged from the DeepCore registry"
        );
        require(
            registry.GUARDIAN_ROLE() == IDeepCoreRegistryCheck(w.deepcoreRegistry).GUARDIAN_ROLE(),
            "guardian role hash diverged from the DeepCore registry"
        );

        console.log("DeepCoreLaunchRegistry ", address(registry), "(CREATE3 via CreateX: same on every chain)");
        console.log("  vault             ", w.vault);
        console.log("  deepcoreRegistry     ", w.deepcoreRegistry);
        console.log("  deepcores listed    ", IDeepCoreRegistryCheck(w.deepcoreRegistry).deepcoreCount());
        console.log("  launches indexed  ", registry.launchCount());
        console.log("  This contract holds no roles of its own; curation is the DeepCore registry's.");
    }
}
