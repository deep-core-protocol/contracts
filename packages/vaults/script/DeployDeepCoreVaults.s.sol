// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";

import {DeepCoreDeploy} from "deepcore-hooks/script/DeepCoreCreateX.sol";
import {DeepCoreGovernance} from "deepcore-hooks/script/DeepCoreGovernance.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {DeepCoreManagedVault} from "../src/DeepCoreManagedVault.sol";
import {DeepCoreVaultFactory} from "../src/DeepCoreVaultFactory.sol";

/**
 * Deploys the managed-vault implementation and `DeepCoreVaultFactory`, both through CreateX `deployCreate3`
 * (same address on every chain), the factory owned by the governance Safe from birth.
 *
 * ORDER. The implementation stores its factory as an immutable, so it is deployed FIRST with the factory's
 * PREDICTED address (CREATE3 addresses depend only on deployer and salt); the factory's constructor then
 * refuses an implementation that does not name it.
 *
 * ############################ WHAT CANNOT BE UNDONE ############################
 * The fee recipient (the Safe), the creation-fee cap, the performance-fee cap, the notice and the
 * implementation. Only the two VALUES move, by the Safe, inside the caps.
 *
 * THE DECISION (owner, 2026-10-12): performance fee 10% (1,000 bps) of harvested LP fees, immutable cap 20%
 * (2,000 bps); a flat creation fee of 0.075 ETH-equivalent in native (as the utilities), cap 10x; 7-day
 * notice. Asserted on every production chain. The fee is wei; any dollar figure is converted OFF CHAIN.
 *
 * Usage (dry run first - no --broadcast):
 *   eval "$(node ops/deploy/tools/salts-env.mjs ops/deploy/salts/salts.0x<deployer>.json)"
 *   VAULTS_OWNER_SAFE=<Safe> CL_POOL_MANAGER=<manager> VAULTS_FEE_WEI=<wei> VAULTS_FEE_CAP_WEI=<10x> \
 *   VAULTS_PERF_BPS=1000 VAULTS_PERF_CAP_BPS=2000 VAULTS_NOTICE_SECONDS=604800 \
 *   forge script script/DeployDeepCoreVaults.s.sol --rpc-url $RPC
 */
contract DeployDeepCoreVaultsScript is Script {
    uint32 internal constant MAINNET_NOTICE_SECONDS = 7 days;
    uint16 internal constant DECIDED_PERF_BPS = 1_000;
    uint16 internal constant DECIDED_PERF_CAP_BPS = 2_000;

    string internal constant IMPL_LABEL = "DEEPCORE_MANAGED_VAULT_IMPL";
    string internal constant FACTORY_LABEL = "DEEPCORE_VAULT_FACTORY";

    struct Wiring {
        uint256 pk;
        address safe;
        ICLPoolManager clPoolManager;
        uint256 feeWei;
        uint256 feeCapWei;
        uint16 perfBps;
        uint16 perfCapBps;
        uint32 noticeSeconds;
        DeepCoreDeploy.Target implTarget;
        DeepCoreDeploy.Target factoryTarget;
    }

    function run() public returns (DeepCoreVaultFactory factory) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        return runWith(
            Wiring({
                pk: pk,
                safe: vm.envAddress("VAULTS_OWNER_SAFE"),
                clPoolManager: ICLPoolManager(vm.envAddress("CL_POOL_MANAGER")),
                feeWei: vm.envUint("VAULTS_FEE_WEI"),
                feeCapWei: vm.envUint("VAULTS_FEE_CAP_WEI"),
                perfBps: uint16(vm.envOr("VAULTS_PERF_BPS", uint256(DECIDED_PERF_BPS))),
                perfCapBps: uint16(vm.envOr("VAULTS_PERF_CAP_BPS", uint256(DECIDED_PERF_CAP_BPS))),
                noticeSeconds: uint32(vm.envOr("VAULTS_NOTICE_SECONDS", uint256(MAINNET_NOTICE_SECONDS))),
                implTarget: DeepCoreDeploy.fromEnv(IMPL_LABEL, deployer),
                factoryTarget: DeepCoreDeploy.fromEnv(FACTORY_LABEL, deployer)
            })
        );
    }

    function implInitCode(Wiring memory w) public pure returns (bytes memory) {
        return abi.encodePacked(
            type(DeepCoreManagedVault).creationCode,
            abi.encode(DeepCoreDeploy.predict(w.factoryTarget), address(w.clPoolManager))
        );
    }

    function factoryInitCode(Wiring memory w) public pure returns (bytes memory) {
        return abi.encodePacked(
            type(DeepCoreVaultFactory).creationCode,
            abi.encode(
                DeepCoreDeploy.predict(w.implTarget),
                w.safe,
                w.safe,
                w.feeWei,
                w.feeCapWei,
                w.noticeSeconds,
                w.perfBps,
                w.perfCapBps
            )
        );
    }

    function runWith(Wiring memory w) public returns (DeepCoreVaultFactory factory) {
        preflight(w);
        bytes memory implCode = implInitCode(w);
        bytes memory factoryCode = factoryInitCode(w);
        vm.startBroadcast(w.pk);
        DeepCoreDeploy.deploy(w.implTarget, implCode, IMPL_LABEL);
        factory = DeepCoreVaultFactory(payable(DeepCoreDeploy.deploy(w.factoryTarget, factoryCode, FACTORY_LABEL)));
        vm.stopBroadcast();
        postflight(factory, w);

        console.log("=== DeepCoreVaultFactory ===");
        console.log("  chain id         ", block.chainid);
        console.log("  factory          ", address(factory));
        console.log("  implementation   ", factory.implementation());
        console.log("  owner/recipient  ", w.safe);
        console.log("  fee (wei)        ", w.feeWei);
        console.log("  perf fee (bps)   ", w.perfBps);
        console.log("  NEXT: record `vaultFactory` in @deepcoreprotocol/sdk deployments after read-back, and the fee quote.");
    }

    /// @notice Every check that must pass before anything is broadcast. Public so tests drive it.
    function preflight(Wiring memory w) public view {
        address deployer = vm.addr(w.pk);
        require(w.implTarget.deployer == deployer && w.factoryTarget.deployer == deployer, "salt target is not this deployer");
        DeepCoreDeploy.preflight(w.implTarget, IMPL_LABEL);
        DeepCoreDeploy.preflight(w.factoryTarget, FACTORY_LABEL);

        if (DeepCoreGovernance.isProductionChain(block.chainid)) {
            require(w.noticeSeconds == MAINNET_NOTICE_SECONDS, "VAULTS_NOTICE_SECONDS is not 7 days on mainnet");
            require(w.perfBps == DECIDED_PERF_BPS, "VAULTS_PERF_BPS is not the decided 1000 bps");
            require(w.perfCapBps == DECIDED_PERF_CAP_BPS, "VAULTS_PERF_CAP_BPS is not the decided 2000 bps");
            require(w.feeWei > 0 && w.feeCapWei == w.feeWei * 10, "VAULTS_FEE_CAP_WEI must be 10x a non-zero VAULTS_FEE_WEI");
        }
        require(w.safe != address(0) && w.safe.code.length > 0, "VAULTS_OWNER_SAFE must be a deployed Safe");
        require(w.safe != deployer, "VAULTS_OWNER_SAFE is the deployer");
        DeepCoreGovernance.requireGovernanceSafe(w.safe, deployer, "VAULTS_OWNER_SAFE");
        require(address(w.clPoolManager).code.length > 0, "CL_POOL_MANAGER has no code");
        require(address(w.clPoolManager.vault()).code.length > 0, "CL_POOL_MANAGER has no vault");
        require(w.feeWei <= w.feeCapWei, "VAULTS_FEE_WEI above the cap");
        require(w.perfCapBps <= 2_000 && w.perfBps <= w.perfCapBps, "performance fee outside the caps");
        require(w.noticeSeconds >= 1 days && w.noticeSeconds <= 30 days, "VAULTS_NOTICE_SECONDS outside 1..30 days");
    }

    /// @notice Read back the deployed reality. Public so tests drive it.
    function postflight(DeepCoreVaultFactory factory, Wiring memory w) public view {
        DeepCoreManagedVault impl = DeepCoreManagedVault(payable(factory.implementation()));
        require(address(factory) == DeepCoreDeploy.predict(w.factoryTarget), "factory not at the predicted address");
        require(address(impl) == DeepCoreDeploy.predict(w.implTarget), "implementation not at the predicted address");
        require(address(factory).code.length <= 24_576 && address(impl).code.length <= 24_576, "EIP-170");
        require(impl.FACTORY() == address(factory), "implementation factory");
        require(address(impl.CL_POOL_MANAGER()) == address(w.clPoolManager), "implementation manager");
        require(factory.owner() == w.safe && factory.pendingOwner() == address(0), "owner is not the Safe");
        require(factory.protocolFeeRecipient() == w.safe, "recipient is not the Safe");
        require(factory.feeWei() == w.feeWei && factory.maxFeeWei() == w.feeCapWei, "creation fee");
        require(factory.performanceFeeBps() == w.perfBps && factory.maxPerformanceFeeBps() == w.perfCapBps, "perf fee");
        require(factory.feeNoticeSeconds() == w.noticeSeconds, "notice");
        require(factory.vaultCount() == 0, "fresh factory");
    }
}
