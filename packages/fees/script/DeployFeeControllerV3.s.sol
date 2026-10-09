// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";

import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";

import {DeepCoreProtocolFeeControllerV3} from "../src/DeepCoreProtocolFeeControllerV3.sol";
import {ILockedLaunchOracle} from "../src/interfaces/ILockedLaunchOracle.sol";

interface IV2Identity {
    function owner() external view returns (address);
    function DYNAMIC_FEE_PIPS() external view returns (uint16);
    function DEFAULT_SPLIT_RATIO() external view returns (uint256);
    function MAX_PROTOCOL_FEE() external view returns (uint16);
}

/**
 * The V3 pre-broadcast checks, as a library with an INTERNAL function, so any script that needs them
 * (this one, and the kit's deploy script, which runs them against the kit it has just deployed) gets
 * the same code INLINED.
 *
 * WHY NOT `new DeployFeeControllerV3Script().checkInputs(...)`, which is what the kit's script did until
 * 2026-10-09: with forge 1.8.1, on every OP-stack chain (Base, Ink, Optimism) a CREATE made by the script
 * contract itself returns address(0) when forge runs under its default sender. CREATE2, and any creation
 * under a named `--sender`, work; so do all other chains. It stopped the kit's deployment on Base and Ink
 * in rehearsal, before anything was broadcast. A deploy script must not depend on the script contract
 * being able to create another contract: share code through a library instead.
 */
library FeeControllerV3Checks {
    function checkInputs(address safe, address policy, address kit) internal view {
        require(safe != address(0) && policy != address(0) && kit != address(0), "zero address input");
        require(safe.code.length > 0, "owner must be the Safe contract, not an EOA");
        require(policy.code.length > 0, "policy has no code");
        require(kit.code.length > 0, "kit has no code");
        require(kit != policy && kit != safe && policy != safe, "inputs must be three distinct contracts");

        IV2Identity v2 = IV2Identity(policy);
        require(v2.owner() == safe, "V2 is not owned by the Safe: V3 would compose over foreign policy");
        require(v2.DYNAMIC_FEE_PIPS() == 999, "policy is not DeepCoreProtocolFeeControllerV2 (DYNAMIC_FEE_PIPS)");
        require(v2.DEFAULT_SPLIT_RATIO() == 250_000, "policy is not DeepCoreProtocolFeeControllerV2 (split)");
        require(v2.MAX_PROTOCOL_FEE() == 4000, "policy is not DeepCoreProtocolFeeControllerV2 (cap)");

        (bool ok, bytes memory ret) =
            kit.staticcall(abi.encodeCall(ILockedLaunchOracle.isLockedLaunch, (bytes32(0))));
        require(ok && ret.length == 32 && uint256(bytes32(ret)) == 0, "kit does not implement isLockedLaunch");

        /* Kit v2's owner is the Safe (Kit v2 decisions #1). A kit governed by anyone else is a
           tenant's kit, and the protocol's zero-fee rule must not be bound to it. */
        (ok, ret) = kit.staticcall(abi.encodeWithSignature("owner()"));
        require(ok && ret.length == 32, "kit has no owner(): not LaunchpadKit v2");
        require(abi.decode(ret, (address)) == safe, "kit is not owned by the Safe: not DeepCore's kit");
    }
}

/**
 * Deploys DeepCoreProtocolFeeControllerV3. Design: packages/fees/docs/controller-v3.md.
 *
 * INERT UNTIL INSTALLED. Deploying this changes no pool's fee. It prices nothing until the custody
 * timelock executes `setProtocolFeeController(V3)` on both pool-manager owner wrappers, a 48h
 * operation whose calldata `BuildInstallFeeControllerV3.s.sol` prints.
 *
 * OWNERSHIP, per the CLAUDE.md table (`DeepCoreProtocolFeeController` owner = Safe): set in the
 * constructor, never transferred, so the deployer key never holds it. V3 has no guardian; the
 * Ops guardian stays on V2, where it can only disable fees.
 *
 * THE ADDRESS. CreateX `deployCreate3` at `DEEPCORE_SALT_DEEPCORE_FEE_CONTROLLER_V3`, mined for the deployer
 * and chain-id free, so V3 has the same `0x7878…78` address on every chain even though its policy and
 * kit arguments differ per chain (`ops/deploy/salts/README.md`). Note what that does NOT mean: the
 * controller is still inert until a custody batch installs it on that chain's wrappers.
 *
 * Every input comes from the environment and is checked on chain BEFORE broadcasting; every
 * immutable is read back AFTER. On every production chain the Safe must be the governance Safe of
 * record (`DeepCoreGovernance`; refused while it is unset).
 *
 *   PRIVATE_KEY        deployer (gas only)
 *   FEE_OWNER_SAFE     governance Safe
 *   FEE_POLICY_V2      live DeepCoreProtocolFeeControllerV2
 *   LAUNCHPAD_KIT_V2   the LaunchpadKit v2 deployment - never an adapter
 *
 *   eval "$(node ops/deploy/tools/salts-env.mjs ops/deploy/salts/salts.0x<deployer>.json)"
 *   forge script script/DeployFeeControllerV3.s.sol --rpc-url $RPC            # dry run
 *   forge script script/DeployFeeControllerV3.s.sol --rpc-url $RPC --broadcast --slow
 */
contract DeployFeeControllerV3Script is Script {
    string internal constant LABEL = "DEEPCORE_FEE_CONTROLLER_V3";

    function run() external returns (DeepCoreProtocolFeeControllerV3 controller) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address safe = vm.envAddress("FEE_OWNER_SAFE");
        address policy = vm.envAddress("FEE_POLICY_V2");
        address kit = vm.envAddress("LAUNCHPAD_KIT_V2");
        return runWith(pk, safe, policy, kit, DeepCoreDeploy.fromEnv(LABEL, vm.addr(pk)));
    }

    /// @notice The controller's creation code with this chain's constructor arguments.
    function initCode(address safe, address policy, address kit) public pure returns (bytes memory) {
        return abi.encodePacked(
            type(DeepCoreProtocolFeeControllerV3).creationCode,
            abi.encode(safe, IProtocolFeeController(policy), kit)
        );
    }

    /// @dev Environment in `run`, logic here, so a test drives the exact code that gates a deploy.
    function runWith(uint256 pk, address safe, address policy, address kit, DeepCoreDeploy.Target memory target)
        public
        returns (DeepCoreProtocolFeeControllerV3 controller)
    {
        // Every production chain - see DeepCoreGovernance. `checkInputs` proves the policy IS a
        // DeepCoreProtocolFeeControllerV2 owned by this Safe (deployed by DeployFeeControllerV2Chain).
        DeepCoreGovernance.requireGovernanceSafe(safe, vm.addr(pk), "FEE_OWNER_SAFE");

        require(target.deployer == vm.addr(pk), "the salt target is not this deployer");
        DeepCoreDeploy.preflight(target, LABEL);
        checkInputs(safe, policy, kit);

        console.log("=== DEPLOY DeepCoreProtocolFeeControllerV3 ===");
        console.log("  deployer     ", vm.addr(pk));
        console.log("  owner        ", safe);
        console.log("  policy (V2)  ", policy);
        console.log("  launchOracle ", kit);
        console.log("  will deploy to", DeepCoreDeploy.predict(target), "(CREATE3 via CreateX)");

        bytes memory code = initCode(safe, policy, kit);
        vm.startBroadcast(pk);
        controller = DeepCoreProtocolFeeControllerV3(DeepCoreDeploy.deploy(target, code, LABEL));
        vm.stopBroadcast();

        require(address(controller) == DeepCoreDeploy.predict(target), "V3 is not at the predicted address");
        verifyDeployment(controller, safe, policy, kit);

        console.log("");
        console.log("=== DEPLOYED, NOT INSTALLED ===");
        console.log("  V3 ", address(controller));
        console.log("Next: FEE_CONTROLLER_V3=<V3> forge script script/BuildInstallFeeControllerV3.s.sol --rpc-url $RPC");
    }

    /// @notice Pre-broadcast checks. Public so the test suite exercises the exact code that gates a deploy.
    function checkInputs(address safe, address policy, address kit) public view {
        FeeControllerV3Checks.checkInputs(safe, policy, kit);
    }

    /// @notice Post-broadcast read-back of every immutable and every ownership claim.
    function verifyDeployment(DeepCoreProtocolFeeControllerV3 c, address safe, address policy, address kit)
        public
        view
    {
        require(address(c).code.length > 0, "no code at V3");
        require(c.owner() == safe, "owner is not the Safe");
        require(c.pendingOwner() == address(0), "unexpected pending owner");
        require(address(c.policy()) == policy, "policy immutable mismatch");
        require(c.launchOracle() == kit, "launchOracle immutable mismatch");
        require(c.treasury() == safe, "treasury is not the Safe");
        require(c.LAUNCH_ORACLE_GAS() == 50_000, "oracle stipend changed");

        /* V3 must agree with V2 on a pool the kit never created. */
        PoolKey memory probe = PoolKey({
            currency0: Currency.wrap(address(0x1)),
            currency1: Currency.wrap(address(0x2)),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(0x3)),
            fee: 3000,
            parameters: bytes32(uint256(60) << 16)
        });
        require(
            c.protocolFeeForPool(probe) == IProtocolFeeController(policy).protocolFeeForPool(probe),
            "V3 disagrees with V2 on a non-launch pool"
        );
        probe.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        probe.hooks = IHooks(address(0x4));
        require(
            c.protocolFeeForPool(probe) == IProtocolFeeController(policy).protocolFeeForPool(probe),
            "V3 disagrees with V2 on a non-launch dynamic pool"
        );

        try c.renounceOwnership() {
            revert("renounceOwnership did not revert");
        } catch {}
    }
}
