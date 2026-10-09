// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";

import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";

import {DeepCoreProtocolFeeControllerV2} from "../src/DeepCoreProtocolFeeControllerV2.sol";

interface IManagerView {
    function vault() external view returns (address);
    function owner() external view returns (address);
}

interface IVaultAppView {
    function isAppRegistered(address app) external view returns (bool);
}

/**
 * Deploys `DeepCoreProtocolFeeControllerV2` on a greenfield chain (HyperEVM 999 is the launch chain) —
 * every input from the environment, no address in this file. This is THE V2 deploy script; there is
 * no other.
 *
 * WHY IT MUST RUN BEFORE THE KIT. `DeployLaunchpadKitV2.s.sol` reads `FEE_POLICY_V2` and, when it is
 * set, runs V3's own pre-broadcast checks against the new kit (`checkInputs`): V2 must have code and
 * be owned by the Safe. Deploy V2 here first and export its READ-BACK as `FEE_POLICY_V2`.
 *
 *   owner    = the governance Safe (constructor argument; `Ownable2Step`, renounce reverts)
 *   guardian = the Ops key (may only disable fees; can never collect or raise)
 *   treasury = the owner (constructor default)
 *
 * ADDRESS. Plain CREATE: the address is (deployer, nonce), so it is NOT the same on every chain.
 * V2 has no line in `ops/deploy/salts/labels.txt`; giving it one is an owner decision.
 *
 *   EXPECTED_CHAIN_ID  the chain this run is meant for (999 on HyperEVM) - refuses any other
 *   FEE_OWNER_SAFE     the governance Safe (asserted against DeepCoreGovernance.SAFE on production chains)
 *   OPS                the guardian (Ops key)
 *   CL_POOL_MANAGER / BIN_POOL_MANAGER   this chain's managers (read back, never trusted blind)
 *
 *   forge script script/DeployFeeControllerV2Chain.s.sol --rpc-url $RPC --sender $DEPLOYER            # dry run
 *   forge script script/DeployFeeControllerV2Chain.s.sol --rpc-url $RPC --sender $DEPLOYER --broadcast --slow
 *
 * Afterwards the Safe installs it on BOTH managers through the wrappers
 * (`setProtocolFeeController(v2)` on `CLPoolManagerOwner` and `BinPoolManagerOwner`) — while the Safe
 * still owns the wrappers, i.e. before the custody timelock's `acceptOwnership` executes. After that
 * the install is a 48 h custody operation.
 */
contract DeployFeeControllerV2ChainScript is Script {
    function run() external returns (DeepCoreProtocolFeeControllerV2 controller) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        uint256 expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        address safe = vm.envAddress("FEE_OWNER_SAFE");
        address guardian = vm.envAddress("OPS");
        address clManager = vm.envAddress("CL_POOL_MANAGER");
        address binManager = vm.envAddress("BIN_POOL_MANAGER");

        /* ---- pre-flight ---------------------------------------------------- */
        require(block.chainid == expectedChainId, "EXPECTED_CHAIN_ID does not match the RPC's chain");
        DeepCoreGovernance.requireGovernanceSafe(safe, deployer, "FEE_OWNER_SAFE");
        require(guardian != address(0), "OPS (guardian) unset");
        require(guardian != safe && guardian != deployer, "guardian must be the Ops key, not the Safe or the deployer");

        /* The managers are only read here, but a wrong pair means the post-deploy install batch is
           built against the wrong contracts: prove they are this chain's DeepCore managers first. */
        require(clManager.code.length > 0 && binManager.code.length > 0, "a pool manager has no code on this chain");
        address vault = IManagerView(clManager).vault();
        require(vault == IManagerView(binManager).vault(), "CL and Bin managers use different Vaults");
        require(
            IVaultAppView(vault).isAppRegistered(clManager) && IVaultAppView(vault).isAppRegistered(binManager),
            "a pool manager is not registered on its Vault"
        );

        console.log("=== DEPLOY DeepCoreProtocolFeeControllerV2 (chain-generic) ===");
        console.log("  chain id  ", block.chainid);
        console.log("  deployer  ", deployer);
        console.log("  owner     ", safe, "(set in the constructor, never transferred)");
        console.log("  guardian  ", guardian);

        vm.startBroadcast(pk);
        controller = new DeepCoreProtocolFeeControllerV2(safe, guardian);
        vm.stopBroadcast();

        /* ---- post-flight: read every constructor argument back, plus renounce ---- */
        require(controller.owner() == safe, "owner is not the Safe");
        require(controller.pendingOwner() == address(0), "unexpected pending owner");
        require(controller.guardian() == guardian, "guardian mismatch");
        require(controller.treasury() == safe, "treasury is not the Safe");
        require(controller.protocolFeeSplitRatio() == 250_000, "split ratio is not 25%");
        require(controller.feeForLpFee(3000) == 999, "0.30% tier is not 999 pips");
        require(controller.DYNAMIC_FEE_PIPS() == 999 && controller.MAX_PROTOCOL_FEE() == 4000, "constants moved");
        try controller.renounceOwnership() {
            revert("renounceOwnership did not revert");
        } catch {}

        console.log("");
        console.log("=== DEPLOYED, NOT INSTALLED ===");
        console.log("  V2       ", address(controller));
        uint24[5] memory tiers = [uint24(100), 500, 2500, 3000, 10000];
        for (uint256 i = 0; i < tiers.length; i++) {
            console.log("  lpFee", tiers[i], "-> protocol", controller.feeForLpFee(tiers[i]));
        }
        console.log("Install: Safe -> setProtocolFeeController(V2) on both wrappers, BEFORE custody owns them.");
        console.log("  CL  manager ", clManager, "owner", IManagerView(clManager).owner());
        console.log("  BIN manager ", binManager, "owner", IManagerView(binManager).owner());
    }
}
