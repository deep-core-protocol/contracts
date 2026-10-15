// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {Tick} from "infinity-core/src/pool-cl/libraries/Tick.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

import {IDeepCoreLiquidityRewards as I} from "../src/interfaces/IDeepCoreLiquidityRewards.sol";
import {RewardsHookHarness} from "./utils/RewardsHarness.sol";
import {RewardsFixture} from "./utils/RewardsFixture.sol";

/// @dev Drives random adds, removals, swaps, time, top-ups and claims through REAL core. Every position is
/// held by the core test router (sender = router) so the handler can remove and claim any of them.
contract RewardsHandler is Test {
    CLPoolManager public manager;
    CLPoolManagerRouter public router;
    RewardsHookHarness public hook;
    MockERC20 public rwd;
    PoolKey public key;
    PoolId public id;

    struct Pos {
        int24 lo;
        int24 hi;
        bytes32 salt;
        uint128 liq;
    }

    Pos[] public positions;
    int24[] public touchedTicks;
    mapping(int24 => bool) internal _touched;

    uint256 public fundedNet;
    uint256 public paid;
    uint256 public removeFailures;
    uint256 public swapHookFailures;
    uint256 public calls;
    uint256 public claimMismatches;
    address public constant SINK = address(0x51F);

    constructor(CLPoolManager m, CLPoolManagerRouter r, RewardsHookHarness h, MockERC20 t, PoolKey memory k, PoolId i) {
        manager = m;
        router = r;
        hook = h;
        rwd = t;
        key = k;
        id = i;
    }

    function positionCount() external view returns (uint256) {
        return positions.length;
    }

    function touchedCount() external view returns (uint256) {
        return touchedTicks.length;
    }

    function _touch(int24 t) internal {
        if (!_touched[t]) {
            _touched[t] = true;
            touchedTicks.push(t);
        }
    }

    function add(uint256 loSeed, uint256 widthSeed, uint256 liqSeed) external {
        calls++;
        int24 lo = int24(int256(bound(loSeed, 0, 60)) * 10 - 300);
        int24 hi = lo + int24(int256(bound(widthSeed, 1, 40)) * 10);
        uint128 liq = uint128(bound(liqSeed, 1e9, 1e20));
        bytes32 salt = bytes32(positions.length);
        router.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({tickLower: lo, tickUpper: hi, liquidityDelta: int256(uint256(liq)), salt: salt}),
            ""
        );
        positions.push(Pos(lo, hi, salt, liq));
        _touch(lo);
        _touch(hi);
    }

    function remove(uint256 idx, uint256 fracSeed) external {
        calls++;
        if (positions.length == 0) return;
        Pos storage p = positions[idx % positions.length];
        if (p.liq == 0) return;
        uint128 amt = uint128(bound(fracSeed, 1, p.liq));
        try router.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({tickLower: p.lo, tickUpper: p.hi, liquidityDelta: -int256(uint256(amt)), salt: p.salt}),
            ""
        ) {
            p.liq -= amt;
        } catch {
            removeFailures++;
        }
    }

    function swap(uint256 targetSeed) external {
        calls++;
        int24 target = int24(int256(bound(targetSeed, 0, 800))) - 400;
        (uint160 price, int24 cur,,) = manager.getSlot0(id);
        if (target == cur) return;
        bool zeroForOne = target < cur;
        uint160 limit = TickMath.getSqrtRatioAtTick(target);
        if (zeroForOne ? limit >= price : limit <= price) return;
        try router.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(1e24),
                sqrtPriceLimitX96: limit
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        ) {} catch {
            swapHookFailures++;
        }
    }

    function warp(uint256 dt) external {
        calls++;
        vm.warp(block.timestamp + bound(dt, 1, 3 days));
    }

    function topUp(uint256 amt) external {
        calls++;
        amt = bound(amt, 1e6, 1e24);
        (, uint64 finish,,) = hook.streamOf(id, Currency.wrap(address(rwd)));
        if (finish <= block.timestamp + 1 hours) return;
        uint16 fee = hook.protocolFeeBps();
        rwd.mint(address(this), amt);
        rwd.approve(address(hook), amt);
        hook.topUp(key, Currency.wrap(address(rwd)), amt);
        fundedNet += amt - amt * fee / 10_000;
    }

    function claim(uint256 idx) external {
        calls++;
        if (positions.length == 0) return;
        Pos storage p = positions[idx % positions.length];
        I.PositionKey memory k = I.PositionKey({sender: address(router), tickLower: p.lo, tickUpper: p.hi, salt: p.salt});
        uint256[] memory e = hook.earned(id, k);
        if (e[0] == 0) return;
        vm.prank(address(router));
        uint256[] memory got = hook.claim(id, k, SINK);
        if (got[0] != e[0]) claimMismatches++;
        paid += got[0];
    }

    function noteFunded(uint256 net) external {
        fundedNet += net;
    }
}

contract RewardsInvariantTest is RewardsFixture {
    RewardsHandler internal handler;

    function _minEligible() internal pure override returns (uint128) {
        return 1; // every position qualifies, so the mirror must equal core exactly
    }

    function setUp() public override {
        super.setUp();
        handler = new RewardsHandler(manager, router, hook, rwd, key, id);
        tA.mint(address(handler), 1e30);
        tB.mint(address(handler), 1e30);
        vm.startPrank(address(handler));
        tA.approve(address(router), type(uint256).max);
        tB.approve(address(router), type(uint256).max);
        vm.stopPrank();
        _start(1e24, 30 days);
        handler.noteFunded(_net(1e24));

        bytes4[] memory sel = new bytes4[](6);
        sel[0] = RewardsHandler.add.selector;
        sel[1] = RewardsHandler.remove.selector;
        sel[2] = RewardsHandler.swap.selector;
        sel[3] = RewardsHandler.warp.selector;
        sel[4] = RewardsHandler.topUp.selector;
        sel[5] = RewardsHandler.claim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: sel}));
        targetContract(address(handler));
    }

    /// @dev Every removal and swap the handler made went through real core without reverting.
    function invariant_removalNeverReverts() public view {
        assertEq(handler.removeFailures(), 0, "a removal through core reverted");
        assertEq(handler.swapHookFailures(), 0, "a swap through core reverted");
        assertEq(handler.claimMismatches(), 0, "a claim paid other than earned() reported");
    }

    function invariant_mirrorEqualsCore() public view {
        assertEq(hook.eligibleLiquidity(id), manager.getLiquidity(id), "eligible liquidity != core's active liquidity");
        uint256 n = handler.touchedCount();
        for (uint256 i; i < n; ++i) {
            int24 t = handler.touchedTicks(i);
            Tick.Info memory c = manager.getPoolTickInfo(id, t);
            (uint128 g, int128 net) = hook.mirroredTick(id, t);
            assertEq(g, c.liquidityGross, "gross");
            assertEq(net, c.liquidityNet, "net");
        }
        (,, int24 last,,) = hook.poolConfig(id);
        (, int24 coreTick,,) = manager.getSlot0(id);
        assertEq(last, coreTick, "lastTick");
    }

    function invariant_paidNeverExceedsFunded() public view {
        uint256 owedToPositions;
        uint256 n = handler.positionCount();
        for (uint256 i; i < n; ++i) {
            (int24 lo, int24 hi, bytes32 salt,) = handler.positions(i);
            owedToPositions += hook.earned(id, I.PositionKey({sender: address(router), tickLower: lo, tickUpper: hi, salt: salt}))[0];
        }
        assertLe(handler.paid() + owedToPositions, handler.fundedNet(), "rewards paid or owed exceed what was funded");
        assertEq(rwd.balanceOf(handler.SINK()), handler.paid());
    }

    /// @dev Per-position accrual matches the accumulator: what positions are owed sums to the pool's accrued
    /// ledger, short only by rounding (at most one unit per position per accrual or settlement).
    function invariant_positionsMatchAccumulator() public view {
        uint256 owedToPositions;
        uint256 n = handler.positionCount();
        for (uint256 i; i < n; ++i) {
            (int24 lo, int24 hi, bytes32 salt,) = handler.positions(i);
            owedToPositions += hook.earned(id, I.PositionKey({sender: address(router), tickLower: lo, tickUpper: hi, salt: salt}))[0];
        }
        I.StreamView[] memory ss = hook.streams(id);
        uint256 accrued = ss[0].accruedUnpaid;
        assertLe(owedToPositions, accrued, "positions owed more than accrued");
        assertLe(accrued - owedToPositions, (handler.calls() + 2) * (n + 2), "dust above the rounding bound");
    }

    function invariant_ledgerIsSolvent() public view {
        Currency R = Currency.wrap(address(rwd));
        address[] memory none = new address[](0);
        assertEq(_ledger(R, none), hook.totalOwed(R), "ledger != totalOwed");
        assertLe(hook.totalOwed(R), rwd.balanceOf(address(hook)), "insolvent");
    }
}
