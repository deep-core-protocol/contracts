// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {DeepCoreTimelock} from "../src/DeepCoreTimelock.sol";

/**
 * TESTNET rehearsal deployment. Deploys BOTH tiers on purpose — see below.
 *
 *   CUSTODY (48h) — owns Vault and the pool managers. `Vault.registerApp` is
 *     onlyOwner and IRREVERSIBLE; there is no unregister anywhere in the Vault or
 *     its interface. A registered app can move funds against the Vault forever, so
 *     the only real defence is a window long enough for the public to notice.
 *
 *   POLICY (6h) — retained here, and DELIBERATELY NOT DEPLOYED ON MAINNET.
 *     `DeployGovernanceMainnet.s.sol` deploys Custody only; everything the
 *     ownership table used to route through Policy is held by the Safe directly,
 *     because a delay on a reversible action is a check on co-signers that a
 *     single operator does not have. The tier stays exercised here so that
 *     bringing it back — when there is a team — is a script change against code
 *     that is known to work, rather than an untested path.
 *
 * TESTNET ONLY, enforced: on any chain that is not a local dev chain or a known public testnet
 * (the same exclusion list as `DeepCoreGovernance.isProductionChain`) this script refuses and points
 * at `DeployGovernanceMainnet.s.sol`, which requires an explicit GOVERNANCE_CANCELLER and a Safe.
 *
 * TESTNET: the deployer is proposer and executor so a testnet stays iterable.
 * MAINNET: the proposer MUST be a Safe multisig. Executors may be left open —
 * once an operation has survived its delay in public, anyone executing it is
 * harmless, and it removes the multisig as a liveness dependency.
 *
 * On a testnet these are deployed but NOT wired as owners. Handing the Vault to a
 * 48h timelock on a testnet makes iteration miserable; the wiring is a mainnet step.
 * Deploying them now means the governance model is real code at a real address that
 * can be exercised, rather than a diagram.
 */
contract DeployGovernanceScript is Script {
    /// @notice Local dev chains and public testnets - the only chains this script runs on. Mirrors the
    /// skip list in `packages/hooks/script/DeepCoreGovernance.sol` (not imported: this package has no
    /// `deepcore-hooks/` remapping).
    function isTestChain(uint256 chainId) public pure returns (bool) {
        return chainId == 31337 || chainId == 1337 || chainId == 1338 || chainId == 998 || chainId == 11155111 || chainId == 84532
            || chainId == 2201 || chainId == 5042002;
    }

    function run() public {
        require(
            isTestChain(block.chainid),
            "DeployGovernance is a TESTNET script: use DeployGovernanceMainnet.s.sol (explicit GOVERNANCE_CANCELLER, a Safe proposer)"
        );
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        address[] memory proposers = new address[](1);
        proposers[0] = deployer;
        address[] memory executors = new address[](1);
        executors[0] = deployer;

        /* The canceller must not be a proposer, which the constructor enforces, so a
           testnet run needs a second address. `GOVERNANCE_CANCELLER` if one is set,
           otherwise a deterministic throwaway — this is a testnet script (enforced
           above) and the point is to exercise the role's existence, not to secure it.
           Production never reaches this fallback. */
        address canceller = vm.envOr("GOVERNANCE_CANCELLER", address(uint160(uint256(keccak256("deepcore.testnet.canceller")))));
        require(canceller != deployer, "GOVERNANCE_CANCELLER must not be the deployer");

        vm.startBroadcast(pk);

        DeepCoreTimelock custody =
            new DeepCoreTimelock(DeepCoreTimelock.Tier.Custody, 48 hours, proposers, executors, canceller);
        DeepCoreTimelock policy =
            new DeepCoreTimelock(DeepCoreTimelock.Tier.Policy, 6 hours, proposers, executors, canceller);

        vm.stopBroadcast();

        // Prove the floors are live, not just compiled.
        require(custody.getMinDelay() == 48 hours, "custody delay wrong");
        require(policy.getMinDelay() == 6 hours, "policy delay wrong");
        require(!custody.hasRole(custody.DEFAULT_ADMIN_ROLE(), deployer), "deployer must not be admin");
        require(custody.hasRole(custody.CANCELLER_ROLE(), canceller), "canceller role not granted");

        console.log("DeepCoreTimelock CUSTODY ", address(custody));
        console.log("  minDelay (s)        ", custody.getMinDelay());
        console.log("  floor    (s)        ", custody.minDelayFloor());
        console.log("DeepCoreTimelock POLICY  ", address(policy));
        console.log("  minDelay (s)        ", policy.getMinDelay());
        console.log("  floor    (s)        ", policy.minDelayFloor());
        console.log("");
        console.log("No external admin holds DEFAULT_ADMIN_ROLE - the timelocks self-administer.");
    }
}
