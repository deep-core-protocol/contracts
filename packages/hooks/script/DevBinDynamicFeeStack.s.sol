// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {LiquidityConfigurations} from "infinity-core/src/pool-bin/libraries/math/LiquidityConfigurations.sol";
import {PackedUint128Math} from "infinity-core/src/pool-bin/libraries/math/PackedUint128Math.sol";
import {BinSwapHelper} from "infinity-core/test/pool-bin/helpers/BinSwapHelper.sol";
import {BinLiquidityHelper} from "infinity-core/test/pool-bin/helpers/BinLiquidityHelper.sol";
import {DeepCoreBinDynamicFeeHook} from "../src/dex/DeepCoreBinDynamicFeeHook.sol";

/// @notice LOCAL DEVNET ONLY: builds Bin liquidity with core's own encoders, so a harness never has to
/// reproduce Bin's bit layouts. Holds test tokens and mints through core's test helper.
contract BinLiveKit {
    BinLiquidityHelper public immutable helper;

    constructor(BinLiquidityHelper helper_, MockERC20 x, MockERC20 y) {
        helper = helper_;
        x.approve(address(helper_), type(uint256).max);
        y.approve(address(helper_), type(uint256).max);
    }

    /// @notice Spread `amountX` over `n` bins from `activeId` up and `amountY` over `n` bins down.
    function mintAround(PoolKey calldata key, uint24 activeId, uint128 amountX, uint128 amountY, uint8 n) external {
        uint256 total = uint256(n) * 2 - 1;
        bytes32[] memory configs = new bytes32[](total);
        uint64 share = uint64(1e18 / n);
        for (uint256 i; i < total; ++i) {
            // forge-lint: disable-next-line(unsafe-typecast)
            uint24 id = uint24(uint256(activeId) + i - (n - 1));
            configs[i] = LiquidityConfigurations.encodeParams(id >= activeId ? share : 0, id <= activeId ? share : 0, id);
        }
        helper.mint(
            key,
            IBinPoolManager.MintParams({liquidityConfigs: configs, amountIn: PackedUint128Math.encode(amountX, amountY), salt: 0}),
            ""
        );
    }

    /// @notice A lopsided mint into ONE bin (X only): into the active bin it is an implicit swap.
    function mintXInto(PoolKey calldata key, uint24 id, uint128 amountX) external {
        bytes32[] memory configs = new bytes32[](1);
        configs[0] = LiquidityConfigurations.encodeParams(1e18, 1e18, id);
        helper.mint(
            key,
            IBinPoolManager.MintParams({liquidityConfigs: configs, amountIn: PackedUint128Math.encode(amountX, 0), salt: 0}),
            ""
        );
    }
}

/// @notice LOCAL DEVNET ONLY stack for the Bin dynamic-fee hook's live bar. Not a release script.
contract DevBinDynamicFeeStack is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        require(block.chainid == 31337, "local anvil only");
        address owner_ = vm.envOr("DYNFEE_OWNER", deployer);
        address recipient = vm.envOr("DYNFEE_RECIPIENT", deployer);

        vm.startBroadcast(pk);
        Vault vault = new Vault();
        BinPoolManager manager = new BinPoolManager(IVault(address(vault)));
        vault.registerApp(address(manager));
        BinSwapHelper swapHelper = new BinSwapHelper(manager, vault);
        BinLiquidityHelper liqHelper = new BinLiquidityHelper(manager, vault);
        MockERC20 a = new MockERC20("Dev A", "DEVA", 18);
        MockERC20 b = new MockERC20("Dev B", "DEVB", 18);
        (MockERC20 t0, MockERC20 t1) = address(a) < address(b) ? (a, b) : (b, a);
        BinLiveKit kit = new BinLiveKit(liqHelper, t0, t1);
        t0.mint(deployer, 1e30);
        t1.mint(deployer, 1e30);
        t0.mint(address(kit), 1e30);
        t1.mint(address(kit), 1e30);
        t0.approve(address(swapHelper), type(uint256).max);
        t1.approve(address(swapHelper), type(uint256).max);
        DeepCoreBinDynamicFeeHook hook = new DeepCoreBinDynamicFeeHook(
            manager, IVault(address(vault)), owner_, recipient, 50_000, 1_500, 3_000, 1 days, 1 days, 500
        );
        vm.stopBroadcast();

        console.log("vault", address(vault));
        console.log("manager", address(manager));
        console.log("swapHelper", address(swapHelper));
        console.log("kit", address(kit));
        console.log("token0", address(t0));
        console.log("token1", address(t1));
        console.log("hook", address(hook));
    }
}
