// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {LiquidityConfigurations} from "infinity-core/src/pool-bin/libraries/math/LiquidityConfigurations.sol";
import {PackedUint128Math} from "infinity-core/src/pool-bin/libraries/math/PackedUint128Math.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {BinSwapHelper} from "infinity-core/test/pool-bin/helpers/BinSwapHelper.sol";
import {BinLiquidityHelper} from "infinity-core/test/pool-bin/helpers/BinLiquidityHelper.sol";

import {DeepCoreRangeOrders} from "../../src/DeepCoreRangeOrders.sol";
import {DeepCoreDCA} from "../../src/DeepCoreDCA.sol";

/// @dev Stands up a plain-anvil devnet for the live-transaction bar: core (Vault + both managers), two tokens,
/// a CL pool, a native CL pool and a Bin pool with liquidity, both order contracts owned by a Safe stand-in
/// (the anvil account #9, whose key the harness holds; a real Safe's signing path is G-5, not this bar).
/// Prints a JSON blob of addresses. Never used against a real chain (refuses any chain id but 31337).
contract LiveBarSetup is Script {
    using CLPoolParametersHelper for bytes32;
    using BinPoolParametersHelper for bytes32;

    function run() external {
        require(block.chainid == 31337, "devnet only");
        address safe = vm.envAddress("LIVE_SAFE");
        address[] memory people = vm.envAddress("LIVE_PEOPLE", ",");
        vm.startBroadcast();
        Vault vault = new Vault();
        CLPoolManager cl = new CLPoolManager(IVault(address(vault)));
        BinPoolManager bin = new BinPoolManager(IVault(address(vault)));
        vault.registerApp(address(cl));
        vault.registerApp(address(bin));
        CLPoolManagerRouter router = new CLPoolManagerRouter(IVault(address(vault)), ICLPoolManager(address(cl)));
        BinSwapHelper binSwapper = new BinSwapHelper(IBinPoolManager(address(bin)), IVault(address(vault)));
        BinLiquidityHelper binLiq = new BinLiquidityHelper(IBinPoolManager(address(bin)), IVault(address(vault)));
        MockERC20 a = new MockERC20("A", "A", 18);
        MockERC20 b = new MockERC20("B", "B", 18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        for (uint256 i; i < people.length; ++i) {
            t0.mint(people[i], 1e30);
            t1.mint(people[i], 1e30);
        }
        t0.approve(address(router), type(uint256).max);
        t1.approve(address(router), type(uint256).max);
        t0.approve(address(binLiq), type(uint256).max);
        t1.approve(address(binLiq), type(uint256).max);

        PoolKey memory keyCL = PoolKey(
            Currency.wrap(address(t0)), Currency.wrap(address(t1)), IHooks(address(0)), IPoolManager(address(cl)), 3000,
            bytes32(0).setTickSpacing(10)
        );
        cl.initialize(keyCL, 79228162514264337593543950336);
        router.modifyPosition(keyCL, ICLPoolManager.ModifyLiquidityParams(-6000, 6000, 1e21, 0), "");
        PoolKey memory keyN = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(t1)), IHooks(address(0)), IPoolManager(address(cl)), 3000,
            bytes32(0).setTickSpacing(10)
        );
        cl.initialize(keyN, 79228162514264337593543950336);
        router.modifyPosition{value: 5e20}(keyN, ICLPoolManager.ModifyLiquidityParams(-6000, 6000, 1e21, 0), "");
        PoolKey memory keyBin = PoolKey(
            Currency.wrap(address(t0)), Currency.wrap(address(t1)), IHooks(address(0)), IPoolManager(address(bin)), 3000,
            bytes32(0).setBinStep(10)
        );
        bin.initialize(keyBin, 2 ** 23);
        bytes32[] memory configs = new bytes32[](3);
        configs[0] = LiquidityConfigurations.encodeParams(0, 0.5e18, 2 ** 23 - 1);
        configs[1] = LiquidityConfigurations.encodeParams(0.5e18, 0.5e18, 2 ** 23);
        configs[2] = LiquidityConfigurations.encodeParams(0.5e18, 0, 2 ** 23 + 1);
        binLiq.mint(
            keyBin,
            IBinPoolManager.MintParams({
                liquidityConfigs: configs,
                amountIn: PackedUint128Math.encode(uint128(1e22), uint128(1e22)),
                salt: 0
            }),
            ""
        );

        address[] memory guards = new address[](1);
        guards[0] = address(0x000000000000000000000000000000000000dEaD); // a stand-in listed launch guard
        DeepCoreRangeOrders orders =
            new DeepCoreRangeOrders(ICLPoolManager(address(cl)), safe, safe, 10, 50, 7 days, guards);
        DeepCoreDCA dca =
            new DeepCoreDCA(ICLPoolManager(address(cl)), IBinPoolManager(address(bin)), safe, safe, 10, 50, 7 days);
        vm.stopBroadcast();

        console2.log("ADDR vault", address(vault));
        console2.log("ADDR cl", address(cl));
        console2.log("ADDR bin", address(bin));
        console2.log("ADDR router", address(router));
        console2.log("ADDR binSwapper", address(binSwapper));
        console2.log("ADDR t0", address(t0));
        console2.log("ADDR t1", address(t1));
        console2.log("ADDR orders", address(orders));
        console2.log("ADDR dca", address(dca));
    }
}
