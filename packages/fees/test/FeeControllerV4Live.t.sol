// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {CLPoolManagerOwner, ICLPoolManagerWithPauseOwnable} from "infinity-core/src/pool-cl/CLPoolManagerOwner.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IProtocolFees} from "infinity-core/src/interfaces/IProtocolFees.sol";
import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

import {TokenFixture} from "infinity-core/test/helpers/TokenFixture.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

import {DeepCoreProtocolFeeControllerV2} from "../src/DeepCoreProtocolFeeControllerV2.sol";
import {DeepCoreProtocolFeeControllerV3} from "../src/DeepCoreProtocolFeeControllerV3.sol";
import {DeepCoreProtocolFeeControllerV4} from "../src/DeepCoreProtocolFeeControllerV4.sol";
import {MockCLLaunchHook, MockLocker, MockCLLaunchKit} from "./utils/LaunchFixtures.sol";

/**
 * REAL core: Vault, CLPoolManager, CLPoolManagerOwner (the wrapper that holds fee authority on
 * chain), the real V2 as policy, and V4 naming TWO kits. Only the launchpad side is a fixture, as in
 * the V3 live suite: V4 depends on nothing of a kit's but `isLockedLaunch(bytes32)`.
 *
 * The two kits are the situation V4 exists for. Each has its OWN launch hook and its own locker,
 * because new guards are what make a second kit necessary in the first place: a hook address is part
 * of pool identity, so the first kit's pools and the second kit's pools can never be the same pools.
 *
 * This test contract plays the custody timelock: it owns the wrapper.
 */
contract FeeControllerV4LiveTest is Test, TokenFixture {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    Vault vault;
    CLPoolManager poolManager;
    CLPoolManagerOwner wrapper;
    CLPoolManagerRouter router;
    DeepCoreProtocolFeeControllerV2 v2;
    DeepCoreProtocolFeeControllerV4 v4;

    MockCLLaunchHook hookA;
    MockLocker lockerA;
    MockCLLaunchKit kitA;

    MockCLLaunchHook hookB;
    MockLocker lockerB;
    MockCLLaunchKit kitB;

    address safe = makeAddr("governanceSafe");
    address guardian = makeAddr("opsGuardian");
    address stranger = makeAddr("stranger");
    address attacker = makeAddr("attacker");

    uint24 constant PACKED_999 = uint24(999) | (uint24(999) << 12);
    uint160 constant PRICE_1 = 79228162514264337593543950336; // tick 0

    function setUp() public {
        initializeTokens();

        vault = new Vault();
        poolManager = new CLPoolManager(vault);
        vault.registerApp(address(poolManager));
        router = new CLPoolManagerRouter(vault, poolManager);

        wrapper = new CLPoolManagerOwner(ICLPoolManagerWithPauseOwnable(address(poolManager)));
        poolManager.transferOwnership(address(wrapper));

        v2 = new DeepCoreProtocolFeeControllerV2(safe, guardian);

        hookA = new MockCLLaunchHook();
        lockerA = new MockLocker();
        kitA = new MockCLLaunchKit(poolManager, hookA, lockerA);

        hookB = new MockCLLaunchHook();
        lockerB = new MockLocker();
        kitB = new MockCLLaunchKit(poolManager, hookB, lockerB);

        address[] memory kits = new address[](2);
        kits[0] = address(kitA);
        kits[1] = address(kitB);
        v4 = new DeepCoreProtocolFeeControllerV4(safe, IProtocolFeeController(address(v2)), kits, new address[](0), 7 days);

        IERC20Minimal(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
    }

    function _install(IProtocolFeeController c) internal {
        wrapper.setProtocolFeeController(c);
        assertEq(address(poolManager.protocolFeeController()), address(c));
    }

    function _launchKey(MockCLLaunchHook hook, int24 tickSpacing) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(hook)),
            poolManager: poolManager,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: bytes32(uint256(1)).setTickSpacing(tickSpacing)
        });
    }

    function _normalKey(uint24 fee) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: fee,
            parameters: bytes32(0).setTickSpacing(60)
        });
    }

    function _stamped(PoolKey memory key) internal view returns (uint24 protocolFee) {
        (,, protocolFee,) = poolManager.getSlot0(key.toId());
    }

    /* =====================================================================
       BIRTH
       ===================================================================== */

    /// The whole reason for V4, against a real manager: a launch of EACH kit is born at zero, a plain
    /// pool pays the policy's fee, and the owner's setter cannot charge either launch.
    function test_Live_BothKits_BornAtZero_PlainPoolCharged_OwnerCannotChargeEither() public {
        _install(v4);

        PoolKey memory launchA = _launchKey(hookA, 60);
        PoolKey memory launchB = _launchKey(hookB, 60);
        PoolKey memory normal = _normalKey(3000);
        assertEq(v2.protocolFeeForPool(launchA), PACKED_999, "V2 alone would stamp 999 on the first kit's");
        assertEq(v2.protocolFeeForPool(launchB), PACKED_999, "and on the second kit's");

        kitA.createLockedLaunch(launchA, PRICE_1);
        kitB.createLockedLaunch(launchB, PRICE_1);
        poolManager.initialize(normal, PRICE_1);

        assertEq(_stamped(launchA), 0, "the first kit's launch is born at zero");
        assertEq(_stamped(launchB), 0, "the second kit's launch is born at zero");
        assertEq(_stamped(normal), PACKED_999, "a plain pool pays the policy's fee");
        assertTrue(lockerA.isLockedPool(launchA.toId()));
        assertTrue(lockerB.isLockedPool(launchB.toId()));
        assertTrue(v4.isLockedLaunchPool(launchA.toId()));
        assertTrue(v4.isLockedLaunchPool(launchB.toId()));
        assertFalse(v4.isLockedLaunchPool(normal.toId()));

        vm.startPrank(safe);
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.LockedLaunchPoolKeepsZeroFee.selector, launchA.toId())
        );
        v4.setPoolProtocolFee(address(poolManager), launchA, PACKED_999);
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.LockedLaunchPoolKeepsZeroFee.selector, launchB.toId())
        );
        v4.setPoolProtocolFee(address(poolManager), launchB, PACKED_999);
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.LockedLaunchPoolKeepsZeroFee.selector, launchB.toId())
        );
        v4.setPoolProtocolFee(address(poolManager), launchB, 1);
        vm.stopPrank();
        assertEq(_stamped(launchA), 0);
        assertEq(_stamped(launchB), 0);

        /* Zero always goes through, and the plain pool is still the owner's to reprice. */
        vm.startPrank(safe);
        v4.setPoolProtocolFee(address(poolManager), launchA, 0);
        v4.setPoolProtocolFee(address(poolManager), launchB, 0);
        v4.setPoolProtocolFee(address(poolManager), normal, 500);
        vm.stopPrank();
        assertEq(_stamped(launchA), 0);
        assertEq(_stamped(launchB), 0);
        assertEq(_stamped(normal), 500);
    }

    /// What V4 replaces. With V3 bound to the NEW kit only, the first kit's launch is born charged
    /// and the owner can stamp a fee on a first-kit pool that was born at zero.
    function test_Live_WhatV3BoundToTheNewKitWouldLose() public {
        DeepCoreProtocolFeeControllerV3 v3NewKitOnly =
            new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(v2)), address(kitB));

        /* A first-kit pool born at zero while a controller that knew its kit was installed. */
        _install(v4);
        PoolKey memory oldLaunch = _launchKey(hookA, 60);
        kitA.createLockedLaunch(oldLaunch, PRICE_1);
        assertEq(_stamped(oldLaunch), 0);

        _install(v3NewKitOnly);
        vm.prank(safe);
        v3NewKitOnly.setPoolProtocolFee(address(poolManager), oldLaunch, PACKED_999);
        assertEq(_stamped(oldLaunch), PACKED_999, "V3 bound to the new kit lets the owner charge the first kit's pool");

        PoolKey memory bornCharged = _launchKey(hookA, 10);
        kitA.createLockedLaunch(bornCharged, PRICE_1);
        assertEq(_stamped(bornCharged), PACKED_999, "and a new first-kit launch is born charged");

        /* V4 back in: the owner repairs both, and cannot break them again. */
        _install(v4);
        vm.startPrank(safe);
        assertEq(v4.syncPoolToPolicy(address(poolManager), oldLaunch), 0);
        assertEq(v4.syncPoolToPolicy(address(poolManager), bornCharged), 0);
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.LockedLaunchPoolKeepsZeroFee.selector, oldLaunch.toId())
        );
        v4.setPoolProtocolFee(address(poolManager), oldLaunch, PACKED_999);
        vm.stopPrank();
        assertEq(_stamped(oldLaunch), 0);
        assertEq(_stamped(bornCharged), 0);
    }

    function test_Live_NormalPool_IsBornWithTheConfiguredFee() public {
        _install(v4);
        PoolKey memory key = _normalKey(3000);
        poolManager.initialize(key, PRICE_1);
        assertEq(_stamped(key), PACKED_999);
    }

    /// The flag must exist when core reads the fee. Written one line later, it is worthless.
    function test_Live_TimingTrap_FlagAfterInitializeIsTooLate() public {
        _install(v4);
        PoolKey memory key = _launchKey(hookB, 60);
        kitB.createLaunchFlaggedTooLate(key, PRICE_1);
        assertEq(_stamped(key), PACKED_999, "core read the fee before the flag existed");
        assertTrue(v4.isLockedLaunchPool(key.toId()), "the flag exists now, and changes nothing");
    }

    /// An unlocked launch through either kit pays the fee.
    function test_Live_UnlockedLaunchThroughAKit_PaysTheFee() public {
        _install(v4);
        PoolKey memory a = _launchKey(hookA, 60);
        PoolKey memory b = _launchKey(hookB, 60);
        kitA.createUnlockedLaunch(a, PRICE_1);
        kitB.createUnlockedLaunch(b, PRICE_1);
        assertEq(_stamped(a), PACKED_999);
        assertEq(_stamped(b), PACKED_999);
    }

    /// If the lock fails the launch reverts, and the flag and the pool go with it.
    function test_Live_LockFailure_RevertsFlagAndPool() public {
        _install(v4);
        PoolKey memory key = _launchKey(hookB, 60);
        lockerB.setFailNext(true);
        vm.expectRevert(bytes("lock failed"));
        kitB.createLockedLaunch(key, PRICE_1);

        assertFalse(kitB.isLockedLaunch(PoolId.unwrap(key.toId())), "flag reverted");
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, 0, "pool reverted");
    }

    /* =====================================================================
       SPOOFING, against the real manager
       ===================================================================== */

    /// A pool on either launch hook that did not come through its kit.
    function test_Live_Spoof_HookPoolNotLaunchedThroughAKit() public {
        _install(v4);
        PoolKey memory a = _launchKey(hookA, 60);
        PoolKey memory b = _launchKey(hookB, 60);
        vm.startPrank(attacker);
        hookA.claim(a);
        poolManager.initialize(a, PRICE_1);
        hookB.claim(b);
        poolManager.initialize(b, PRICE_1);
        vm.stopPrank();
        assertEq(_stamped(a), PACKED_999);
        assertEq(_stamped(b), PACKED_999);
    }

    /// A third kit, identical in code, that V4 does not name.
    function test_Live_Spoof_KitOutsideTheSet() public {
        _install(v4);
        MockCLLaunchKit fake = new MockCLLaunchKit(poolManager, hookA, lockerA);
        PoolKey memory key = _launchKey(hookA, 60);
        fake.createLockedLaunch(key, PRICE_1);
        assertTrue(fake.isLockedLaunch(PoolId.unwrap(key.toId())), "the fake vouches");
        assertFalse(v4.isLaunchOracle(address(fake)));
        assertEq(_stamped(key), PACKED_999, "and nobody listens");
    }

    /// One kit's flag is for its own pool id. It says nothing about the other kit's hook.
    function test_Live_AKitVouchesOnlyForItsOwnPools() public {
        _install(v4);
        PoolKey memory a = _launchKey(hookA, 60);
        kitA.createLockedLaunch(a, PRICE_1);

        PoolKey memory sameShapeOnTheOtherHook = _launchKey(hookB, 60);
        vm.startPrank(attacker);
        hookB.claim(sameShapeOnTheOtherHook);
        poolManager.initialize(sameShapeOnTheOtherHook, PRICE_1);
        vm.stopPrank();
        assertEq(_stamped(a), 0);
        assertEq(_stamped(sameShapeOnTheOtherHook), PACKED_999);
    }

    /* =====================================================================
       MONEY: a launch accrues nothing, a normal pool accrues, the swap keeps the balance
       ===================================================================== */

    function test_Live_SwapOnEitherKitsLaunchAccruesNoProtocolFee() public {
        _install(v4);
        PoolKey memory launchA = _launchKey(hookA, 60);
        PoolKey memory launchB = _launchKey(hookB, 60);
        kitA.createLockedLaunch(launchA, PRICE_1);
        kitB.createLockedLaunch(launchB, PRICE_1);
        _addLiquidity(launchA);
        _addLiquidity(launchB);
        _swap(launchA, true, 1 ether);
        _swap(launchB, true, 1 ether);
        assertEq(poolManager.protocolFeesAccrued(currency0), 0);

        PoolKey memory normal = _normalKey(3000);
        poolManager.initialize(normal, PRICE_1);
        _addLiquidity(normal);
        _swap(normal, true, 1 ether);
        assertGt(poolManager.protocolFeesAccrued(currency0), 0);
    }

    /**
     * The migration, through the real wrapper:
     *   V3 (first kit) installed -> a normal pool accrues fees, a first-kit launch is born at zero
     *   -> swap to V4 -> stamps unchanged, V3 can no longer collect, V4 collects V3's balance,
     *   -> both kits' new launches are born at zero.
     */
    function test_Live_Migration_V3ToV4_PreservesStampsAndAccruedFees() public {
        DeepCoreProtocolFeeControllerV3 v3 =
            new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(v2)), address(kitA));
        _install(v3);

        PoolKey memory normal = _normalKey(3000);
        poolManager.initialize(normal, PRICE_1);
        _addLiquidity(normal);
        _swap(normal, true, 1 ether);
        uint256 accruedUnderV3 = poolManager.protocolFeesAccrued(currency0);
        assertGt(accruedUnderV3, 0);

        PoolKey memory firstKitLaunch = _launchKey(hookA, 10);
        kitA.createLockedLaunch(firstKitLaunch, PRICE_1);
        assertEq(_stamped(firstKitLaunch), 0);

        _install(v4);

        assertEq(_stamped(normal), PACKED_999, "swapping the controller does not restamp");
        assertEq(_stamped(firstKitLaunch), 0, "nor un-zero");
        assertEq(poolManager.protocolFeesAccrued(currency0), accruedUnderV3, "balance untouched");

        vm.prank(stranger);
        vm.expectRevert(IProtocolFees.InvalidCaller.selector);
        v3.sweep(address(poolManager), currency0);

        vm.prank(safe);
        vm.expectRevert(IProtocolFees.InvalidCaller.selector);
        v3.collect(address(poolManager), currency0, 0, safe);

        uint256 before = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(safe);
        vm.prank(stranger);
        uint256 swept = v4.sweep(address(poolManager), currency0);
        assertEq(swept, accruedUnderV3, "V4 collects what accrued under V3");
        assertEq(IERC20Minimal(Currency.unwrap(currency0)).balanceOf(safe) - before, accruedUnderV3);
        assertEq(poolManager.protocolFeesAccrued(currency0), 0);
        assertEq(IERC20Minimal(Currency.unwrap(currency0)).balanceOf(address(v4)), 0, "V4 held nothing on the way");

        vm.prank(safe);
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepCoreProtocolFeeControllerV4.LockedLaunchPoolKeepsZeroFee.selector, firstKitLaunch.toId()
            )
        );
        v4.setPoolProtocolFee(address(poolManager), firstKitLaunch, PACKED_999);

        PoolKey memory newA = _launchKey(hookA, 20);
        PoolKey memory newB = _launchKey(hookB, 20);
        kitA.createLockedLaunch(newA, PRICE_1);
        kitB.createLockedLaunch(newB, PRICE_1);
        assertEq(_stamped(newA), 0);
        assertEq(_stamped(newB), 0);
    }

    /// Only the wrapper's owner (the custody timelock) can install a controller.
    function test_Live_InstallIsCustodyOnly() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, safe));
        wrapper.setProtocolFeeController(v4);

        vm.prank(stranger);
        vm.expectRevert();
        poolManager.setProtocolFeeController(v4);
    }

    /* =====================================================================
       POWERS AND CAPS, against the real manager
       ===================================================================== */

    function test_Live_OwnerRepricingKeepsTheCoreCap() public {
        _install(v4);
        PoolKey memory normal = _normalKey(3000);
        poolManager.initialize(normal, PRICE_1);

        uint24 tooBig = uint24(4001);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(IProtocolFees.ProtocolFeeTooLarge.selector, tooBig));
        v4.setPoolProtocolFee(address(poolManager), normal, tooBig);

        uint24 max = uint24(4000) | (uint24(4000) << 12);
        vm.prank(safe);
        v4.setPoolProtocolFee(address(poolManager), normal, max);
        assertEq(_stamped(normal), max);
    }

    function test_Live_GuardianOnlyReduces() public {
        _install(v4);
        vm.prank(guardian);
        v2.emergencyDisableFees();

        PoolKey memory normal = _normalKey(3000);
        poolManager.initialize(normal, PRICE_1);
        assertEq(_stamped(normal), 0, "a pool born during an incident pays nothing");

        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        v4.setPoolProtocolFee(address(poolManager), normal, PACKED_999);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        v4.syncPoolToPolicy(address(poolManager), normal);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        v4.collect(address(poolManager), currency0, 0, guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        v2.setFeesDisabled(false);
        vm.stopPrank();
    }

    /* ===================================================================== */

    function _addLiquidity(PoolKey memory key) internal {
        router.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: 100 ether,
                salt: bytes32(0)
            }),
            ""
        );
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountIn) internal {
        router.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amountIn,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
    }
}

interface IERC20Minimal {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}
