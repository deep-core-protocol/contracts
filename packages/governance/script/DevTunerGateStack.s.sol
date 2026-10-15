// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {DeepCoreDynamicFeeHook} from "deepcore-hooks/src/dex/DeepCoreDynamicFeeHook.sol";
import {ManualPriceBandOracle} from "deepcore-hooks-rwa/src/oracles/ManualPriceBandOracle.sol";
import {DeepCoreTunerGate} from "../src/DeepCoreTunerGate.sol";

/// @notice A LOCAL DEVNET ONLY stack for the tuner gate's live-transaction bar: core, a test router, two
/// tokens, the dynamic-fee hook, a ManualPriceBandOracle and the gate. Not a release script.
/// Env: PRIVATE_KEY (an anvil key); GATE_OWNER, GATE_GUARDIAN, GATE_RECIPIENT, ORACLE_OWNER (anvil accounts).
contract DevTunerGateStack is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        require(block.chainid == 31337, "local anvil only");

        vm.startBroadcast(pk);
        Vault vault = new Vault();
        CLPoolManager manager = new CLPoolManager(IVault(address(vault)));
        vault.registerApp(address(manager));
        CLPoolManagerRouter router = new CLPoolManagerRouter(vault, manager);
        MockERC20 a = new MockERC20("Dev A", "DEVA", 18);
        MockERC20 b = new MockERC20("Dev B", "DEVB", 18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        t0.mint(deployer, 1e30);
        t1.mint(deployer, 1e30);
        t0.approve(address(router), type(uint256).max);
        t1.approve(address(router), type(uint256).max);
        DeepCoreDynamicFeeHook hook = new DeepCoreDynamicFeeHook(
            manager, IVault(address(vault)), deployer, deployer, 50_000, 1_500, 3_000, 1 days, 1 days, 500
        );
        ManualPriceBandOracle oracle = new ManualPriceBandOracle(vm.envAddress("ORACLE_OWNER"));
        DeepCoreTunerGate gate = new DeepCoreTunerGate(
            vm.envAddress("GATE_OWNER"), vm.envAddress("GATE_GUARDIAN"), vm.envAddress("GATE_RECIPIENT"), 1 days, 1 days, 1_000
        );
        vm.stopBroadcast();

        console.log("vault", address(vault));
        console.log("manager", address(manager));
        console.log("router", address(router));
        console.log("token0", address(t0));
        console.log("token1", address(t1));
        console.log("hook", address(hook));
        console.log("oracle", address(oracle));
        console.log("gate", address(gate));
    }
}
