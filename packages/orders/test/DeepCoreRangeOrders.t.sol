// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPosition} from "infinity-core/src/pool-cl/libraries/CLPosition.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {LaunchGuardHook, ILaunchTokenOrigin} from "deepcore-hooks/src/launch/LaunchGuardHook.sol";
import {DeepCoreRangeOrders} from "../src/DeepCoreRangeOrders.sol";
import {OrdersFeeBase} from "../src/base/OrdersFeeBase.sol";
import {OrdersFixture} from "./OrdersFixture.sol";
import {FeeOnTransferToken, ReentrantReceiver} from "./mocks/Mocks.sol";

contract DeepCoreRangeOrdersTest is OrdersFixture {
    using CLPoolParametersHelper for bytes32;

    int24 internal constant ABOVE = 100; // sell currency0 here (price at tick 0)
    int24 internal constant BELOW = -110; // sell currency1 here

    /*//////////////////////////////////////////////////////////////
                                 PLACE
    //////////////////////////////////////////////////////////////*/

    function test_place_sellAbove_opensEpochAndHoldsTip() public {
        uint256 before = t0.balanceOf(ALICE);
        (uint256 orderId, uint256 epochId, uint128 liq) = _place(ALICE, keyCL, ABOVE, true, 1e18, 1e15);
        assertEq(orderId, 1);
        assertEq(epochId, 1);
        assertGt(liq, 0);
        // the maker paid at most amount + tip; the unused rounding came back
        uint256 paid = before - t0.balanceOf(ALICE);
        assertLe(paid, 1e18 + 1e15);
        assertGe(paid, 1e18 + 1e15 - 2);
        DeepCoreRangeOrders.Epoch memory e = orders.getEpoch(epochId);
        assertEq(e.liquidity, liq);
        assertEq(e.tipTotal, 1e15);
        assertEq(orders.totalOwed(c0), 1e15, "only the tip is a balance; principal is pool liquidity");
        assertEq(t0.balanceOf(address(orders)), 1e15);
        CLPosition.Info memory pos = cl.getPosition(keyCL.toId(), address(orders), ABOVE, ABOVE + SPACING, bytes32(epochId));
        assertEq(pos.liquidity, liq, "core position == epoch liquidity");
        assertEq(orders.openEpochOf(keyCL.toId(), ABOVE, true), epochId);
        DeepCoreRangeOrders.Order memory o = orders.getOrder(orderId);
        assertEq(o.maker, ALICE);
        assertEq(o.feeBps, FEE_BPS);
    }

    function test_place_secondMakerJoinsSameEpoch() public {
        (, uint256 e1, uint128 l1) = _place(ALICE, keyCL, ABOVE, true, 1e18, 0);
        (, uint256 e2, uint128 l2) = _place(BOB, keyCL, ABOVE, true, 3e18, 0);
        assertEq(e1, e2);
        assertEq(orders.getEpoch(e1).liquidity, l1 + l2);
    }

    function test_place_sellBelow() public {
        (,, uint128 liq) = _place(ALICE, keyCL, BELOW, false, 2e18, 0);
        assertGt(liq, 0);
    }

    function test_place_refusesInRange() public {
        vm.expectRevert(abi.encodeWithSelector(DeepCoreRangeOrders.OrderInRange.selector, int24(0), int24(0)));
        _place(ALICE, keyCL, 0, true, 1e18, 0);
        // sell1 at a level whose upper edge is above the tick
        vm.expectRevert(abi.encodeWithSelector(DeepCoreRangeOrders.OrderInRange.selector, int24(0), int24(0)));
        _place(ALICE, keyCL, 0, false, 1e18, 0);
        // a sell1 whose upper edge IS the tick is fully currency1: valid
        _place(ALICE, keyCL, -10, false, 1e18, 0);
        // sell0 below the price is a market sell, not an order
        vm.expectRevert(abi.encodeWithSelector(DeepCoreRangeOrders.OrderInRange.selector, int24(0), int24(-100)));
        _place(ALICE, keyCL, -100, true, 1e18, 0);
    }

    function test_place_refusesUnaligned() public {
        vm.expectRevert(abi.encodeWithSelector(DeepCoreRangeOrders.LevelNotAligned.selector, int24(105), SPACING));
        _place(ALICE, keyCL, 105, true, 1e18, 0);
    }

    function test_place_refusesForeignManager() public {
        PoolKey memory k = keyCL;
        k.poolManager = IPoolManager(address(bin));
        vm.expectRevert(DeepCoreRangeOrders.WrongPoolManager.selector);
        _place(ALICE, k, ABOVE, true, 1e18, 0);
    }

    function test_place_refusesEveryTrapBit() public {
        uint8[4] memory bits = [uint8(4), 5, 12, 13];
        for (uint256 i; i < bits.length; ++i) {
            PoolKey memory k = keyCL;
            k.parameters = bytes32(uint256(k.parameters) | (uint256(1) << bits[i]));
            vm.expectRevert(abi.encodeWithSelector(DeepCoreRangeOrders.HookCanTrapLiquidity.selector, uint16(1) << bits[i]));
            _place(ALICE, k, ABOVE, true, 1e18, 0);
        }
    }

    /*//////////////////////////////////////////////////////////////
                    LAUNCH POOLS ARE REFUSED (owner, 2026-10-13)
    //////////////////////////////////////////////////////////////*/

    function test_launch_refusesEveryGuardBitmap() public {
        uint16[3] memory maps = [uint16(0x0041), 0x08C1, 0x0CC1];
        for (uint256 i; i < maps.length; ++i) {
            PoolKey memory k = keyCL;
            k.hooks = IHooks(address(0xBEEF));
            k.parameters = bytes32(uint256(maps[i])).setTickSpacing(SPACING);
            assertTrue(orders.isLaunchPool(k));
            vm.expectRevert(abi.encodeWithSelector(DeepCoreRangeOrders.LaunchPoolNotSupported.selector, address(0xBEEF)));
            _place(ALICE, k, ABOVE, true, 1e18, 0);
        }
    }

    function test_launch_refusesAListedGuardWhateverItsBitmap() public {
        PoolKey memory k = keyCL;
        k.hooks = IHooks(LISTED_GUARD);
        k.parameters = bytes32(uint256(1 << 7)).setTickSpacing(SPACING); // not a guard bitmap
        assertTrue(orders.isLaunchPool(k));
        vm.expectRevert(abi.encodeWithSelector(DeepCoreRangeOrders.LaunchPoolNotSupported.selector, LISTED_GUARD));
        _place(ALICE, k, ABOVE, true, 1e18, 0);
        assertTrue(orders.isLaunchGuard(LISTED_GUARD));
        assertFalse(orders.isLaunchGuard(address(0xBEEF)));
    }

    function test_launch_refusesTheRealGuardsOwnKey() public {
        // the real CL launch guard from packages/hooks, at an address this contract was never told about
        LaunchGuardHook guard =
            new LaunchGuardHook(ICLPoolManager(address(cl)), ILaunchTokenOrigin(address(0x1234)), SAFE, 2000);
        uint16 bitmap = guard.getHooksRegistrationBitmap();
        assertEq(bitmap, 0x0CC1, "the guard generation DeepCore deploys");
        PoolKey memory k = keyCL;
        k.hooks = IHooks(address(guard));
        k.fee = 0x800000; // launch pools are dynamic-fee
        k.parameters = bytes32(uint256(bitmap)).setTickSpacing(SPACING);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreRangeOrders.LaunchPoolNotSupported.selector, address(guard)));
        _place(ALICE, k, ABOVE, true, 1e18, 0);
    }

    function test_launch_ordinaryPoolsAreNotLaunchPools() public view {
        assertFalse(orders.isLaunchPool(keyCL));
        assertFalse(orders.isLaunchPool(keyNative));
        PoolKey memory k = keyCL;
        k.hooks = IHooks(address(0xBEEF));
        k.parameters = bytes32(uint256(0x08C0)).setTickSpacing(SPACING); // a DEX hook taxing swaps, no beforeInitialize
        assertFalse(orders.isLaunchPool(k));
    }

    function test_launch_constructorRefusesZeroAndTooManyGuards() public {
        address[] memory g = new address[](1);
        vm.expectRevert(OrdersFeeBase.ZeroAddress.selector);
        new DeepCoreRangeOrders(ICLPoolManager(address(cl)), SAFE, SAFE, 10, 50, NOTICE, g);
        g = new address[](17);
        vm.expectRevert(DeepCoreRangeOrders.TooManyLaunchGuards.selector);
        new DeepCoreRangeOrders(ICLPoolManager(address(cl)), SAFE, SAFE, 10, 50, NOTICE, g);
    }

    function test_place_refusesUninitialisedPool() public {
        PoolKey memory k = keyCL;
        k.fee = 500;
        vm.expectRevert(DeepCoreRangeOrders.PoolNotInitialized.selector);
        _place(ALICE, k, ABOVE, true, 1e18, 0);
    }

    function test_place_refusesZeroAndBadValueAndIntegrator() public {
        vm.expectRevert(DeepCoreRangeOrders.ZeroAmount.selector);
        _place(ALICE, keyCL, ABOVE, true, 0, 0);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreRangeOrders.WrongValue.selector, 0, 1));
        orders.place{value: 1}(_params(keyCL, ABOVE, true, 1e18));
        vm.expectRevert(abi.encodeWithSelector(OrdersFeeBase.IntegratorBpsAboveCap.selector, uint16(11)));
        _placeWith(ALICE, keyCL, ABOVE, true, 1e18, 0, SITE, 11);
        vm.expectRevert(OrdersFeeBase.IntegratorMissing.selector);
        _placeWith(ALICE, keyCL, ABOVE, true, 1e18, 0, address(0), 5);
    }

    function test_place_refusesFeeOnTransfer() public {
        FeeOnTransferToken tax = new FeeOnTransferToken();
        (Currency a, Currency b) = address(tax) < address(t1) ? (Currency.wrap(address(tax)), c1) : (c1, Currency.wrap(address(tax)));
        PoolKey memory k = PoolKey(a, b, IHooks(address(0)), IPoolManager(address(cl)), 3000, bytes32(0).setTickSpacing(SPACING));
        cl.initialize(k, SQRT_1_1);
        tax.mint(ALICE, 1e20);
        vm.prank(ALICE);
        tax.approve(address(orders), type(uint256).max);
        bool taxIs0 = Currency.unwrap(a) == address(tax);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreRangeOrders.FeeOnTransferUnsupported.selector, 1e18, 99e16));
        _place(ALICE, k, taxIs0 ? ABOVE : BELOW, taxIs0, 1e18, 0);
    }

    function test_place_nativeNeedsExactValue() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreRangeOrders.WrongValue.selector, 1e18 + 5, 1e18));
        DeepCoreRangeOrders.PlaceParams memory p = _params(keyNative, ABOVE, true, 1e18);
        p.tip = 5;
        orders.place{value: 1e18}(p);
    }

    function test_place_refusedWhilePausedButExitsWork() public {
        (uint256 id,,) = _place(ALICE, keyCL, ABOVE, true, 1e18, 0);
        cl.pause();
        vm.expectRevert(ICLPoolManager.PoolPaused.selector);
        _place(BOB, keyCL, ABOVE, true, 1e18, 0);
        vm.prank(ALICE);
        orders.cancel(id, ALICE);
    }

    /*//////////////////////////////////////////////////////////////
                             FILL / WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function test_fill_executePaysTipAndWithdrawChargesFee() public {
        (uint256 id, uint256 epochId,) = _placeWith(ALICE, keyCL, ABOVE, true, 1e18, 1e15, SITE, 5);
        assertFalse(orders.isCrossed(epochId));
        vm.expectRevert(DeepCoreRangeOrders.NotCrossed.selector);
        orders.execute(epochId);

        _swapToTick(keyCL, ABOVE + SPACING);
        assertTrue(orders.isCrossed(epochId));
        uint256 keeperBefore = t0.balanceOf(KEEPER);
        vm.prank(KEEPER);
        (uint256 proceeds, uint256 tip) = orders.execute(epochId);
        assertEq(tip, 1e15);
        assertEq(t0.balanceOf(KEEPER) - keeperBefore, 1e15, "tip in the input currency");
        assertGt(proceeds, 1e18, "sold above 1.0");
        assertEq(orders.openEpochOf(keyCL.toId(), ABOVE, true), 0);
        CLPosition.Info memory pos = cl.getPosition(keyCL.toId(), address(orders), ABOVE, ABOVE + SPACING, bytes32(epochId));
        assertEq(pos.liquidity, 0, "filled epoch's position is empty");

        vm.expectRevert(DeepCoreRangeOrders.EpochAlreadyFilled.selector);
        orders.execute(epochId);

        uint256 lpFees1 = orders.getEpoch(epochId).held1 - proceeds; // the crossing swap paid LP fees in currency1
        uint256 aliceBefore = t1.balanceOf(ALICE);
        vm.prank(ALICE);
        (uint256 a0, uint256 a1) = orders.withdraw(id, ALICE);
        uint256 fee = proceeds * FEE_BPS / 10_000;
        uint256 integ = proceeds * 5 / 10_000;
        assertApproxEqAbs(a1, proceeds - fee - integ + lpFees1, 1, "proceeds less both fees, plus the uncharged LP fees");
        assertEq(a0, 0);
        assertEq(t1.balanceOf(ALICE) - aliceBefore, a1);
        // + at most a wei of rounding dust retired to the protocol when the last maker left
        assertApproxEqAbs(orders.protocolOwed(c1), fee, 1);
        assertEq(orders.integratorOwed(SITE, c1), integ);

        uint256 owed = orders.protocolOwed(c1);
        orders.flushProtocolFees(c1);
        assertEq(t1.balanceOf(SAFE), owed, "flush pays exactly what is owed");
        vm.prank(SITE);
        orders.claimIntegratorFees(c1, SITE);
        assertEq(orders.totalOwed(c1), 0);
        assertEq(orders.totalOwed(c0), 0);
    }

    function test_fill_twoMakersProRata() public {
        (uint256 a,uint256 epochId,) = _place(ALICE, keyCL, ABOVE, true, 1e18, 0);
        (uint256 b,,) = _place(BOB, keyCL, ABOVE, true, 3e18, 0);
        _swapToTick(keyCL, ABOVE + SPACING);
        orders.execute(epochId);
        uint256 held = orders.getEpoch(epochId).held1;
        vm.prank(ALICE);
        (, uint256 outA) = orders.withdraw(a, ALICE);
        vm.prank(BOB);
        (, uint256 outB) = orders.withdraw(b, BOB);
        assertApproxEqRel(outB, outA * 3, 1e12);
        assertLe(outA + outB, held);
        assertEq(orders.getEpoch(epochId).held1, 0, "dust retired to protocol when the last maker leaves");
        assertLe(t1.balanceOf(address(orders)), orders.totalOwed(c1) + 0);
        assertEq(t1.balanceOf(address(orders)), orders.totalOwed(c1));
    }

    function test_fill_sellBelow_paysCurrency0() public {
        (uint256 id, uint256 epochId,) = _place(ALICE, keyCL, BELOW, false, 1e18, 0);
        _swapToTick(keyCL, BELOW - 1);
        assertTrue(orders.isCrossed(epochId));
        orders.execute(epochId);
        vm.prank(ALICE);
        (uint256 a0, uint256 a1) = orders.withdraw(id, ALICE);
        assertGt(a0, 0);
        assertEq(a1, 0);
    }

    function test_fill_exactBoundaries() public {
        (, uint256 epochId,) = _place(ALICE, keyCL, ABOVE, true, 1e18, 0);
        _swapToTick(keyCL, ABOVE + SPACING - 1);
        assertFalse(orders.isCrossed(epochId), "one tick short of the upper edge is not a fill");
        _swapToTick(keyCL, ABOVE + SPACING);
        assertEq(_tick(keyCL), ABOVE + SPACING);
        assertTrue(orders.isCrossed(epochId), "tick == tickUpper is a fill");
    }

    function test_fill_sellBelow_tickEqualLowerIsNotAFill() public {
        (, uint256 epochId,) = _place(ALICE, keyCL, BELOW, false, 1e18, 0);
        _swapToTick(keyCL, BELOW - 20);
        assertTrue(orders.isCrossed(epochId));
        // back up to the lower edge exactly: tick == tickLower is IN range by core's rule
        _swapToTick(keyCL, BELOW);
        assertEq(_tick(keyCL), BELOW);
        assertFalse(orders.isCrossed(epochId), "tick == tickLower is in range, not a fill");
        vm.expectRevert(DeepCoreRangeOrders.NotCrossed.selector);
        orders.execute(epochId);
    }

    function test_unfill_priceReturnsBeforeExecution() public {
        (, uint256 epochId,) = _place(ALICE, keyCL, ABOVE, true, 1e18, 0);
        _swapToTick(keyCL, ABOVE + SPACING + 50);
        _swapToTick(keyCL, 0);
        assertFalse(orders.isCrossed(epochId));
        vm.expectRevert(DeepCoreRangeOrders.NotCrossed.selector);
        orders.execute(epochId);
    }

    function test_withdraw_refusals() public {
        (uint256 id, uint256 epochId,) = _place(ALICE, keyCL, ABOVE, true, 1e18, 0);
        vm.prank(ALICE);
        vm.expectRevert(DeepCoreRangeOrders.EpochNotFilled.selector);
        orders.withdraw(id, ALICE);
        _swapToTick(keyCL, ABOVE + SPACING);
        orders.execute(epochId);
        vm.prank(BOB);
        vm.expectRevert(DeepCoreRangeOrders.NotMaker.selector);
        orders.withdraw(id, BOB);
        vm.prank(ALICE);
        vm.expectRevert(DeepCoreRangeOrders.EpochAlreadyFilled.selector);
        orders.cancel(id, ALICE);
        vm.prank(ALICE);
        orders.withdraw(id, ALICE);
        vm.prank(ALICE);
        vm.expectRevert(DeepCoreRangeOrders.UnknownOrder.selector);
        orders.withdraw(id, ALICE);
    }

    function test_newEpochAfterFill() public {
        (, uint256 e1,) = _place(ALICE, keyCL, ABOVE, true, 1e18, 0);
        _swapToTick(keyCL, ABOVE + SPACING);
        orders.execute(e1);
        _swapToTick(keyCL, 0);
        (, uint256 e2,) = _place(BOB, keyCL, ABOVE, true, 1e18, 0);
        assertEq(e2, e1 + 1);
    }

    function test_executeMany_skipsUncrossed() public {
        (, uint256 e1,) = _place(ALICE, keyCL, ABOVE, true, 1e18, 1e12);
        (, uint256 e2,) = _place(ALICE, keyCL, 500, true, 1e18, 1e12);
        _swapToTick(keyCL, ABOVE + SPACING);
        uint256[] memory ids = new uint256[](4);
        ids[0] = e1;
        ids[1] = e2;
        ids[2] = 999;
        ids[3] = e1;
        vm.prank(KEEPER);
        uint256 n = orders.executeMany(ids);
        assertEq(n, 1);
        assertTrue(orders.getEpoch(e1).filled);
        assertFalse(orders.getEpoch(e2).filled);
    }

    function test_native_sellAbove_fillAndWithdraw() public {
        (uint256 id, uint256 epochId,) = _place(ALICE, keyNative, ABOVE, true, 1e18, 1e15);
        assertEq(address(orders).balance, 1e15);
        _swapToTick(keyNative, ABOVE + SPACING);
        uint256 k = KEEPER.balance;
        vm.prank(KEEPER);
        orders.execute(epochId);
        assertEq(KEEPER.balance - k, 1e15, "native tip");
        vm.prank(ALICE);
        (, uint256 out) = orders.withdraw(id, ALICE);
        assertGt(out, 0);
        assertEq(address(orders).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                                 CANCEL
    //////////////////////////////////////////////////////////////*/

    function test_cancel_untouchedRefundsAllFree() public {
        uint256 before = t0.balanceOf(ALICE);
        (uint256 id,,) = _place(ALICE, keyCL, ABOVE, true, 1e18, 1e15);
        vm.prank(ALICE);
        (uint256 a0, uint256 a1) = orders.cancel(id, ALICE);
        assertEq(a1, 0);
        assertApproxEqAbs(t0.balanceOf(ALICE), before, 2, "principal and tip back, minus core's round-up");
        assertGe(a0, 1e18 + 1e15 - 2);
        assertEq(orders.protocolOwed(c1), 0);
        assertEq(orders.totalOwed(c0), 0);
    }

    function test_cancel_insideRangeChargesConvertedPartOnly() public {
        (uint256 id, uint256 epochId,) = _placeWith(ALICE, keyCL, ABOVE, true, 1e18, 0, SITE, 10);
        _swapToTick(keyCL, ABOVE + SPACING / 2);
        assertFalse(orders.isCrossed(epochId));
        vm.prank(ALICE);
        (uint256 a0, uint256 a1) = orders.cancel(id, ALICE);
        assertGt(a0, 0);
        assertGt(a1, 0);
        uint256 converted = a1 + orders.protocolOwed(c1) + orders.integratorOwed(SITE, c1);
        // fees on the converted principal, plus LP fees the position earned (uncharged)
        assertApproxEqAbs(orders.protocolOwed(c1), converted * FEE_BPS / 10_000, converted / 10_000 + 2);
        assertGt(orders.integratorOwed(SITE, c1), 0);
    }

    function test_cancel_crossedPaysTheSameFeeAsWithdraw() public {
        (uint256 id,,) = _place(ALICE, keyCL, ABOVE, true, 1e18, 0);
        _swapToTick(keyCL, ABOVE + SPACING);
        vm.prank(ALICE);
        (, uint256 a1) = orders.cancel(id, ALICE);
        uint256 owed = orders.protocolOwed(c1);
        assertLe(owed, (a1 + owed) * FEE_BPS / 10_000, "charged on principal only, LP fees excluded");
        assertGe(owed, (a1 + owed) * FEE_BPS / 10_000 * 99 / 100);
    }

    function test_cancel_refusals() public {
        (uint256 id,,) = _place(ALICE, keyCL, ABOVE, true, 1e18, 0);
        vm.prank(BOB);
        vm.expectRevert(DeepCoreRangeOrders.NotMaker.selector);
        orders.cancel(id, BOB);
        vm.prank(ALICE);
        vm.expectRevert(OrdersFeeBase.ZeroAddress.selector);
        orders.cancel(id, address(0));
        vm.prank(ALICE);
        vm.expectRevert(DeepCoreRangeOrders.UnknownOrder.selector);
        orders.cancel(42, ALICE);
    }

    function test_cancel_lastMakerThenNewJoinerSameEpoch() public {
        (uint256 id, uint256 e1,) = _place(ALICE, keyCL, ABOVE, true, 1e18, 0);
        vm.prank(ALICE);
        orders.cancel(id, ALICE);
        vm.expectRevert(DeepCoreRangeOrders.EmptyEpoch.selector);
        orders.execute(e1);
        (, uint256 e2,) = _place(BOB, keyCL, ABOVE, true, 1e18, 0);
        assertEq(e1, e2, "an emptied open epoch is reused");
    }

    /*//////////////////////////////////////////////////////////////
                     LP FEES: A LATE JOINER TAKES NONE
    //////////////////////////////////////////////////////////////*/

    function test_lpFees_lateJoinerDoesNotShareEarlierFees() public {
        (uint256 a, uint256 epochId,) = _place(ALICE, keyCL, ABOVE, true, 10e18, 0);
        // churn inside the range: the order earns LP fees
        for (uint256 i; i < 4; ++i) {
            _swapToTick(keyCL, ABOVE + 7);
            _swapToTick(keyCL, ABOVE + 2);
        }
        _swapToTick(keyCL, 0);
        (uint256 b,,) = _place(BOB, keyCL, ABOVE, true, 10e18, 0); // books the fees so far to ALICE
        DeepCoreRangeOrders.Epoch memory e = orders.getEpoch(epochId);
        assertGt(e.held0 + e.held1, 0, "fees were booked at the join");
        _swapToTick(keyCL, ABOVE + SPACING);
        orders.execute(epochId);
        vm.prank(ALICE);
        (uint256 a0,) = orders.withdraw(a, ALICE);
        vm.prank(BOB);
        (uint256 b0,) = orders.withdraw(b, BOB);
        assertGt(a0, b0, "ALICE alone earned the early fees (currency0 fees from in-range buys)");
        assertEq(b0, 0, "after BOB joined only an upward swap ran (fees in currency1): he is owed no currency0");
        assertEq(t0.balanceOf(address(orders)), orders.totalOwed(c0));
        assertEq(t1.balanceOf(address(orders)), orders.totalOwed(c1));
    }

    /*//////////////////////////////////////////////////////////////
                              GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    function test_fee_increaseWaitsDecreaseImmediateFrozenPerOrder() public {
        (uint256 early,,) = _place(ALICE, keyCL, ABOVE, true, 1e18, 0);
        vm.prank(SAFE);
        orders.setProtocolFee(30);
        assertEq(orders.protocolFeeBps(), FEE_BPS, "increase is not live yet");
        (uint16 pend, uint64 at) = orders.pendingProtocolFee();
        assertEq(pend, 30);
        assertEq(at, block.timestamp + NOTICE);
        vm.warp(block.timestamp + NOTICE);
        assertEq(orders.protocolFeeBps(), 30, "applies by time alone");
        (uint256 late,,) = _place(BOB, keyCL, ABOVE, true, 1e18, 0);
        assertEq(orders.getOrder(early).feeBps, FEE_BPS, "never retroactive");
        assertEq(orders.getOrder(late).feeBps, 30);
        vm.prank(SAFE);
        orders.setProtocolFee(5);
        assertEq(orders.protocolFeeBps(), 5, "decrease is immediate");
    }

    function test_fee_capsAndAccess() public {
        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(OrdersFeeBase.FeeAboveCap.selector, 51, 50));
        orders.setProtocolFee(51);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        orders.setProtocolFee(1);
        vm.prank(SAFE);
        vm.expectRevert(OrdersFeeBase.RenounceDisabled.selector);
        orders.renounceOwnership();
        vm.prank(SAFE);
        vm.expectRevert(OrdersFeeBase.NoPendingFee.selector);
        orders.cancelPendingProtocolFee();
        vm.prank(SAFE);
        orders.setProtocolFee(40);
        vm.prank(SAFE);
        orders.cancelPendingProtocolFee();
        (uint16 p,) = orders.pendingProtocolFee();
        assertEq(p, 0);
        vm.expectRevert(abi.encodeWithSelector(OrdersFeeBase.FeeAboveCap.selector, 60, 50));
        new DeepCoreRangeOrders(ICLPoolManager(address(cl)), SAFE, SAFE, 10, 60, NOTICE, new address[](0));
        vm.expectRevert(abi.encodeWithSelector(OrdersFeeBase.InvalidNotice.selector, uint32(1 hours)));
        new DeepCoreRangeOrders(ICLPoolManager(address(cl)), SAFE, SAFE, 10, 50, 1 hours, new address[](0));
        vm.expectRevert(OrdersFeeBase.ZeroAddress.selector);
        new DeepCoreRangeOrders(ICLPoolManager(address(cl)), SAFE, address(0), 10, 50, NOTICE, new address[](0));
    }

    function test_rescueSurplus_onlyAboveOwed() public {
        _place(ALICE, keyCL, ABOVE, true, 1e18, 1e15);
        vm.prank(SAFE);
        vm.expectRevert(OrdersFeeBase.NothingToRescue.selector);
        orders.rescueSurplus(c0, SAFE);
        t0.mint(address(orders), 7e18);
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        orders.rescueSurplus(c0, STRANGER);
        vm.prank(SAFE);
        assertEq(orders.rescueSurplus(c0, BOB), 7e18);
        assertEq(t0.balanceOf(address(orders)), 1e15, "the tip stays");
    }

    function test_flush_refusals() public {
        vm.expectRevert(OrdersFeeBase.NothingToFlush.selector);
        orders.flushProtocolFees(c1);
        vm.prank(SITE);
        vm.expectRevert(OrdersFeeBase.NothingToClaim.selector);
        orders.claimIntegratorFees(c1, SITE);
    }

    function test_native_refusedFromStrangers() public {
        vm.prank(STRANGER);
        (bool ok,) = address(orders).call{value: 1}("");
        assertFalse(ok);
    }

    function test_lockAcquired_onlyVault() public {
        vm.expectRevert(abi.encodeWithSelector(DeepCoreRangeOrders.NotVault.selector, address(this)));
        orders.lockAcquired("");
    }

    /*//////////////////////////////////////////////////////////////
                              REENTRANCY
    //////////////////////////////////////////////////////////////*/

    function test_reentrancy_nativeRecipientCannotReenter() public {
        ReentrantReceiver r = new ReentrantReceiver();
        vm.deal(address(r), 10e18);
        DeepCoreRangeOrders.PlaceParams memory p = _params(keyNative, ABOVE, true, 1e18);
        bytes memory ret = r.call{value: 1e18}(address(orders), abi.encodeCall(DeepCoreRangeOrders.place, (p)));
        (uint256 id,,) = abi.decode(ret, (uint256, uint256, uint128));
        r.arm(address(orders), abi.encodeCall(DeepCoreRangeOrders.cancel, (id, address(r))));
        vm.expectRevert();
        r.call(address(orders), abi.encodeCall(DeepCoreRangeOrders.cancel, (id, address(r))));
        // the order is intact
        assertEq(orders.getOrder(id).maker, address(r));
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_placeCancelRoundTripNeverGains(uint96 amount, uint8 levelSteps, bool sell0) public {
        vm.assume(amount > 1e6);
        int24 lvl = sell0 ? int24(uint24(levelSteps) + 1) * SPACING : -int24(uint24(levelSteps) + 2) * SPACING;
        Currency inC = sell0 ? c0 : c1;
        uint256 before = inC.balanceOf(ALICE);
        (uint256 id,,) = _place(ALICE, keyCL, lvl, sell0, amount, 0);
        vm.prank(ALICE);
        orders.cancel(id, ALICE);
        uint256 afterBal = inC.balanceOf(ALICE);
        assertLe(afterBal, before, "never more than was put in");
        assertGe(afterBal + 2, before, "at most core's round-up lost");
    }

    function testFuzz_fillNeverPaysMoreThanProceeds(uint96 a, uint96 b) public {
        a = uint96(bound(a, 1e9, 1e21));
        b = uint96(bound(b, 1e9, 1e21));
        (uint256 ia, uint256 epochId,) = _place(ALICE, keyCL, ABOVE, true, a, 0);
        (uint256 ib,,) = _place(BOB, keyCL, ABOVE, true, b, 0);
        _swapToTick(keyCL, ABOVE + SPACING);
        orders.execute(epochId);
        uint256 held = orders.getEpoch(epochId).held1;
        vm.prank(ALICE);
        (, uint256 oa) = orders.withdraw(ia, ALICE);
        vm.prank(BOB);
        (, uint256 ob) = orders.withdraw(ib, BOB);
        assertLe(oa + ob + orders.protocolOwed(c1), held);
        assertEq(t1.balanceOf(address(orders)), orders.totalOwed(c1));
    }

    function _params(PoolKey memory key, int24 tickLower, bool zeroForOne, uint256 amount)
        internal
        pure
        returns (DeepCoreRangeOrders.PlaceParams memory)
    {
        return DeepCoreRangeOrders.PlaceParams({
            key: key,
            tickLower: tickLower,
            zeroForOne: zeroForOne,
            amountIn: amount,
            tip: 0,
            integrator: address(0),
            integratorBps: 0
        });
    }
}
