// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {DeepCoreDexHook} from "../src/dex/DeepCoreDexHook.sol";

/// @notice A LOCAL DEVNET ONLY stack for the oracle and DEX hooks' live-transaction bar: a Vault, a CL
/// pool manager, core's test router, two test tokens and `DeepCoreDexHook`. `DeepCoreOracleHook` is added
/// by `DevOracleHookAdd.s.sol`, a SEPARATE compilation unit: this one includes the DEX hook, so forge
/// builds everything in it at the DEX hook's pinned 2,000 runs, which is not the oracle hook's release
/// bytecode. Not a release script (each hook has its own `Deploy*.s.sol`).
/// Env: PRIVATE_KEY (an anvil key), DEX_OWNER and DEX_RECIPIENT (defaults: the deployer).
contract DevOracleDexStack is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        require(block.chainid == 31337, "local anvil only");
        address owner_ = vm.envOr("DEX_OWNER", deployer);
        address recipient = vm.envOr("DEX_RECIPIENT", deployer);

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
        DeepCoreDexHook dexHook = new DeepCoreDexHook(
            manager, IVault(address(vault)), owner_, recipient, 50_000, 1_500, 3_000, 1 days, 1 days, 500, 100, 600, 16
        );
        vm.stopBroadcast();

        console.log("vault", address(vault));
        console.log("manager", address(manager));
        console.log("router", address(router));
        console.log("token0", address(t0));
        console.log("token1", address(t1));
        console.log("dexHook", address(dexHook));
    }
}
