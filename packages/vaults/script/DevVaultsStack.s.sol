// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {DeepCoreOracleHook} from "deepcore-hooks/src/oracle/DeepCoreOracleHook.sol";

import {DeepCoreManagedVault} from "../src/DeepCoreManagedVault.sol";
import {DeepCoreVaultFactory} from "../src/DeepCoreVaultFactory.sol";

/**
 * LOCAL DEVNET ONLY (plain anvil, never a real chain): stands up the core Vault + CL pool manager, two test
 * tokens, the REAL price-oracle hook, one oracle-hooked pool and one native/token oracle-hooked pool with
 * background liquidity, a test router, the vault implementation and the factory. The live-transaction bar
 * drives everything else from a harness. Release deployments use `DeployDeepCoreVaults.s.sol` (CreateX, the
 * Safe); this script exists because that path needs CreateX and a Safe, neither of which a plain anvil has.
 *
 *   anvil --port 8551 &   (and --hardfork shanghai for the legacy profile)
 *   PRIVATE_KEY=<anvil key 0> SAFE=<anvil account 9> forge script script/DevVaultsStack.s.sol --rpc-url http://127.0.0.1:8551 --broadcast --slow
 */
contract DevVaultsStackScript is Script {
    using CLPoolParametersHelper for bytes32;

    uint160 internal constant SQRT_1_1 = 79228162514264337593543950336;

    function run() external {
        require(block.chainid == 31337, "devnet only");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address safe = vm.envAddress("SAFE");
        vm.startBroadcast(pk);

        Vault vault = new Vault();
        CLPoolManager cl = new CLPoolManager(IVault(address(vault)));
        vault.registerApp(address(cl));
        CLPoolManagerRouter router = new CLPoolManagerRouter(IVault(address(vault)), ICLPoolManager(address(cl)));
        MockERC20 a = new MockERC20("Test A", "TKA", 18);
        MockERC20 b = new MockERC20("Test B", "TKB", 18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        DeepCoreOracleHook hook = new DeepCoreOracleHook(ICLPoolManager(address(cl)), IVault(address(vault)), safe, 100, 600, 64);

        bytes32 params = bytes32(uint256(hook.getHooksRegistrationBitmap())).setTickSpacing(10);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(t0)),
            currency1: Currency.wrap(address(t1)),
            hooks: IHooks(address(hook)),
            poolManager: IPoolManager(address(cl)),
            fee: 3000,
            parameters: params
        });
        cl.initialize(key, SQRT_1_1);
        PoolKey memory nkey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(t1)),
            hooks: IHooks(address(hook)),
            poolManager: IPoolManager(address(cl)),
            fee: 3000,
            parameters: params
        });
        cl.initialize(nkey, SQRT_1_1);

        t0.mint(deployer, 1e30);
        t1.mint(deployer, 1e30);
        t0.approve(address(router), type(uint256).max);
        t1.approve(address(router), type(uint256).max);
        router.modifyPosition(
            key, ICLPoolManager.ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e22, salt: 0}), ""
        );
        router.modifyPosition{value: 1000 ether}(
            nkey, ICLPoolManager.ModifyLiquidityParams({tickLower: -60000, tickUpper: 60000, liquidityDelta: 1e19, salt: 0}), ""
        );

        address predicted = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        DeepCoreManagedVault impl = new DeepCoreManagedVault(predicted, ICLPoolManager(address(cl)));
        DeepCoreVaultFactory factory =
            new DeepCoreVaultFactory(address(impl), safe, safe, 0.075 ether, 0.75 ether, 7 days, 1_000, 2_000);
        require(address(factory) == predicted, "factory address");
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        vm.stopBroadcast();

        console.log("VAULT_CORE", address(vault));
        console.log("CL_POOL_MANAGER", address(cl));
        console.log("ROUTER", address(router));
        console.log("TOKEN0", address(t0));
        console.log("TOKEN1", address(t1));
        console.log("ORACLE_HOOK", address(hook));
        console.log("IMPL", address(impl));
        console.log("FACTORY", address(factory));
        console.log("STRAY", address(stray));
        console.logBytes32(params);
    }
}
