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
import {MockCLLaunchHook, MockLocker, MockCLLaunchKit} from "./utils/LaunchFixtures.sol";

/**
 * REAL core: Vault, CLPoolManager, CLPoolManagerOwner (the wrapper that holds fee authority on
 * chain), the real V2 as policy, and V3. Only the launchpad side is a fixture, because the real kit
 * and hook are being rewritten and V3 depends on nothing of theirs but `isLockedLaunch(bytes32)`.
 *
 * This test contract plays the custody timelock: it owns the wrapper.
 */
contract FeeControllerV3LiveTest is Test, TokenFixture {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    Vault vault;
    CLPoolManager poolManager;
    CLPoolManagerOwner wrapper;
    CLPoolManagerRouter router;
    DeepCoreProtocolFeeControllerV2 v2;
    DeepCoreProtocolFeeControllerV3 v3;

    MockCLLaunchHook hook;
    MockLocker locker;
    MockCLLaunchKit kit;

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

        hook = new MockCLLaunchHook();
        locker = new MockLocker();
        kit = new MockCLLaunchKit(poolManager, hook, locker);
        v3 = new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(v2)), address(kit));

        IERC20Minimal(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
    }

    function _install(IProtocolFeeController c) internal {
        wrapper.setProtocolFeeController(c);
        assertEq(address(poolManager.protocolFeeController()), address(c));
    }

    function _launchKey(int24 tickSpacing) internal view returns (PoolKey memory) {
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

    function test_Live_KitLockedLaunch_IsBornAtZero() public {
        _install(v3);
        PoolKey memory key = _launchKey(60);
        assertEq(v2.protocolFeeForPool(key), PACKED_999, "V2 alone would stamp 999");

        kit.createLockedLaunch(key, PRICE_1);

        assertEq(_stamped(key), 0, "born at zero");
        assertTrue(locker.isLockedPool(key.toId()));
        assertTrue(v3.isLockedLaunchPool(key.toId()));
    }

    function test_Live_NormalPool_IsBornWithTheConfiguredFee() public {
        _install(v3);
        PoolKey memory key = _normalKey(3000);
        poolManager.initialize(key, PRICE_1);
        assertEq(_stamped(key), PACKED_999);
    }

    /// The flag must exist when core reads the fee. Written one line later, it is worthless.
    function test_Live_TimingTrap_FlagAfterInitializeIsTooLate() public {
        _install(v3);
        PoolKey memory key = _launchKey(60);
        kit.createLaunchFlaggedTooLate(key, PRICE_1);
        assertEq(_stamped(key), PACKED_999, "core read the fee before the flag existed");
        assertTrue(v3.isLockedLaunchPool(key.toId()), "the flag exists now, and changes nothing");
    }

    /// An unlocked launch through the same kit pays the fee.
    function test_Live_UnlockedLaunchThroughTheKit_PaysTheFee() public {
        _install(v3);
        PoolKey memory key = _launchKey(60);
        kit.createUnlockedLaunch(key, PRICE_1);
        assertEq(_stamped(key), PACKED_999);
    }

    /// If the lock fails the launch reverts, and the flag and the pool go with it.
    function test_Live_LockFailure_RevertsFlagAndPool() public {
        _install(v3);
        PoolKey memory key = _launchKey(60);
        locker.setFailNext(true);
        vm.expectRevert(bytes("lock failed"));
        kit.createLockedLaunch(key, PRICE_1);

        assertFalse(kit.isLockedLaunch(PoolId.unwrap(key.toId())), "flag reverted");
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, 0, "pool reverted");
    }

    /* =====================================================================
       SPOOFING, against the real manager
       ===================================================================== */

    /// A pool on the launch hook that did not come through the kit.
    function test_Live_Spoof_HookPoolNotLaunchedThroughTheKit() public {
        _install(v3);
        PoolKey memory key = _launchKey(60);
        vm.startPrank(attacker);
        hook.claim(key);
        poolManager.initialize(key, PRICE_1);
        vm.stopPrank();
        assertEq(_stamped(key), PACKED_999);
    }

    /// A second kit, identical in code, that V3 is not bound to.
    function test_Live_Spoof_FakeKit() public {
        _install(v3);
        MockCLLaunchKit fake = new MockCLLaunchKit(poolManager, hook, locker);
        PoolKey memory key = _launchKey(60);
        fake.createLockedLaunch(key, PRICE_1);
        assertTrue(fake.isLockedLaunch(PoolId.unwrap(key.toId())), "the fake vouches");
        assertEq(_stamped(key), PACKED_999, "and nobody listens");
    }

    /// Someone else claims (reserves) the kit's predicted pool id and creates it first: born charged,
    /// and the kit's own launch then reverts with its flag. No fee dodged in either order.
    function test_Live_Spoof_PoolIdReservedBySomeoneElse() public {
        _install(v3);
        PoolKey memory key = _launchKey(60);
        vm.startPrank(attacker);
        hook.claim(key);
        poolManager.initialize(key, PRICE_1);
        vm.stopPrank();

        vm.expectRevert();
        kit.createLockedLaunch(key, PRICE_1);
        assertFalse(kit.isLockedLaunch(PoolId.unwrap(key.toId())));
        assertEq(_stamped(key), PACKED_999);
    }

    /// Claimed but not yet initialized by the attacker: the kit cannot take it, nothing is stamped.
    function test_Live_Spoof_ClaimOnlySquat_BlocksTheKitButDodgesNothing() public {
        _install(v3);
        PoolKey memory key = _launchKey(60);
        vm.prank(attacker);
        hook.claim(key);

        vm.expectRevert(bytes("claimed"));
        kit.createLockedLaunch(key, PRICE_1);

        vm.prank(attacker);
        poolManager.initialize(key, PRICE_1);
        assertEq(_stamped(key), PACKED_999);
    }

    /* =====================================================================
       MONEY: a launch accrues nothing, a normal pool accrues, the swap keeps V2's balance
       ===================================================================== */

    function test_Live_SwapOnALockedLaunchAccruesNoProtocolFee() public {
        _install(v3);
        PoolKey memory launch = _launchKey(60);
        kit.createLockedLaunch(launch, PRICE_1);
        _addLiquidity(launch);
        _swap(launch, true, 1 ether);
        assertEq(poolManager.protocolFeesAccrued(currency0), 0);

        PoolKey memory normal = _normalKey(3000);
        poolManager.initialize(normal, PRICE_1);
        _addLiquidity(normal);
        _swap(normal, true, 1 ether);
        assertGt(poolManager.protocolFeesAccrued(currency0), 0);
    }

    /**
     * The migration, through the real wrapper:
     *   V2 installed -> a normal pool accrues fees, a kit launch is created (the interim state)
     *   -> swap to V3 -> stamps unchanged, V2 can no longer collect, V3 collects V2's balance,
     *   -> the Safe fixes the interim launch with syncPoolToPolicy, and new launches are born at zero.
     */
    function test_Live_Migration_V2ToV3_PreservesStampsAndAccruedFees() public {
        _install(v2);

        PoolKey memory normal = _normalKey(3000);
        poolManager.initialize(normal, PRICE_1);
        _addLiquidity(normal);
        _swap(normal, true, 1 ether);
        uint256 accruedUnderV2 = poolManager.protocolFeesAccrued(currency0);
        assertGt(accruedUnderV2, 0);

        PoolKey memory interimLaunch = _launchKey(10);
        kit.createLockedLaunch(interimLaunch, PRICE_1);
        assertEq(_stamped(interimLaunch), PACKED_999, "V2 has no zero rule");

        _install(v3);

        assertEq(_stamped(normal), PACKED_999, "swapping the controller does not restamp");
        assertEq(_stamped(interimLaunch), PACKED_999, "nor un-stamp");
        assertEq(poolManager.protocolFeesAccrued(currency0), accruedUnderV2, "balance untouched");

        vm.prank(stranger);
        vm.expectRevert(IProtocolFees.InvalidCaller.selector);
        v2.sweep(address(poolManager), currency0);

        vm.prank(safe);
        vm.expectRevert(IProtocolFees.InvalidCaller.selector);
        v2.collect(address(poolManager), currency0, 0, safe);

        uint256 before = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(safe);
        vm.prank(stranger);
        uint256 swept = v3.sweep(address(poolManager), currency0);
        assertEq(swept, accruedUnderV2, "V3 collects what accrued under V2");
        assertEq(IERC20Minimal(Currency.unwrap(currency0)).balanceOf(safe) - before, accruedUnderV2);
        assertEq(poolManager.protocolFeesAccrued(currency0), 0);

        vm.prank(safe);
        assertEq(v3.syncPoolToPolicy(address(poolManager), interimLaunch), 0);
        assertEq(_stamped(interimLaunch), 0, "the interim launch is fixed by the owner, per pool");

        vm.prank(safe);
        assertEq(v3.syncPoolToPolicy(address(poolManager), normal), PACKED_999, "normal pools keep policy");

        PoolKey memory newLaunch = _launchKey(20);
        kit.createLockedLaunch(newLaunch, PRICE_1);
        assertEq(_stamped(newLaunch), 0);
    }

    /// Only the wrapper's owner (the custody timelock) can install a controller.
    function test_Live_InstallIsCustodyOnly() public {
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, safe));
        wrapper.setProtocolFeeController(v3);

        vm.prank(stranger);
        vm.expectRevert();
        poolManager.setProtocolFeeController(v3);
    }

    /* =====================================================================
       POWERS AND CAPS, against the real manager
       ===================================================================== */

    function test_Live_OwnerRepricingKeepsTheCoreCap() public {
        _install(v3);
        PoolKey memory normal = _normalKey(3000);
        poolManager.initialize(normal, PRICE_1);

        uint24 tooBig = uint24(4001);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(IProtocolFees.ProtocolFeeTooLarge.selector, tooBig));
        v3.setPoolProtocolFee(address(poolManager), normal, tooBig);

        uint24 max = uint24(4000) | (uint24(4000) << 12);
        vm.prank(safe);
        v3.setPoolProtocolFee(address(poolManager), normal, max);
        assertEq(_stamped(normal), max);
    }

    /// The Safe's escape hatch stops at a kit-flagged pool (acceptance finding B): a locked launch pool
    /// may only ever be set to 0 by this controller, against the real manager.
    function test_Live_OwnerEscapeHatchCannotChargeALaunchPool() public {
        _install(v3);
        PoolKey memory launch = _launchKey(60);
        kit.createLockedLaunch(launch, PRICE_1);
        assertEq(_stamped(launch), 0);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV3.LockedLaunchPoolKeepsZeroFee.selector, launch.toId()));
        v3.setPoolProtocolFee(address(poolManager), launch, PACKED_999);
        assertEq(_stamped(launch), 0);
        vm.prank(safe);
        v3.setPoolProtocolFee(address(poolManager), launch, 0);
        assertEq(_stamped(launch), 0);
    }

    function test_Live_GuardianOnlyReduces() public {
        _install(v3);
        vm.prank(guardian);
        v2.emergencyDisableFees();

        PoolKey memory normal = _normalKey(3000);
        poolManager.initialize(normal, PRICE_1);
        assertEq(_stamped(normal), 0, "a pool born during an incident pays nothing");

        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        v3.setPoolProtocolFee(address(poolManager), normal, PACKED_999);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        v3.syncPoolToPolicy(address(poolManager), normal);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        v3.collect(address(poolManager), currency0, 0, guardian);
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
