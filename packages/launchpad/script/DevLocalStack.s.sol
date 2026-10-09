// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";

import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {CLPositionManager} from "infinity-periphery/src/pool-cl/CLPositionManager.sol";
import {BinPositionManager} from "infinity-periphery/src/pool-bin/BinPositionManager.sol";
import {CLPositionDescriptorOffChain} from "infinity-periphery/src/pool-cl/CLPositionDescriptorOffChain.sol";
import {ICLPositionDescriptor} from "infinity-periphery/src/pool-cl/interfaces/ICLPositionDescriptor.sol";
import {IWETH9} from "infinity-periphery/src/interfaces/external/IWETH9.sol";
import {CLQuoter} from "infinity-periphery/src/pool-cl/lens/CLQuoter.sol";
import {BinQuoter} from "infinity-periphery/src/pool-bin/lens/BinQuoter.sol";

import {LaunchGuardHook, ILaunchTokenOrigin} from "deepcore-hooks/src/launch/LaunchGuardHook.sol";
import {BinLaunchGuardHook} from "deepcore-hooks/src/launch/BinLaunchGuardHook.sol";
import {DeepCoreRegistry} from "deepcore-registry/src/DeepCoreRegistry.sol";
import {DeepCoreLaunchRegistry} from "deepcore-registry/src/DeepCoreLaunchRegistry.sol";
import {DeepCoreProtocolFeeControllerV2} from "deepcore-fees/src/DeepCoreProtocolFeeControllerV2.sol";
import {DeepCoreProtocolFeeControllerV3} from "deepcore-fees/src/DeepCoreProtocolFeeControllerV3.sol";

import {LaunchpadKitV2} from "../src/LaunchpadKitV2.sol";
import {DeepCoreLPLocker} from "../src/DeepCoreLPLocker.sol";
import {DeepCoreBinLPLocker} from "../src/DeepCoreBinLPLocker.sol";
import {LaunchTokenFactory} from "../src/LaunchTokenFactory.sol";
import {ILaunchTokenFactory} from "../src/interfaces/ILaunchTokenFactory.sol";
import {ILaunchRegistryWriter} from "../src/interfaces/ILaunchRegistryWriter.sol";
import {ILaunchpadKitV2} from "../src/interfaces/ILaunchpadKitV2.sol";
import {DeepCorePadFactory} from "../src/pad/DeepCorePadFactory.sol";

/// @title DevLocalStack - the whole DeepCore stack on a PLAIN anvil, for front-end development
/// @notice `test/kitv2/KitV2Fixture.sol::_deployAll` as a broadcast: core (Vault, both pool managers), periphery
/// (Permit2, WETH, both position managers, both quoters), the registries, the fee controllers with V3
/// INSTALLED on both managers, the Kit v2 stack, the pad factory, and a mintable mock quote token.
///
/// WHY THIS EXISTS. An anvil fork of a public RPC can die within minutes when the endpoint prunes
/// historical state: anvil then cannot fetch what it needs and panics. A plain anvil has no upstream, so a
/// dev session lasts as long as the process does. The cost is that nothing here is a deployed core: addresses differ, there is no
/// UniversalRouter (it lives in packages/router with its own build), and the pool managers are owned by the
/// dev key rather than the custody timelock. A front end pointed here must override every core address.
///
/// DEV ONLY. Refuses to run unless `DEV_LOCAL=1`, and never against a real network: check the RPC is a
/// local anvil. One flat broadcast from `PRIVATE_KEY`, which becomes the owner of everything that has one.
///
///   anvil --port 8545
///   DEV_LOCAL=1 PRIVATE_KEY=<funded anvil key> forge script script/DevLocalStack.s.sol \
///       --rpc-url http://127.0.0.1:8545 --broadcast --slow
contract DevLocalStackScript is Script {
    uint256 internal constant INITIAL_LAUNCH_FEE = 0.0005 ether;
    uint256 internal constant MAX_LAUNCH_FEE = 0.01 ether;
    uint32 internal constant NOTICE = 7 days;
    uint256 internal constant MAX_INTEGRATOR_FEE = 0.005 ether;
    /// @dev DEVNET VALUES, not a price: the site (pad) fee is "$10 per chain" converted off chain at
    /// deploy time on a real chain (DeployDeepCorePadFactory.s.sol). Here 0.003 native, cap 10x, notice 7 d.
    uint256 internal constant PAD_FEE = 0.003 ether;
    uint256 internal constant PAD_FEE_CAP = 0.03 ether;
    uint8 internal constant MAX_LEGS = 4;
    uint16 internal constant MAX_BINS_PER_LEG = 20;
    /// @dev DEVNET VALUE. The share of the trade fee both guards leave their pools, on buys.
    uint16 internal constant LP_SHARE_BPS = 2_000;

    function run() external {
        require(vm.envOr("DEV_LOCAL", uint256(0)) == 1, "DEV_LOCAL=1 is required: this deploys a throwaway stack on a local anvil");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address safe = vm.envOr("KIT_OWNER_SAFE", deployer);

        /* Permit2 pins solc 0.8.17, so it is not compiled here. Its canonical runtime bytecode is
           etched locally by the permit2 test helper and pushed to anvil with `anvil_setCode` at the
           same canonical address, so the local simulation and the chain agree. */
        address permit2 = new DeployPermit2().deployPermit2();
        vm.rpc("anvil_setCode", string.concat('["', vm.toString(permit2), '","', vm.toString(permit2.code), '"]'));

        vm.startBroadcast(pk);

        Vault vault = new Vault();
        CLPoolManager clPM = new CLPoolManager(IVault(address(vault)));
        BinPoolManager binPM = new BinPoolManager(IVault(address(vault)));
        vault.registerApp(address(clPM));
        vault.registerApp(address(binPM));

        WETH weth = new WETH();
        ICLPositionDescriptor descriptor = new CLPositionDescriptorOffChain("http://localhost/positions/");
        CLPositionManager clPosm = new CLPositionManager(
            IVault(address(vault)), ICLPoolManager(address(clPM)), IAllowanceTransfer(address(permit2)), 100_000, descriptor, IWETH9(address(weth))
        );
        BinPositionManager binPosm = new BinPositionManager(
            IVault(address(vault)), IBinPoolManager(address(binPM)), IAllowanceTransfer(address(permit2)), IWETH9(address(weth))
        );
        CLQuoter clQuoter = new CLQuoter(address(clPM));
        BinQuoter binQuoter = new BinQuoter(address(binPM));

        LaunchTokenFactory factory = new LaunchTokenFactory();
        LaunchGuardHook clHook = new LaunchGuardHook(ICLPoolManager(address(clPM)), ILaunchTokenOrigin(address(factory)), safe, LP_SHARE_BPS);
        BinLaunchGuardHook binHook = new BinLaunchGuardHook(IBinPoolManager(address(binPM)), ILaunchTokenOrigin(address(factory)), safe, LP_SHARE_BPS);
        DeepCoreLPLocker clLocker = new DeepCoreLPLocker(clPosm, safe, 2_000, 5_000, 2_000);
        DeepCoreBinLPLocker binLocker = new DeepCoreBinLPLocker(binPosm, safe, 2_000, 5_000, 2_000, 64);

        address[] memory none = new address[](0);
        DeepCoreRegistry deepcoreRegistry = new DeepCoreRegistry(deployer, address(vault), none, none);
        DeepCoreLaunchRegistry launchRegistry = new DeepCoreLaunchRegistry(address(vault), address(deepcoreRegistry));

        DeepCoreProtocolFeeControllerV2 v2 = new DeepCoreProtocolFeeControllerV2(deployer, deployer);
        LaunchpadKitV2 kit = new LaunchpadKitV2(
            LaunchpadKitV2.Deployment({
                owner: safe,
                clPoolManager: ICLPoolManager(address(clPM)),
                clHook: clHook,
                clPositionManager: clPosm,
                clLocker: clLocker,
                binPoolManager: IBinPoolManager(address(binPM)),
                binHook: binHook,
                binPositionManager: binPosm,
                binLocker: binLocker,
                tokenFactory: ILaunchTokenFactory(address(factory)),
                launchRegistry: ILaunchRegistryWriter(address(launchRegistry)),
                protocolFeeRecipient: safe,
                launchpadSteward: deployer,
                initialLaunchFeeWei: INITIAL_LAUNCH_FEE,
                maxLaunchFeeWei: MAX_LAUNCH_FEE,
                launchFeeNoticeSeconds: NOTICE,
                maxIntegratorLaunchFeeWei: MAX_INTEGRATOR_FEE,
                maxLegs: MAX_LEGS,
                maxBinsPerLeg: MAX_BINS_PER_LEG
            })
        );
        DeepCoreProtocolFeeControllerV3 v3 = new DeepCoreProtocolFeeControllerV3(deployer, IProtocolFeeController(address(v2)), address(kit));
        clPM.setProtocolFeeController(v3);
        binPM.setProtocolFeeController(v3);

        DeepCorePadFactory padFactory = new DeepCorePadFactory(ILaunchpadKitV2(address(kit)), safe, safe, PAD_FEE, PAD_FEE_CAP, NOTICE);

        MockERC20 quote = new MockERC20("Dev USD", "dUSD", 6);
        quote.mint(deployer, 1_000_000_000e6);

        vm.stopBroadcast();

        console.log("");
        console.log("=== DeepCore local devnet (chain id %s) ===", block.chainid);
        console.log("  deployer / owner    ", deployer);
        console.log("  vault               ", address(vault));
        console.log("  clPoolManager       ", address(clPM));
        console.log("  binPoolManager      ", address(binPM));
        console.log("  permit2             ", permit2, "(canonical bytecode, anvil_setCode)");
        console.log("  weth                ", address(weth));
        console.log("  clPositionManager   ", address(clPosm));
        console.log("  binPositionManager  ", address(binPosm));
        console.log("  clQuoter            ", address(clQuoter));
        console.log("  binQuoter           ", address(binQuoter));
        console.log("  deepcoreRegistry       ", address(deepcoreRegistry));
        console.log("  launchRegistry      ", address(launchRegistry));
        console.log("  feeControllerV2     ", address(v2));
        console.log("  feeControllerV3     ", address(v3), "(installed on both managers)");
        console.log("  launchTokenFactory  ", address(factory));
        console.log("  clLaunchGuardHook   ", address(clHook));
        console.log("  binLaunchGuardHook  ", address(binHook));
        console.log("  clLPLocker          ", address(clLocker));
        console.log("  binLPLocker         ", address(binLocker));
        console.log("  launchpadKitV2      ", address(kit));
        console.log("  padFactory          ", address(padFactory), "(site fee 0.003 native, devnet value, cap 0.03, notice 7 d)");
        console.log("  quote token (dUSD)  ", address(quote), "6 decimals, 1e9 minted to the deployer");
        console.log("  no UniversalRouter: swaps through a router are not available on this devnet");
    }
}
