// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {CLPoolManagerOwner, ICLPoolManagerWithPauseOwnable} from "infinity-core/src/pool-cl/CLPoolManagerOwner.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

import {DeepCoreDynamicFeeHook} from "deepcore-hooks/src/dex/DeepCoreDynamicFeeHook.sol";

import {DeepCoreProtocolFeeControllerV2} from "../src/DeepCoreProtocolFeeControllerV2.sol";
import {DeepCoreProtocolFeeControllerV4} from "../src/DeepCoreProtocolFeeControllerV4.sol";
import {MockLaunchOracle} from "./utils/V3Mocks.sol";

/**
 * REAL core (Vault, CLPoolManager, the owner wrapper), the real V2 as policy, and the REAL
 * `DeepCoreDynamicFeeHook`: V4 lists the hook, and a pool opened on it is born at zero core fee while an
 * identical pool on a second, unlisted instance of the same hook pays V2's 999. The hook still takes
 * its own protocol share on every swap; the core fee is what the list waives. This contract plays the
 * custody timelock: it owns the wrapper.
 */
contract FeeControllerV4ZeroFeeHooksLiveTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    uint24 internal constant PACKED_999 = uint24(999) | (uint24(999) << 12);
    uint32 internal constant NOTICE = 7 days;
    uint256 internal constant T0 = 1_800_000_000;

    Vault internal vault;
    CLPoolManager internal manager;
    CLPoolManagerOwner internal wrapper;
    CLPoolManagerRouter internal router;
    DeepCoreProtocolFeeControllerV2 internal v2;
    DeepCoreProtocolFeeControllerV4 internal v4;
    DeepCoreDynamicFeeHook internal listed;
    DeepCoreDynamicFeeHook internal unlisted;
    Currency internal c0;
    Currency internal c1;

    address internal safe = makeAddr("governanceSafe");
    address internal creator = makeAddr("poolCreator");

    function setUp() public {
        vm.warp(T0);
        vault = new Vault();
        manager = new CLPoolManager(vault);
        vault.registerApp(address(manager));
        router = new CLPoolManagerRouter(vault, manager);
        wrapper = new CLPoolManagerOwner(ICLPoolManagerWithPauseOwnable(address(manager)));
        manager.transferOwnership(address(wrapper));

        v2 = new DeepCoreProtocolFeeControllerV2(safe, makeAddr("guardian"));
        listed = _hook();
        unlisted = _hook();

        address[] memory kits = new address[](1);
        kits[0] = address(new MockLaunchOracle());
        address[] memory hooks = new address[](1);
        hooks[0] = address(listed);
        v4 = new DeepCoreProtocolFeeControllerV4(safe, IProtocolFeeController(address(v2)), kits, hooks, NOTICE);
        wrapper.setProtocolFeeController(v4);

        (c0, c1) = deployCurrencies(2 ** 250);
        IERC20(Currency.unwrap(c0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(c1)).approve(address(router), type(uint256).max);
    }

    function _hook() internal returns (DeepCoreDynamicFeeHook) {
        return new DeepCoreDynamicFeeHook(manager, IVault(address(vault)), safe, safe, 50_000, 1_500, 3_000, NOTICE, 1 days, 500);
    }

    function _cfg() internal pure returns (DeepCoreDynamicFeeHook.FeeConfig memory c) {
        c.baseFee = 3_000;
        c.volSlope = 10;
        c.sameSecondSlope = 50;
        c.minBaseFee = 500;
        c.maxBaseFee = 10_000;
        c.maxVolSlope = 40;
        c.maxSameSecondSlope = 100;
        c.maxFee = 30_000;
        c.volCap = 2_000;
        c.decaySeconds = 1_800;
        c.deadband = 5;
        c.maxBaseFeeStep = 500;
        c.maxSlopeStep = 5;
        c.minTuneInterval = 3_600;
        c.tuner = address(0);
    }

    function _open(DeepCoreDynamicFeeHook hook, int24 spacing) internal returns (PoolKey memory k) {
        k = PoolKey({
            currency0: c0,
            currency1: c1,
            hooks: IHooks(address(hook)),
            poolManager: manager,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: CLPoolParametersHelper.setTickSpacing(bytes32(uint256(hook.getHooksRegistrationBitmap())), spacing)
        });
        vm.prank(creator);
        hook.configure(k, _cfg(), 3_000);
        manager.initialize(k, SQRT_RATIO_1_1);
        router.modifyPosition(
            k,
            ICLPoolManager.ModifyLiquidityParams({tickLower: -6_000, tickUpper: 6_000, liquidityDelta: 1_000_000 ether, salt: 0}),
            ZERO_BYTES
        );
    }

    function _swap(PoolKey memory k) internal {
        router.swap(
            k,
            ICLPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1}),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ZERO_BYTES
        );
    }

    function _stamped(PoolKey memory k) internal view returns (uint24 protocolFee) {
        (,, protocolFee,) = manager.getSlot0(k.toId());
    }

    function test_Live_ListedHookPoolIsBornAtZero_UnlistedPays_HookStillTakesItsShare() public {
        PoolKey memory onListed = _open(listed, 60);
        PoolKey memory onUnlisted = _open(unlisted, 60);
        assertEq(_stamped(onListed), 0, "a listed hook's pool is born at zero core fee");
        assertEq(_stamped(onUnlisted), PACKED_999, "the same hook, unlisted, pays V2's fee");

        uint256 coreBefore = manager.protocolFeesAccrued(c0);
        _swap(onListed);
        assertEq(manager.protocolFeesAccrued(c0), coreBefore, "no core fee on the listed hook's pool");
        assertGt(listed.protocolTaken(c1) + listed.protocolTaken(c0), 0, "the hook's own share is still taken");

        _swap(onUnlisted);
        assertGt(manager.protocolFeesAccrued(c0), coreBefore, "the unlisted pool pays the core fee");
    }

    function test_Live_OwnerCannotChargeWhileListed_RemovalRepricesNewPoolsOnly() public {
        PoolKey memory born = _open(listed, 60);
        vm.startPrank(safe);
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.ZeroFeeHookPoolKeepsZeroFee.selector, born.toId(), address(listed))
        );
        v4.setPoolProtocolFee(address(manager), born, PACKED_999);
        v4.scheduleZeroFeeHookRemoval(address(listed));
        vm.stopPrank();

        /* One second before the notice a new pool is still born at zero. */
        vm.warp(block.timestamp + NOTICE - 1);
        assertEq(_stamped(_open(listed, 10)), 0);

        /* At the notice, by time alone: new pools pay; pools born earlier keep their zero until synced. */
        vm.warp(block.timestamp + 1);
        PoolKey memory late = _open(listed, 20);
        assertEq(_stamped(late), PACKED_999, "a pool born after the removal pays");
        assertEq(_stamped(born), 0, "a pool born while listed keeps its zero");
        vm.prank(safe);
        assertEq(v4.syncPoolToPolicy(address(manager), born), PACKED_999);
        assertEq(_stamped(born), PACKED_999);
    }

    function test_Live_AddingAHookZeroesItsNewPools_SyncZeroesItsOldOnes() public {
        PoolKey memory before = _open(unlisted, 60);
        assertEq(_stamped(before), PACKED_999);
        vm.prank(safe);
        v4.addZeroFeeHook(address(unlisted));
        assertEq(_stamped(_open(unlisted, 10)), 0, "a new pool after the add is born at zero");
        assertEq(_stamped(before), PACKED_999, "an old pool is not touched by the add");
        vm.prank(safe);
        v4.syncPoolToPolicy(address(manager), before);
        assertEq(_stamped(before), 0, "sync brings the old pool to zero");
    }
}
