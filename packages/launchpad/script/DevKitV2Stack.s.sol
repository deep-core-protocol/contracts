// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";

import {DeepCoreLaunchRegistry} from "deepcore-registry/src/DeepCoreLaunchRegistry.sol";

import {DeployBinLaunchGuardHookScript} from "./DeployBinLaunchGuardHook.s.sol";
import {DeployDeepCoreBinLPLockerScript} from "./DeployDeepCoreBinLPLocker.s.sol";
import {DeployDeepCoreLPLockerScript} from "./DeployDeepCoreLPLocker.s.sol";
import {DeployLaunchGuardHookMainnetScript} from "./DeployLaunchGuardHookMainnet.s.sol";
import {DeployLaunchpadKitV2Script} from "./DeployLaunchpadKitV2.s.sol";
import {DeployDeepCorePadFactoryScript} from "./DeployDeepCorePadFactory.s.sol";
import {DeepCorePadFactory} from "../src/pad/DeepCorePadFactory.sol";
import {CreateXCreate3, DeepCoreDeploy} from "./CreateX.sol";
import {LaunchpadKitV2} from "../src/LaunchpadKitV2.sol";
import {DeepCoreLPLocker} from "../src/DeepCoreLPLocker.sol";
import {DeepCoreBinLPLocker} from "../src/DeepCoreBinLPLocker.sol";
import {LaunchTokenFactory} from "../src/LaunchTokenFactory.sol";
import {LaunchGuardHook} from "deepcore-hooks/src/launch/LaunchGuardHook.sol";
import {BinLaunchGuardHook} from "deepcore-hooks/src/launch/BinLaunchGuardHook.sol";

/// @title DevKitV2Stack - the whole Kit v2 stack on a LOCAL FORK, for front-end development
/// @notice Deploys, through the REAL deploy scripts' `runWith` entry points, exactly what
/// `test/fork/TimestampRedeployRehearsal.t.sol::test_REHEARSE_kitV2LaunchOnTheLiveCore` deploys: CL locker +
/// token factory, Bin locker, both launch guards (listed in the live `DeepCoreRegistry`), a fresh
/// `DeepCoreLaunchRegistry`, and `LaunchpadKitV2` owned by the governance Safe - so a tenant front end
/// (`create-deepcore-app`) can be pointed at a kit that exists before DeepCore's shared one does.
///
/// ONE STEP PER INVOCATION, selected by `STEP`, each step reading the previous steps' addresses from env:
///
///   STEP=lockers    -> LOCKER_CL, LAUNCH_TOKEN_FACTORY, LOCKER_BIN            (needs the position managers)
///   STEP=guard-cl   -> GUARD_CL                                                (needs LAUNCH_TOKEN_FACTORY)
///   STEP=guard-bin  -> GUARD_BIN                                               (needs LAUNCH_TOKEN_FACTORY)
///   STEP=registry   -> LAUNCH_REGISTRY                                         (a fresh DeepCoreLaunchRegistry)
///   STEP=kit        -> LAUNCHPAD_KIT_V2                                        (needs everything above)
///   STEP=pads       -> PAD_FACTORY                                             (needs LAUNCHPAD_KIT_V2, KIT_OWNER_SAFE;
///                                                                              PAD_FEE_WEI / PAD_FEE_CAP_WEI / PAD_FEE_NOTICE_SECONDS optional)
///
/// Why steps and not one run: a broadcast that crosses several script contracts (each `runWith` opens its
/// own `vm.startBroadcast`) while a linked library (`LaunchLegs`) is auto-deployed first produced a
/// transaction plan with duplicate nonces under `forge script --broadcast` (foundry 1.8.1), and two guard
/// deployments in one process (each a CREATE followed by a registry `register` CALL) had the second
/// `register` simulated before its CREATE. One nested script per process never has either problem. The
/// in-EVM rehearsal test is unaffected: it never broadcasts.
///
/// FORK ONLY. This is a development tool:
///   * It refuses to run unless `DEV_FORK=1` is set; the reader should still check `--rpc-url` is an anvil
///     fork (`anvil --fork-url <chain rpc>`), never a live endpoint.
///   * It skips the production scripts' `run()` guards (the ~3-minute contract-clock probe, the
///     address-book read-back) by calling `runWith` with explicit addresses. The production path is each
///     script's `run()`; this script proves nothing about it.
///   * It does NOT install a V3 fee controller: on the live chain that is a 48 h Custody operation, and on
///     a fork it is the `vm.prank` the rehearsal test performs. Pools this stack creates are born at the
///     fee the installed V2 controller assigns, which is what a tenant sees today anyway.
///
/// Common env: DEV_FORK=1, PRIVATE_KEY (a funded fork key), CL_POOL_MANAGER, BIN_POOL_MANAGER,
/// CL_POSITION_MANAGER, BIN_POSITION_MANAGER, LAUNCH_GUARD_REGISTRY (the live DeepCoreRegistry),
/// LAUNCH_GUARD_STEWARD, LAUNCHPAD_STEWARD, KIT_OWNER_SAFE, FEE_POLICY_V2.
contract DevKitV2StackScript is Script {
    function run() external {
        require(vm.envOr("DEV_FORK", uint256(0)) == 1, "DEV_FORK=1 is required: this deploys a throwaway stack on a fork");
        string memory step = vm.envString("STEP");
        bytes32 s = keccak256(bytes(step));
        if (s == keccak256("lockers")) _lockers();
        else if (s == keccak256("guard-cl")) _guardCL();
        else if (s == keccak256("guard-bin")) _guardBin();
        else if (s == keccak256("registry")) _registry();
        else if (s == keccak256("kit")) _kit();
        else if (s == keccak256("pads")) _pads();
        else revert("STEP must be lockers | guard-cl | guard-bin | registry | kit | pads");
    }

    /// @dev A CreateX target for a DEV run. Production reads the mined salts file
    /// (`DEEPCORE_SALT_<LABEL>` / `DEEPCORE_ADDRESS_<LABEL>`, see `ops/deploy/salts/README.md`); when those are
    /// exported this uses them, and otherwise it derives a throwaway salt from `tag` so a fork needs no
    /// mining. `createXCodeHash` is read from whatever sits at CreateX's address, because a plain anvil
    /// may carry a stand-in while a fork carries the real thing.
    function _devTarget(string memory label, bytes11 tag) internal view returns (DeepCoreDeploy.Target memory) {
        address deployer = vm.addr(vm.envUint("PRIVATE_KEY"));
        return DeepCoreDeploy.Target({
            createX: CreateXCreate3.CREATEX,
            createXCodeHash: CreateXCreate3.CREATEX.codehash,
            deployer: deployer,
            salt: vm.envOr(
                string.concat("DEEPCORE_SALT_", label), CreateXCreate3.permissionedCrossChainSalt(deployer, tag)
            ),
            expected: vm.envOr(string.concat("DEEPCORE_ADDRESS_", label), address(0))
        });
    }

    /// @dev The liquidity providers' share both guards are deployed with. 2,000 unless the env says otherwise.
    function _lpShare() internal view returns (uint16) {
        uint256 v = vm.envOr("LAUNCH_LP_SHARE_BPS", uint256(2_000));
        require(v <= 5_000, "LAUNCH_LP_SHARE_BPS is above the guard's cap (5000)");
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(v);
    }

    function _lockers() internal {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address safe = vm.envAddress("KIT_OWNER_SAFE");
        (DeepCoreLPLocker clLocker, LaunchTokenFactory factory) = new DeployDeepCoreLPLockerScript().runWith(
            DeployDeepCoreLPLockerScript.Wiring({
                pk: pk,
                positionManager: vm.envAddress("CL_POSITION_MANAGER"),
                protocolRecipient: safe,
                lockerTarget: _devTarget("DEEPCORE_LP_LOCKER", "dev.lck.cl"),
                factoryTarget: _devTarget("LAUNCH_TOKEN_FACTORY", "dev.factory")
            })
        );
        DeepCoreBinLPLocker binLocker = new DeployDeepCoreBinLPLockerScript().runWith(
            DeployDeepCoreBinLPLockerScript.Wiring({
                pk: pk,
                positionManager: vm.envAddress("BIN_POSITION_MANAGER"),
                protocolRecipient: safe,
                clLocker: address(clLocker),
                target: _devTarget("DEEPCORE_BIN_LP_LOCKER", "dev.lck.bn")
            })
        );
        console.log("");
        console.log("=== STEP lockers ===");
        console.log("  LOCKER_CL            ", address(clLocker));
        console.log("  LAUNCH_TOKEN_FACTORY ", address(factory));
        console.log("  LOCKER_BIN           ", address(binLocker));
    }

    function _guardCL() internal {
        LaunchGuardHook clHook = new DeployLaunchGuardHookMainnetScript().runWith(
            vm.envUint("PRIVATE_KEY"),
            vm.envAddress("CL_POOL_MANAGER"),
            vm.envAddress("LAUNCH_TOKEN_FACTORY"),
            vm.envAddress("LAUNCH_GUARD_REGISTRY"),
            vm.envAddress("LAUNCH_GUARD_STEWARD"),
            vm.envAddress("KIT_OWNER_SAFE"),
            _lpShare(),
            _devTarget("LAUNCH_GUARD_HOOK_QF", "dev.grd.cl")
        );
        console.log("");
        console.log("=== STEP guard-cl ===");
        console.log("  GUARD_CL ", address(clHook));
    }

    function _guardBin() internal {
        BinLaunchGuardHook binHook = new DeployBinLaunchGuardHookScript().runWith(
            vm.envUint("PRIVATE_KEY"),
            vm.envAddress("BIN_POOL_MANAGER"),
            vm.envAddress("LAUNCH_TOKEN_FACTORY"),
            vm.envAddress("LAUNCH_GUARD_REGISTRY"),
            vm.envAddress("LAUNCH_GUARD_STEWARD"),
            vm.envAddress("KIT_OWNER_SAFE"),
            _lpShare(),
            _devTarget("BIN_LAUNCH_GUARD_HOOK_QF", "dev.grd.bn")
        );
        console.log("");
        console.log("=== STEP guard-bin ===");
        console.log("  GUARD_BIN ", address(binHook));
    }

    function _registry() internal {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address vault = address(ICLPoolManager(vm.envAddress("CL_POOL_MANAGER")).vault());
        vm.startBroadcast(pk);
        DeepCoreLaunchRegistry launchRegistry = new DeepCoreLaunchRegistry(vault, vm.envAddress("LAUNCH_GUARD_REGISTRY"));
        vm.stopBroadcast();
        console.log("");
        console.log("=== STEP registry ===");
        console.log("  LAUNCH_REGISTRY ", address(launchRegistry));
    }

    function _kit() internal {
        LaunchpadKitV2 kit = new DeployLaunchpadKitV2Script().runWith(
            DeployLaunchpadKitV2Script.Wiring({
                pk: vm.envUint("PRIVATE_KEY"),
                clPoolManager: vm.envAddress("CL_POOL_MANAGER"),
                binPoolManager: vm.envAddress("BIN_POOL_MANAGER"),
                clPositionManager: vm.envAddress("CL_POSITION_MANAGER"),
                binPositionManager: vm.envAddress("BIN_POSITION_MANAGER"),
                clHook: vm.envAddress("GUARD_CL"),
                binHook: vm.envAddress("GUARD_BIN"),
                clLocker: vm.envAddress("LOCKER_CL"),
                binLocker: vm.envAddress("LOCKER_BIN"),
                tokenFactory: vm.envAddress("LAUNCH_TOKEN_FACTORY"),
                launchRegistry: vm.envAddress("LAUNCH_REGISTRY"),
                safe: vm.envAddress("KIT_OWNER_SAFE"),
                launchpadSteward: vm.envAddress("LAUNCHPAD_STEWARD"),
                initialLaunchFeeWei: vm.envOr("INITIAL_LAUNCH_FEE_WEI", uint256(0.0005 ether)),
                maxLaunchFeeWei: vm.envOr("MAX_LAUNCH_FEE_WEI", uint256(0.01 ether)),
                maxIntegratorLaunchFeeWei: vm.envOr("MAX_INTEGRATOR_LAUNCH_FEE_WEI", uint256(0.005 ether)),
                feePolicyV2: vm.envOr("FEE_POLICY_V2", address(0)),
                /* A dev run lets forge auto-deploy and link LaunchLegs, so no address is known here and
                   the linked-library check is skipped. Production deploys the library first
                   (DeployLaunchLegs.s.sol) and passes --libraries. */
                launchLegs: vm.envOr("DEEPCORE_ADDRESS_LAUNCH_LEGS_QF", address(0)),
                target: _devTarget("LAUNCHPAD_KIT_V2_QF", "dev.kit")
            })
        );
        console.log("");
        console.log("=== STEP kit - paste into deepcore.config.ts ===");
        console.log("  launchpadKitV2 ", address(kit));
    }

    function _pads() internal {
        // PAD_FEE_WEI is the $10 site fee converted off chain (DeployDeepCorePadFactory.s.sol header); the
        // defaults here are DEVNET values for a fork, not a price.
        DeepCorePadFactory padFactory = new DeployDeepCorePadFactoryScript().runWith(
            DeployDeepCorePadFactoryScript.Wiring({
                pk: vm.envUint("PRIVATE_KEY"),
                kit: vm.envAddress("LAUNCHPAD_KIT_V2"),
                safe: vm.envAddress("KIT_OWNER_SAFE"),
                padFeeWei: vm.envOr("PAD_FEE_WEI", uint256(0.003 ether)),
                padFeeCapWei: vm.envOr("PAD_FEE_CAP_WEI", uint256(0.03 ether)),
                padFeeNoticeSeconds: uint32(vm.envOr("PAD_FEE_NOTICE_SECONDS", uint256(7 days))),
                // A fork carries the real CreateX; the salt is permissioned to this deployer.
                target: _devTarget("DEEPCORE_PAD_FACTORY_QF", "dcore.pads")
            })
        );
        console.log("");
        console.log("=== STEP pads - paste into deepcore.config.ts / the dapp address book ===");
        console.log("  PAD_FACTORY ", address(padFactory));
    }
}
