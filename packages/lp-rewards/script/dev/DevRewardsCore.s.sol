// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {CLPositionManager} from "infinity-periphery/src/pool-cl/CLPositionManager.sol";
import {CLPositionDescriptorOffChain} from "infinity-periphery/src/pool-cl/CLPositionDescriptorOffChain.sol";
import {IWETH9} from "infinity-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

/// @notice DEV ONLY (plain anvil): the slice of core and periphery the liquidity-rewards live bar needs -
/// Vault, CLPoolManager, the REAL CLPositionManager, core's test router (swaps and contract-held positions)
/// and three mintable tokens. Permit2 must already be at its canonical address (`anvil_setCode`). The hook
/// itself is deployed by `DeployLiquidityRewardsDevScript` in its own process, so it is the release bytecode
/// (this unit compiles at the position manager's 9,000 runs).
contract DevRewardsCoreScript is Script {
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    function run() external {
        require(block.chainid == 31337, "plain anvil only");
        require(PERMIT2.code.length > 0, "set Permit2's code first (anvil_setCode)");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        vm.startBroadcast(pk);
        Vault vault = new Vault();
        CLPoolManager pm = new CLPoolManager(vault);
        vault.registerApp(address(pm));
        CLPoolManagerRouter router = new CLPoolManagerRouter(vault, pm);
        WETH weth = new WETH();
        CLPositionDescriptorOffChain desc = new CLPositionDescriptorOffChain("https://deepcore.example/p/");
        CLPositionManager posm =
            new CLPositionManager(vault, pm, IAllowanceTransfer(PERMIT2), 100_000, desc, IWETH9(address(weth)));
        MockERC20 a = new MockERC20("Token A", "TKA", 18);
        MockERC20 b = new MockERC20("Token B", "TKB", 18);
        MockERC20 r = new MockERC20("Reward", "RWD", 18);
        a.mint(me, 1e30);
        b.mint(me, 1e30);
        r.mint(me, 1e30);
        vm.stopBroadcast();
        console.log("VAULT", address(vault));
        console.log("POOL_MANAGER", address(pm));
        console.log("ROUTER", address(router));
        console.log("POSM", address(posm));
        console.log("TOKEN_A", address(a));
        console.log("TOKEN_B", address(b));
        console.log("REWARD", address(r));
    }
}
