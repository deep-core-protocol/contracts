// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {LaunchGuardHook} from "deepcore-hooks/src/launch/LaunchGuardHook.sol";

import {LaunchpadKit} from "../../src/LaunchpadKit.sol";
import {LaunchTokenFactory} from "../../src/LaunchTokenFactory.sol";
import {Preset} from "../../src/libraries/LaunchPresets.sol";
import {LaunchParams, LaunchResult, SeedParams} from "../../src/interfaces/ILaunchpadKit.sol";
import {DeployDeepCoreLPLockerScript} from "../../script/DeployDeepCoreLPLocker.s.sol";
import {DeployLaunchGuardHookMainnetScript} from "../../script/DeployLaunchGuardHookMainnet.s.sol";
import {DeployLaunchpadKitMainnetScript} from "../../script/DeployLaunchpadKitMainnet.s.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinLaunchGuardHook} from "deepcore-hooks/src/launch/BinLaunchGuardHook.sol";
import {DeepCoreLaunchRegistry} from "deepcore-registry/src/DeepCoreLaunchRegistry.sol";
import {LaunchRecord, LaunchOrigin, LaunchMetadata} from "deepcore-registry/src/IDeepCoreLaunchRegistry.sol";
import {DeepCoreProtocolFeeControllerV3} from "deepcore-fees/src/DeepCoreProtocolFeeControllerV3.sol";
import {DeepCoreLPLocker} from "../../src/DeepCoreLPLocker.sol";
import {DeepCoreBinLPLocker} from "../../src/DeepCoreBinLPLocker.sol";
import {LaunchpadKitV2} from "../../src/LaunchpadKitV2.sol";
import {
    LegKind,
    BinShape,
    CLLegParams,
    BinLegParams,
    LegParams,
    ScheduleParams,
    LaunchParamsV2,
    LaunchResultV2
} from "../../src/interfaces/ILaunchpadKitV2.sol";
import {DeployDeepCoreBinLPLockerScript} from "../../script/DeployDeepCoreBinLPLocker.s.sol";
import {DeployBinLaunchGuardHookScript} from "../../script/DeployBinLaunchGuardHook.s.sol";
import {DeployLaunchpadKitV2Script} from "../../script/DeployLaunchpadKitV2.s.sol";
import {CreateXTest} from "deepcore-hooks/test/helpers/CreateXLike.sol";

interface IOwnedFork {
    function owner() external view returns (address);
}

/**
 * FORK REHEARSAL of the launchpad deploy on HyperEVM (999), once core is live there, in deployment order:
 *
 *   1. `DeployDeepCoreLPLocker`          -> DeepCoreLPLocker + LaunchTokenFactory
 *   2. `DeployLaunchGuardHookMainnet` -> LaunchGuardHook(poolManager, factory), listed, steward = Ops
 *   3. `DeployLaunchpadKitMainnet`    -> LaunchpadKit(poolManager, hook, positionManager, permit2, registry)
 *
 * then a factory token is created, a front-runner fails to claim its launch pool, the creator names
 * the kit, the kit launches it, and the fee decays on `block.timestamp`. Every script is driven through
 * its real `runWith`, against the chain's core and registry on a fork. Nothing is broadcast: a
 * Foundry test cannot send a transaction, and the key below holds nothing on any chain.
 *
 * Skipped unless `REHEARSAL_RPC_URL` is set. Addresses come from the deployment's own variable names:
 *
 *   REHEARSAL_RPC_URL=<999 RPC> CL_POOL_MANAGER=... CL_POSITION_MANAGER=... PERMIT2=... \
 *   LOCKER_PROTOCOL_RECIPIENT=<Safe> LAUNCH_GUARD_REGISTRY=... LAUNCH_GUARD_STEWARD=<Ops> \
 *   LAUNCHPAD_REGISTRY=... \
 *   forge test --match-path test/fork/TimestampRedeployRehearsal.t.sol --threads 2 -vvv
 *
 * KIT V2 (test_REHEARSE_kitV2LaunchOnTheLiveCore) additionally needs:
 *   BIN_POOL_MANAGER=... BIN_POSITION_MANAGER=... FEE_POLICY_V2=<live V2> LAUNCHPAD_STEWARD=<Ops>
 *   LAUNCH_REGISTRY=<live DeepCoreLaunchRegistry, optional: a fresh one is deployed on the fork when unset>
 * It deploys the whole kit v2 stack through the real scripts (both lockers, both guards, the kit), deploys a
 * V3 bound to the kit, installs it on the LIVE managers by impersonating their owner chain - a fork-only
 * stand-in for the 48 h Custody operation - and launches a native-quoted CL + Bin launch on the live core.
 */
contract TimestampLaunchpadRedeployRehearsal is Test {
    /// @dev A throwaway key for the forked simulation only. Never funded, never used to broadcast.
    uint256 internal constant REHEARSAL_PK = 0xBEEF_0002;
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant FRONT_RUNNER = address(0xBAD);
    int24 internal constant TICK_SPACING = 60;
    uint160 internal constant SQRT_1_1 = 79228162514264337593543950336;

    bool internal live;

    function setUp() public {
        string memory rpc = vm.envOr("REHEARSAL_RPC_URL", string(""));
        live = bytes(rpc).length != 0;
        if (live) vm.createSelectFork(rpc);
    }

    function test_REHEARSE_deployInOrderThenLaunchAFactoryToken() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, 999, "rehearsal must fork HyperEVM (999)");
        address poolManager = vm.envAddress("CL_POOL_MANAGER");
        address positionManager = vm.envAddress("CL_POSITION_MANAGER");

        (, LaunchTokenFactory factory) = new DeployDeepCoreLPLockerScript().runWith(
            DeployDeepCoreLPLockerScript.Wiring({
                pk: REHEARSAL_PK,
                positionManager: positionManager,
                protocolRecipient: vm.envAddress("LOCKER_PROTOCOL_RECIPIENT"),
                lockerTarget: CreateXTest.target(vm.addr(REHEARSAL_PK), "r1.lock.cl"),
                factoryTarget: CreateXTest.target(vm.addr(REHEARSAL_PK), "r1.factory")
            })
        );
        LaunchGuardHook hook = new DeployLaunchGuardHookMainnetScript().runWith(
            REHEARSAL_PK,
            poolManager,
            address(factory),
            vm.envAddress("LAUNCH_GUARD_REGISTRY"),
            vm.envAddress("LAUNCH_GUARD_STEWARD"),
            vm.envAddress("LOCKER_PROTOCOL_RECIPIENT"),
            2_000,
            CreateXTest.target(vm.addr(REHEARSAL_PK), "r1.guard.cl")
        );
        LaunchpadKit kit = new DeployLaunchpadKitMainnetScript().runWith(
            DeployLaunchpadKitMainnetScript.Wiring({
                pk: REHEARSAL_PK,
                poolManager: poolManager,
                hook: address(hook),
                positionManager: positionManager,
                permit2: vm.envAddress("PERMIT2"),
                registry: vm.envAddress("LAUNCHPAD_REGISTRY")
            })
        );

        vm.prank(CREATOR);
        address token = factory.createToken("Rehearsal", "RHR", "", 1_000_000 ether, CREATOR, keccak256("rehearsal"));

        LaunchParams memory p;
        p.launchToken = token;
        p.quoteToken = address(0); // native quote: no second token needed, nothing live touched
        p.tickSpacing = TICK_SPACING;
        p.sqrtPriceX96 = SQRT_1_1;
        p.preset = Preset.FairLaunch;
        p.startDelaySeconds = 120;
        p.launchOperator = CREATOR;
        p.seed = SeedParams({
            tickLower: 0, tickUpper: 0, launchTokenAmount: 0, quoteTokenAmount: 0, positionRecipient: address(0), deadline: 0
        });

        // The reservation: a copier cannot take the factory token's pool, and neither can the kit
        // until the creator names it.
        (PoolKey memory key,,) = kit.computePoolKey(token, address(0), TICK_SPACING);
        LaunchGuardHook.LaunchConfig memory squat = LaunchGuardHook.LaunchConfig({
            startTime: uint40(block.timestamp + 100),
            decaySeconds: 300,
            initialFeeBips: 100_000,
            finalFeeBips: 3_000,
            maxBuyPerTx: 0,
            launchTokenIsCurrency0: Currency.unwrap(key.currency0) == token,
            enabled: true
        });
        vm.prank(FRONT_RUNNER);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.LaunchPoolReserved.selector, token, CREATOR, FRONT_RUNNER));
        hook.configureLaunch(key, squat);

        vm.prank(CREATOR);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.LaunchPoolReserved.selector, token, CREATOR, address(kit)));
        kit.createLaunch(p);

        vm.prank(CREATOR);
        hook.setLaunchClaimer(token, address(kit));
        vm.prank(CREATOR);
        LaunchResult memory r = kit.createLaunch(p);
        PoolId poolId = r.poolId;
        assertEq(hook.launchOwner(poolId), address(kit));

        // The schedule is seconds of block.timestamp: FairLaunch is five minutes after a two-minute delay.
        LaunchGuardHook.Launch memory l = hook.getLaunch(poolId);
        assertEq(uint256(l.startTime), block.timestamp + 120, "startTime");
        assertEq(uint256(l.decaySeconds), 300, "FairLaunch window");
        uint24 opening = hook.feeAt(poolId, l.startTime);
        uint24 closing = hook.feeAt(poolId, uint256(l.startTime) + l.decaySeconds);
        assertGt(opening, closing, "fee decays");
        assertEq(closing, l.finalFeeBips);

        vm.warp(uint256(l.startTime) + l.decaySeconds / 2);
        uint24 mid = hook.currentFee(poolId);
        assertLt(mid, opening);
        assertGt(mid, closing);
        vm.warp(uint256(l.startTime) + l.decaySeconds);
        assertEq(hook.currentFee(poolId), closing, "settled at the window's end");
    }

    /*//////////////////////////////////////////////////////////////
                         KIT V2 ON THE LIVE CORE
    //////////////////////////////////////////////////////////////*/

    struct KitV2Stack {
        address clPM;
        address binPM;
        address safe;
        DeepCoreLPLocker clLocker;
        DeepCoreBinLPLocker binLocker;
        LaunchTokenFactory factory;
        LaunchGuardHook clHook;
        BinLaunchGuardHook binHook;
        address launchRegistry;
        LaunchpadKitV2 kit;
    }

    function test_REHEARSE_kitV2LaunchOnTheLiveCore() public {
        if (!live) {
            vm.skip(true);
            return;
        }
        assertEq(block.chainid, 999, "rehearsal must fork HyperEVM (999)");
        vm.deal(vm.addr(REHEARSAL_PK), 100 ether);
        KitV2Stack memory k = _deployKitV2Stack();

        // Fork-only stand-in for the Custody install: V3 bound to this kit, on both LIVE managers.
        DeepCoreProtocolFeeControllerV3 v3 = new DeepCoreProtocolFeeControllerV3(
            k.safe, IProtocolFeeController(vm.envAddress("FEE_POLICY_V2")), address(k.kit)
        );
        _installController(k.clPM, address(v3));
        _installController(k.binPM, address(v3));

        bytes32 salt = keccak256("kit-v2-rehearsal");
        address token = k.kit.predictLaunchToken(CREATOR, salt);
        LaunchParamsV2 memory p = _kitV2Params(salt);
        vm.deal(CREATOR, 1 ether);
        uint256 fee = k.kit.launchFeeWei();
        vm.prank(CREATOR);
        LaunchResultV2 memory r = k.kit.createLaunch{value: fee}(p);

        assertEq(r.token, token);
        (,, uint24 clFee,) = ICLPoolManager(k.clPM).getSlot0(PoolId.wrap(r.poolIds[0]));
        (, uint24 binFee,) = IBinPoolManager(k.binPM).getSlot0(PoolId.wrap(r.poolIds[1]));
        assertEq(clFee, 0, "live CL manager: kit pool born at zero");
        assertEq(binFee, 0, "live Bin manager: kit pool born at zero");
        assertTrue(k.clLocker.isLocked(r.lockIds[0]));
        assertTrue(k.binLocker.isLocked(r.lockIds[1]));
        assertEq(IERC20(token).balanceOf(address(k.kit)), 0);
        LaunchRecord memory rec = DeepCoreLaunchRegistry(k.launchRegistry).getLaunch(r.poolIds[0]);
        assertEq(uint8(rec.origin), uint8(LaunchOrigin.LaunchpadAttested));
        assertEq(k.kit.feesOwed(k.safe), fee);

        // A non-kit dynamic pool on the same live manager still pays V2's fee through V3.
        assertFalse(v3.isLockedLaunchPool(PoolId.wrap(keccak256("not a launch"))));
    }

    function _deployKitV2Stack() internal returns (KitV2Stack memory k) {
        k.clPM = vm.envAddress("CL_POOL_MANAGER");
        k.binPM = vm.envAddress("BIN_POOL_MANAGER");
        k.safe = vm.envAddress("LOCKER_PROTOCOL_RECIPIENT");
        address clPosm = vm.envAddress("CL_POSITION_MANAGER");
        address binPosm = vm.envAddress("BIN_POSITION_MANAGER");
        address deepcoreRegistry = vm.envAddress("LAUNCH_GUARD_REGISTRY");
        address steward = vm.envAddress("LAUNCH_GUARD_STEWARD");

        (k.clLocker, k.factory) = new DeployDeepCoreLPLockerScript().runWith(
            DeployDeepCoreLPLockerScript.Wiring({
                pk: REHEARSAL_PK,
                positionManager: clPosm,
                protocolRecipient: k.safe,
                lockerTarget: CreateXTest.target(vm.addr(REHEARSAL_PK), "r2.lock.cl"),
                factoryTarget: CreateXTest.target(vm.addr(REHEARSAL_PK), "r2.factory")
            })
        );
        k.binLocker = new DeployDeepCoreBinLPLockerScript().runWith(
            DeployDeepCoreBinLPLockerScript.Wiring({
                pk: REHEARSAL_PK,
                positionManager: binPosm,
                protocolRecipient: k.safe,
                clLocker: address(k.clLocker),
                target: CreateXTest.target(vm.addr(REHEARSAL_PK), "r2.lock.bn")
            })
        );
        k.clHook = new DeployLaunchGuardHookMainnetScript().runWith(
            REHEARSAL_PK, k.clPM, address(k.factory), deepcoreRegistry, steward, k.safe, 2_000,
            CreateXTest.target(vm.addr(REHEARSAL_PK), "r2.guard.cl")
        );
        k.binHook = new DeployBinLaunchGuardHookScript().runWith(
            REHEARSAL_PK, k.binPM, address(k.factory), deepcoreRegistry, steward, k.safe, 2_000,
            CreateXTest.target(vm.addr(REHEARSAL_PK), "r2.grd.bin")
        );

        k.launchRegistry = vm.envOr("LAUNCH_REGISTRY", address(0));
        if (k.launchRegistry == address(0)) {
            k.launchRegistry = address(new DeepCoreLaunchRegistry(address(ICLPoolManager(k.clPM).vault()), deepcoreRegistry));
        }

        k.kit = new DeployLaunchpadKitV2Script().runWith(
            DeployLaunchpadKitV2Script.Wiring({
                pk: REHEARSAL_PK,
                clPoolManager: k.clPM,
                binPoolManager: k.binPM,
                clPositionManager: clPosm,
                binPositionManager: binPosm,
                clHook: address(k.clHook),
                binHook: address(k.binHook),
                clLocker: address(k.clLocker),
                binLocker: address(k.binLocker),
                tokenFactory: address(k.factory),
                launchRegistry: k.launchRegistry,
                safe: k.safe,
                launchpadSteward: vm.envAddress("LAUNCHPAD_STEWARD"),
                initialLaunchFeeWei: 0.0005 ether,
                maxLaunchFeeWei: 0.01 ether,
                maxIntegratorLaunchFeeWei: 0.005 ether,
                feePolicyV2: vm.envAddress("FEE_POLICY_V2"),
                launchLegs: address(0), // forge links the kit itself in an in-EVM rehearsal
                target: CreateXTest.target(vm.addr(REHEARSAL_PK), "r2.kit")
            })
        );
    }

    /// @dev manager.owner() is the *PoolManagerOwner wrapper; the wrapper's owner may call it. Fork only.
    function _installController(address manager, address controller) internal {
        address wrapper = IOwnedFork(manager).owner();
        vm.prank(IOwnedFork(wrapper).owner());
        (bool ok,) = wrapper.call(abi.encodeWithSignature("setProtocolFeeController(address)", controller));
        require(ok, "fork install of V3 failed");
    }

    function _kitV2Params(bytes32 salt) internal pure returns (LaunchParamsV2 memory p) {
        LegParams[] memory legs = new LegParams[](2);
        // Native quote: the launch token is always currency1, so the CL range sits below spot (tick 0).
        legs[0].kind = LegKind.CL;
        legs[0].quote = address(0);
        legs[0].weightBps = 6_000;
        legs[0].cl = CLLegParams({tickSpacing: TICK_SPACING, sqrtPriceX96: SQRT_1_1, tickLower: -60_000, tickUpper: 0});
        legs[1].kind = LegKind.Bin;
        legs[1].quote = address(0);
        legs[1].weightBps = 4_000;
        legs[1].bin = BinLegParams({
            binStep: 10,
            activeId: 2 ** 23,
            shape: BinShape.Linear,
            binCount: 10,
            offsets: new uint24[](0),
            weights: new uint64[](0),
            floorBins: 0
        });
        p.name = "Kit v2 Rehearsal";
        p.symbol = "KV2R";
        p.userSalt = salt;
        p.totalSupply = 1_000_000 ether;
        p.seedSupply = 800_000 ether;
        p.allocationRecipient = CREATOR;
        p.creatorBps = 8_000;
        p.protocolBps = 2_000;
        p.schedule = ScheduleParams({
            preset: Preset.FairLaunch,
            initialFeeBips: 0,
            finalFeeBips: 0,
            decaySeconds: 0,
            enabled: false,
            startDelaySeconds: 120
        });
        p.legs = legs;
        p.listing =
            LaunchMetadata({description: "fork rehearsal", websiteURI: "", xHandle: "", telegramHandle: ""});
    }
}
