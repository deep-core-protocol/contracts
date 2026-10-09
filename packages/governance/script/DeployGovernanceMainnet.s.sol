// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {DeepCoreTimelock} from "../src/DeepCoreTimelock.sol";

/**
 * Deploys THE governance timelock for a MAINNET chain. One, not two.
 *
 * ####################### ONE TIER #######################
 *
 * This script used to deploy a Custody (48h) timelock and a Policy (6h) one. It
 * now deploys only Custody. Everything the ownership table routed through Policy
 * — the protocol fee controller, the registry's `DEFAULT_ADMIN_ROLE`, the RWA
 * hook owners, the position descriptor — is held by the governance Safe directly.
 *
 * The reason is about who a delay is for. A timelock between a multisig and a
 * privileged call is a check on the signers; with one operator there are no other
 * signers to check. What survives that is (a) surviving a stolen key and (b)
 * being a credible base for a tenant who would otherwise fork — and both are
 * about IRREVERSIBLE authority. `Vault.registerApp` cannot be undone at any
 * speed. A fee change can, a registry role grant can, and delaying those costs
 * agility for nothing. Reality had already drifted here: `DEFAULT_ADMIN_ROLE` on
 * the live registry is the Safe, and the deployed Policy timelock holds nothing.
 *
 * `DeepCoreTimelock.Tier.Policy` and `POLICY_MIN_DELAY` are deliberately left intact
 * in the contract. Bringing a second tier back when there is a second signer is
 * then a change to this file, not to a deployed type.
 *
 * ####################### THE CANCELLER #######################
 *
 * `TimelockController` grants `CANCELLER_ROLE` to proposers and nobody else. With
 * the Safe as sole proposer, a 2-of-3 compromise that queues `updateDelay(0)`
 * bought the public 48 hours of VISIBILITY with no party able to act on it — a
 * delay that announces an attack and then executes it. The old version of this
 * script asserted PROPOSER and EXECUTOR and never looked at CANCELLER, which is
 * how the gap survived the first deployment.
 *
 * `GOVERNANCE_CANCELLER` is now explicit and is asserted below. It is the right
 * key to hold alone because its only power is refusal: losing it costs nothing a
 * queued `grantRole` cannot restore, and stealing it achieves griefing and
 * nothing else.
 *
 * Separate from `DeployGovernance.s.sol` rather than a flag on it. That script
 * makes the deployer both proposer and executor so a testnet stays iterable — a
 * sensible testnet default and a catastrophic mainnet one, since it reduces the
 * whole governance model to a 48-hour delay on a single key. A boolean argument
 * deciding which of those two worlds you are in is a boolean somebody
 * eventually gets wrong at 2am. Two files, two names, no flag.
 *
 * THE ORDER MATTERS. These must exist BEFORE the Vault, because
 * `01_DeployVault.s.sol` ends with `transferOwnership(config.poolOwner)` — so
 * whatever the chain config names becomes the Vault's owner the instant it is
 * deployed. Deploy these first, paste the addresses into
 * `packages/core/script/config/deepcore-<chain>.json`, and the Vault is never
 * EOA-owned on mainnet, not for a single block. Deploying the Vault first and
 * transferring afterwards leaves a window in which one key can call
 * `registerApp`, which is irreversible.
 *
 * Usage (dry run first — no --broadcast):
 *   GOVERNANCE_SAFE=0x...  GOVERNANCE_CANCELLER=0x... \
 *   forge script script/DeployGovernanceMainnet.s.sol --rpc-url <chain>
 */
contract DeployGovernanceMainnetScript is Script {
    function run() public {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address safe = vm.envAddress("GOVERNANCE_SAFE");
        address canceller = vm.envAddress("GOVERNANCE_CANCELLER");

        /* ---- pre-flight, before anything is broadcast ---------------------
           Each of these has a specific failure it prevents, and each is
           cheaper to hit here than to discover after the timelocks own the
           protocol. There is no unregister, and no way to re-point a timelock
           that was deployed with the wrong proposer — only a redeploy and a
           re-transfer of everything it owns. */

        // A typo'd Safe address is almost always an EOA or an empty slot. If
        // the sole proposer has no code, governance is one private key with
        // extra steps, and nothing downstream would ever notice.
        require(safe.code.length > 0, "GOVERNANCE_SAFE has no code - not a contract");

        // The deployer is a hot key that just held the deployment. It must not
        // also be the thing that proposes.
        require(safe != deployer, "GOVERNANCE_SAFE must not be the deployer");

        /* The canceller is a veto and only a veto, so it does NOT need to be a
           contract — a hot key whose sole failure mode is inaction is exactly the
           right holder. What it must not be is either of the other two: a
           canceller that is the sole proposer cannot veto a compromised proposer,
           and a canceller that is the deployer shares a machine with it. The
           contract rejects zero and rejects a proposer; these two are the ones a
           script is better placed to catch. */
        require(canceller != address(0), "GOVERNANCE_CANCELLER not set - a zero canceller is the old hole");
        require(canceller != safe, "GOVERNANCE_CANCELLER must not be the Safe");
        require(canceller != deployer, "GOVERNANCE_CANCELLER must not be the deployer");

        /* Sole proposer: the Safe. */
        address[] memory proposers = new address[](1);
        proposers[0] = safe;

        /* OPEN EXECUTION, deliberately. OpenZeppelin treats address(0) in the
           executor set as "anyone may execute". Once an operation has survived
           its delay in public there is nothing left to protect — the delay was
           the protection — and an open executor removes the Safe as a liveness
           dependency, so a lost quorum cannot strand a matured operation.

           It is a one-element array rather than an empty one because
           `DeepCoreTimelock` reverts `NoExecutors()` on an empty set: a timelock
           that can queue but never execute is a bricked timelock, and that
           check exists to catch exactly that mistake. */
        address[] memory executors = new address[](1);
        executors[0] = address(0);

        vm.startBroadcast(pk);

        DeepCoreTimelock custody =
            new DeepCoreTimelock(DeepCoreTimelock.Tier.Custody, 48 hours, proposers, executors, canceller);

        vm.stopBroadcast();

        /* ---- post-flight: assert the deployed reality, not the intent ----- */
        bytes32 PROPOSER = custody.PROPOSER_ROLE();
        bytes32 EXECUTOR = custody.EXECUTOR_ROLE();
        bytes32 CANCELLER = custody.CANCELLER_ROLE();
        bytes32 ADMIN = custody.DEFAULT_ADMIN_ROLE();

        require(custody.getMinDelay() == 48 hours, "custody delay wrong");
        require(custody.minDelayFloor() == 48 hours, "custody floor wrong");
        require(custody.hasRole(PROPOSER, safe), "custody: safe is not proposer");

        // The role the first deployment never looked at. Without an independent
        // holder, a compromised Safe queueing `updateDelay(0)` is unopposable.
        require(custody.hasRole(CANCELLER, canceller), "custody: canceller role not granted");
        require(!custody.hasRole(PROPOSER, canceller), "custody: canceller is also a proposer");
        require(!custody.hasRole(EXECUTOR, canceller), "custody: canceller should not need EXECUTOR");

        // The deployer must hold NOTHING. This is the assertion that would have
        // catch a testnet-style deployment, where the deployer is still proposer.
        require(!custody.hasRole(PROPOSER, deployer), "custody: deployer is proposer");
        require(!custody.hasRole(CANCELLER, deployer), "custody: deployer is canceller");
        require(!custody.hasRole(ADMIN, deployer), "custody: deployer is admin");

        // Open execution, confirmed on chain rather than assumed from the input.
        require(custody.hasRole(EXECUTOR, address(0)), "custody: execution not open");

        console.log("");
        console.log("=== Paste this into packages/core/script/config/deepcore-<chain>.json ===");
        console.log('  "poolOwner":                  ', address(custody));
        console.log("");
        console.log("  \"protocolFeeControllerOwner\" is now the SAFE, not a timelock:");
        console.log("                                ", safe);
        console.log("");
        console.log("CUSTODY (48h) ", address(custody));
        console.log("proposer      ", safe);
        console.log("canceller     ", canceller);
        console.log("executor       open - anyone may execute a matured operation");
        console.log("admin          none - the timelock self-administers");
        console.log("");
        console.log("No Policy timelock is deployed. Everything previously marked Policy in the");
        console.log("ownership table is transferred to the Safe DIRECTLY (Ownable2Step: transfer");
        console.log("then accept, the Safe accepting in its own transaction with no queue).");
    }
}
