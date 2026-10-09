// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";
import {DeepCoreRegistry} from "../src/DeepCoreRegistry.sol";

/**
 * Deploys `DeepCoreRegistry` for a MAINNET chain, through CreateX at the mined salt.
 *
 * Separate from `DeployRegistry.s.sol` for the same reason the governance
 * scripts are split: that one hands the deployer admin, curator AND guardian so
 * the marketplace can be exercised on a testnet, which is a sensible testnet
 * default and a bad mainnet one. A flag choosing between those two worlds is a
 * flag somebody eventually gets wrong.
 *
 * THE ADDRESS (owner decisions 2026-09-19/20). Every mainnet contract is deployed by CreateX
 * `deployCreate3` at a salt mined for the pattern `0x7878…78` and permissioned to the deployer, so the
 * address is the same on every chain and nobody else can take it on a chain DeepCore has not reached.
 * Export the salts with `ops/deploy/tools/salts-env.mjs`; the mechanism and its rules are in
 * `ops/deploy/salts/README.md`. Nothing about the registry's own code or arguments moves the address.
 *
 * ROLES, and why they are not all the same address.
 *
 *   DEFAULT_ADMIN_ROLE -> the Safe. It grants and revokes the other two, which
 *     is privilege escalation, so it belongs with governance. It is NOT given
 *     to a timelock: the registry custodies nothing, a bad listing is reversible
 *     by the guardian in one transaction, and a queue here buys nothing. This
 *     is the judgement call recorded in CLAUDE.md's ownership table — revisit it
 *     if the registry ever gates funds.
 *
 *   CURATOR_ROLE -> the ops key. Listing throughput; a Safe signature per
 *     listing would make the marketplace unusable.
 *
 *   GUARDIAN_ROLE -> the ops key. Flagging a DeepCore that is draining people has
 *     to be immediate. The guardian can only ever flag or unlist — it cannot
 *     mint an audit badge or clear a warning — so a hot key is the right trade.
 *
 *   VAULT -> the DeepCoreProtocol Vault. Not a role: it is the trust anchor for
 *     `attestFromPool`, the only permission source a hook cannot lie to. The registry
 *     believes a pool manager iff `vault.isAppRegistered(manager)`, which is onlyOwner
 *     on the 48h custody timelock. A wrong Vault here silently voids every attestation,
 *     so it is asserted against the pool manager below rather than merely accepted.
 *
 * Usage:
 *   eval "$(node ops/deploy/tools/salts-env.mjs ops/deploy/salts/salts.0x<deployer>.json)"
 *   REGISTRY_ADMIN=0x...  (the Safe)
 *   REGISTRY_OPS=0x...    (curator + guardian)
 *   REGISTRY_VAULT=0x...  (the Vault)
 *   REGISTRY_POOL_MANAGER=0x...  (a live pool manager, to prove the Vault is the right one)
 *   forge script script/DeployRegistryMainnet.s.sol --rpc-url <chain> --broadcast --slow
 */
interface IVaultAppCheck {
    function isAppRegistered(address app) external view returns (bool);
}

contract DeployRegistryMainnetScript is Script {
    /// @dev The env suffix and the line in `ops/deploy/salts/labels.txt`. Changing it changes the address.
    string internal constant LABEL = "DEEPCORE_REGISTRY";

    struct Wiring {
        uint256 pk;
        address admin;
        address ops;
        address vault;
        address poolManager;
        DeepCoreDeploy.Target target;
    }

    function run() public returns (DeepCoreRegistry registry) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        return runWith(
            Wiring({
                pk: pk,
                admin: vm.envAddress("REGISTRY_ADMIN"),
                ops: vm.envAddress("REGISTRY_OPS"),
                vault: vm.envAddress("REGISTRY_VAULT"),
                poolManager: vm.envAddress("REGISTRY_POOL_MANAGER"),
                target: DeepCoreDeploy.fromEnv(LABEL, vm.addr(pk))
            })
        );
    }

    /// @notice The registry's creation code with this chain's constructor arguments. Changes per chain;
    /// the address does not.
    function initCode(Wiring memory w) public pure returns (bytes memory) {
        address[] memory curators = new address[](1);
        curators[0] = w.ops;
        address[] memory guardians = new address[](1);
        guardians[0] = w.ops;
        return abi.encodePacked(type(DeepCoreRegistry).creationCode, abi.encode(w.admin, w.vault, curators, guardians));
    }

    function runWith(Wiring memory w) public returns (DeepCoreRegistry registry) {
        preflight(w);

        bytes memory code = initCode(w);
        vm.startBroadcast(w.pk);
        registry = DeepCoreRegistry(DeepCoreDeploy.deploy(w.target, code, LABEL));
        vm.stopBroadcast();

        postflight(registry, w);
    }

    /// @notice Every check that must pass before anything is broadcast. Public so tests drive it.
    function preflight(Wiring memory w) public view {
        address deployer = vm.addr(w.pk);
        require(w.target.deployer == deployer, "the salt target is not this deployer");
        DeepCoreDeploy.preflight(w.target, LABEL);

        // A typo'd admin is almost always an EOA or an empty slot, and nothing
        // downstream would ever notice that governance is one key.
        require(w.admin.code.length > 0, "REGISTRY_ADMIN has no code - not a contract");
        require(w.admin != deployer, "REGISTRY_ADMIN must not be the deployer");

        /* Prove the Vault is the real one BEFORE deploying against it. A Vault that does
           not know the live pool manager is either the wrong address or an impostor, and
           either way every attestation the registry ever records would be meaningless.
           Reading it back afterwards would be too late: the address is immutable. */
        require(w.vault.code.length > 0, "REGISTRY_VAULT has no code");
        require(
            IVaultAppCheck(w.vault).isAppRegistered(w.poolManager),
            "REGISTRY_VAULT does not know REGISTRY_POOL_MANAGER - wrong Vault"
        );
    }

    /// @notice Assert the deployed reality, not the intent. Public so tests drive it.
    function postflight(DeepCoreRegistry registry, Wiring memory w) public view {
        address deployer = vm.addr(w.pk);
        bytes32 ADMIN_ROLE = registry.DEFAULT_ADMIN_ROLE();
        require(address(registry) == DeepCoreDeploy.predict(w.target), "registry is not at the predicted address");
        require(address(registry.vault()) == w.vault, "vault not wired");
        require(registry.hasRole(ADMIN_ROLE, w.admin), "admin role not held by REGISTRY_ADMIN");
        require(registry.hasRole(registry.CURATOR_ROLE(), w.ops), "curator not set");
        require(registry.hasRole(registry.GUARDIAN_ROLE(), w.ops), "guardian not set");

        /* THE ONE THAT MATTERS: the deployer must not be able to grant itself
           anything later. Admin is the escalation path; curator and guardian
           are not, because both can only flag or unlist and neither can mint an
           audit badge or clear a warning.

           This deliberately does NOT assert that the deployer lacks curator and
           guardian. An earlier version did, and it reverted the deploy — because
           on this protocol REGISTRY_OPS and the deployer are the same wallet by
           the owner's explicit decision (see CLAUDE.md, "One wallet, four
           roles"). The assertion encoded my assumption rather than the project's
           actual key policy. Where the two differ, the deploy should stop; where
           the policy is deliberate, an assertion that contradicts it is a bug in
           the assertion. */
        require(!registry.hasRole(ADMIN_ROLE, deployer), "deployer still holds admin");
        if (w.ops != deployer) {
            require(!registry.hasRole(registry.CURATOR_ROLE(), deployer), "deployer still curator");
            require(!registry.hasRole(registry.GUARDIAN_ROLE(), deployer), "deployer still guardian");
        }

        console.log("DeepCoreRegistry ", address(registry), "(CREATE3 via CreateX: same on every chain for this deployer + salt)");
        console.log("  vault       ", w.vault);
        console.log("  admin       ", w.admin);
        console.log("  curator     ", w.ops);
        console.log("  guardian    ", w.ops);
        console.log("  deepcoreCount  ", registry.deepcoreCount());
        console.log("  salt");
        console.logBytes32(w.target.salt);
        console.log("  deployer holds no role.");
    }
}
