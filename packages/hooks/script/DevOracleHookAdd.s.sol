// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {DeepCoreOracleHook} from "../src/oracle/DeepCoreOracleHook.sol";

/// @notice LOCAL DEVNET ONLY: adds `DeepCoreOracleHook` (at its release settings) to the stack
/// `DevOracleDexStack.s.sol` stood up. Env: PRIVATE_KEY, DEV_POOL_MANAGER, DEX_RECIPIENT (default: deployer).
contract DevOracleHookAdd is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        require(block.chainid == 31337, "local anvil only");
        ICLPoolManager manager = ICLPoolManager(vm.envAddress("DEV_POOL_MANAGER"));
        address recipient = vm.envOr("DEX_RECIPIENT", vm.addr(pk));
        vm.startBroadcast(pk);
        DeepCoreOracleHook oracleHook = new DeepCoreOracleHook(manager, IVault(address(manager.vault())), recipient, 100, 600, 16);
        vm.stopBroadcast();
        console.log("oracleHook", address(oracleHook));
    }
}
