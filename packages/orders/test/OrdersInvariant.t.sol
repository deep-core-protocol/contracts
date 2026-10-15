// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPosition} from "infinity-core/src/pool-cl/libraries/CLPosition.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

import {DeepCoreRangeOrders} from "../src/DeepCoreRangeOrders.sol";
import {DeepCoreDCA} from "../src/DeepCoreDCA.sol";
import {OrdersFixture} from "./OrdersFixture.sol";

/// @dev Random makers, levels, swaps, cancels, fills, withdrawals and DCA plans against real core.
contract OrdersHandler is Test {
    DeepCoreRangeOrders public orders;
    DeepCoreDCA public dca;
    CLPoolManager public cl;
    CLPoolManagerRouter public router;
    PoolKey public key;
    address[3] public makers;

    uint256[] public orderIds;
    uint256[] public epochIds;
    uint256[] public planIds;
    mapping(uint256 => bool) public seenEpoch;
    uint256 public placed;
    uint256 public cancelled;
    uint256 public filled;
    uint256 public withdrawn;
    uint256 public slices;
    uint256 public plansCancelled;

    constructor(
        DeepCoreRangeOrders orders_,
        DeepCoreDCA dca_,
        CLPoolManager cl_,
        CLPoolManagerRouter router_,
        PoolKey memory key_,
        address[3] memory makers_
    ) {
        orders = orders_;
        dca = dca_;
        cl = cl_;
        router = router_;
        key = key_;
        makers = makers_;
    }

    function place(uint256 seed, uint96 amount, uint8 steps, bool sell0, uint64 tip) external {
        amount = uint96(bound(amount, 1e9, 1e21));
        (, int24 tick,,) = cl.getSlot0(key.toId());
        int24 base = (tick / 10) * 10;
        if (tick < 0 && tick % 10 != 0) base -= 10;
        int24 lvl = sell0 ? base + 10 * int24(uint24(steps % 20) + 1) : base - 10 * int24(uint24(steps % 20) + 1);
        address maker = makers[seed % 3];
        vm.prank(maker);
        try orders.place(
            DeepCoreRangeOrders.PlaceParams({
                key: key,
                tickLower: lvl,
                zeroForOne: sell0,
                amountIn: amount,
                tip: tip,
                integrator: address(0),
                integratorBps: 0
            })
        ) returns (uint256 id, uint256 epochId, uint128) {
            orderIds.push(id);
            ++placed;
            if (!seenEpoch[epochId]) {
                seenEpoch[epochId] = true;
                epochIds.push(epochId);
            }
        } catch {}
    }

    function swap(int24 delta) external {
        delta = int24(bound(delta, -400, 400));
        (, int24 tick,,) = cl.getSlot0(key.toId());
        int24 target = tick + delta;
        if (target == tick || target <= -5900 || target >= 5900) return;
        try router.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: target < tick,
                amountSpecified: -1e23,
                sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(target)
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        ) {} catch {}
    }

    /// @dev Drive price through a known epoch's level and fill it, so fills and withdrawals are common.
    function crossAndFill(uint256 i) external {
        if (epochIds.length == 0) return;
        uint256 epochId = epochIds[i % epochIds.length];
        DeepCoreRangeOrders.Epoch memory e = orders.getEpoch(epochId);
        if (e.filled || e.liquidity == 0) return;
        int24 target = e.zeroForOne ? e.tickUpper + 1 : e.tickLower - 1;
        if (target <= -5900 || target >= 5900) return;
        (, int24 tick,,) = cl.getSlot0(key.toId());
        if (target != tick) {
            try router.swap(
                key,
                ICLPoolManager.SwapParams({
                    zeroForOne: target < tick,
                    amountSpecified: -1e24,
                    sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(target)
                }),
                CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
                ""
            ) {} catch {}
        }
        try orders.execute(epochId) {
            ++filled;
        } catch {}
    }

    function cancel(uint256 i) external {
        if (orderIds.length == 0) return;
        uint256 id = orderIds[i % orderIds.length];
        DeepCoreRangeOrders.Order memory o = orders.getOrder(id);
        if (o.maker == address(0)) return;
        vm.prank(o.maker);
        try orders.cancel(id, o.maker) {
            ++cancelled;
        } catch {}
    }

    function execute(uint256 i) external {
        if (epochIds.length == 0) return;
        try orders.execute(epochIds[i % epochIds.length]) {
            ++filled;
        } catch {}
    }

    function withdraw(uint256 i) external {
        if (orderIds.length == 0) return;
        uint256 id = orderIds[i % orderIds.length];
        DeepCoreRangeOrders.Order memory o = orders.getOrder(id);
        if (o.maker == address(0)) return;
        vm.prank(o.maker);
        try orders.withdraw(id, o.maker) {
            ++withdrawn;
        } catch {}
    }

    function createPlan(uint256 seed, uint96 amount, uint8 slices, bool sell0) external {
        amount = uint96(bound(amount, 1e9, 1e20));
        slices = uint8(bound(slices, 1, 6));
        address maker = makers[seed % 3];
        vm.prank(maker);
        try dca.create(
            DeepCoreDCA.CreateParams({
                key: key,
                zeroForOne: sell0,
                amountPerSlice: amount,
                tipPerSlice: uint128(amount / 1000),
                slices: slices,
                interval: 60,
                startAt: 0,
                deadline: uint64(block.timestamp + 365 days),
                minPriceX96: (uint256(1) << 96) / 4,
                recipient: maker,
                integrator: makers[(seed + 1) % 3],
                integratorBps: 3
            })
        ) returns (uint256 id) {
            planIds.push(id);
        } catch {}
    }

    function runSlice(uint256 i) external {
        if (planIds.length == 0) return;
        vm.warp(block.timestamp + 61);
        try dca.execute(planIds[i % planIds.length]) {
            ++slices;
        } catch {}
    }

    function cancelPlan(uint256 i) external {
        if (planIds.length == 0) return;
        uint256 id = planIds[i % planIds.length];
        DeepCoreDCA.Plan memory p = dca.getPlan(id);
        if (p.owner == address(0)) return;
        vm.prank(p.owner);
        try dca.cancel(id, p.owner) {
            ++plansCancelled;
        } catch {}
    }

    function flush(bool one) external {
        try orders.flushProtocolFees(one ? key.currency1 : key.currency0) {} catch {}
        try dca.flushProtocolFees(one ? key.currency1 : key.currency0) {} catch {}
    }

    function epochCount() external view returns (uint256) {
        return epochIds.length;
    }

    function orderCount() external view returns (uint256) {
        return orderIds.length;
    }

    function planCount() external view returns (uint256) {
        return planIds.length;
    }
}

contract OrdersInvariantTest is OrdersFixture {
    OrdersHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[3] memory makers = [ALICE, BOB, STRANGER];
        handler = new OrdersHandler(orders, dca, cl, router, keyCL, makers);
        t0.mint(address(handler), 1e30);
        t1.mint(address(handler), 1e30);
        vm.startPrank(address(handler));
        t0.approve(address(router), type(uint256).max);
        t1.approve(address(router), type(uint256).max);
        vm.stopPrank();
        targetContract(address(handler));
    }

    function afterInvariant() public view {
        console2.log("placed", handler.placed(), "cancelled", handler.cancelled());
        console2.log("filled", handler.filled(), "withdrawn", handler.withdrawn());
        console2.log("slices", handler.slices(), "plansCancelled", handler.plansCancelled());
    }

    /// Solvency: every unit owed is held.
    function invariant_balanceCoversOwed() public view {
        assertGe(t0.balanceOf(address(orders)), orders.totalOwed(c0));
        assertGe(t1.balanceOf(address(orders)), orders.totalOwed(c1));
        assertGe(t0.balanceOf(address(dca)), dca.totalOwed(c0));
        assertGe(t1.balanceOf(address(dca)), dca.totalOwed(c1));
    }

    /// Exactness: nothing arrives that is not on a ledger (no stray value in these runs).
    function invariant_balanceEqualsOwed() public view {
        assertEq(t0.balanceOf(address(orders)), orders.totalOwed(c0));
        assertEq(t1.balanceOf(address(orders)), orders.totalOwed(c1));
        assertEq(t0.balanceOf(address(dca)), dca.totalOwed(c0));
        assertEq(t1.balanceOf(address(dca)), dca.totalOwed(c1));
    }

    /// DCA escrow == sum of open plans' remaining slices and tips, plus fee credits.
    function invariant_dcaEscrowIsSumOfOpenPlans() public view {
        uint256 s0;
        uint256 s1;
        for (uint256 i; i < handler.planCount(); ++i) {
            DeepCoreDCA.Plan memory p = dca.getPlan(handler.planIds(i));
            if (p.owner == address(0)) continue;
            uint256 e = uint256(p.slicesLeft) * (uint256(p.amountPerSlice) + p.tipPerSlice);
            if (p.zeroForOne) s0 += e;
            else s1 += e;
        }
        uint256 credit0 = dca.protocolOwed(c0) + dca.integratorOwed(ALICE, c0) + dca.integratorOwed(BOB, c0)
            + dca.integratorOwed(STRANGER, c0);
        uint256 credit1 = dca.protocolOwed(c1) + dca.integratorOwed(ALICE, c1) + dca.integratorOwed(BOB, c1)
            + dca.integratorOwed(STRANGER, c1);
        assertEq(dca.totalOwed(c0), s0 + credit0);
        assertEq(dca.totalOwed(c1), s1 + credit1);
    }

    /// Range orders: per unfilled epoch, sum(order liquidity) == epoch liquidity == core position liquidity;
    /// a filled epoch's position is empty; tips escrowed == sum of live orders' tips.
    function invariant_epochLiquidityMatchesCore() public view {
        uint256 orderCount = handler.orderCount();
        for (uint256 i; i < handler.epochCount(); ++i) {
            uint256 epochId = handler.epochIds(i);
            DeepCoreRangeOrders.Epoch memory e = orders.getEpoch(epochId);
            CLPosition.Info memory pos =
                cl.getPosition(e.poolId, address(orders), e.tickLower, e.tickUpper, bytes32(epochId));
            uint256 sumLiq;
            uint256 sumTip;
            for (uint256 j; j < orderCount; ++j) {
                DeepCoreRangeOrders.Order memory o = orders.getOrder(handler.orderIds(j));
                if (o.maker == address(0) || o.epochId != epochId) continue;
                sumLiq += o.liquidity;
                sumTip += o.tip;
            }
            assertEq(sumLiq, e.liquidity, "orders sum to the epoch");
            if (e.filled) {
                assertEq(pos.liquidity, 0, "filled epoch is out of the pool");
                assertEq(e.tipTotal, 0);
            } else {
                assertEq(pos.liquidity, e.liquidity, "epoch == core position");
                assertEq(sumTip, e.tipTotal);
            }
        }
    }
}
