// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

import {DeepCoreManagedVault} from "../src/DeepCoreManagedVault.sol";
import {VaultFixture} from "./VaultFixture.sol";
import {MockOracle} from "./mocks/Mocks.sol";

/// @dev Random deposits, withdrawals, trades, harvests, rebalances and time.
contract VaultHandler is Test {
    DeepCoreManagedVault internal immutable mv;
    CLPoolManager internal immutable cl;
    CLPoolManagerRouter internal immutable router;
    MockOracle internal immutable oracle;
    MockERC20 internal immutable t0;
    MockERC20 internal immutable t1;
    PoolKey internal key;
    address[3] internal actors;

    uint256 public deposits;
    uint256 public withdrawals;
    uint256 public rebalances;
    uint256 public harvests;
    /// Per actor, what a deposit-then-withdraw round trip in one block returned above what it paid (must stay 0).
    uint256 public roundTripProfit;

    constructor(
        DeepCoreManagedVault mv_,
        CLPoolManager cl_,
        CLPoolManagerRouter router_,
        MockOracle oracle_,
        MockERC20 t0_,
        MockERC20 t1_,
        PoolKey memory key_,
        address[3] memory actors_
    ) {
        mv = mv_;
        cl = cl_;
        router = router_;
        oracle = oracle_;
        t0 = t0_;
        t1 = t1_;
        key = key_;
        actors = actors_;
    }

    function actorsList() external view returns (address[3] memory) {
        return actors;
    }

    function deposit(uint256 who, uint256 shares) external {
        address a = actors[who % 3];
        uint256 supply = mv.totalSupply();
        shares = bound(shares, 1, supply * 2 + 1);
        vm.prank(a);
        try mv.deposit(shares, type(uint256).max, type(uint256).max, a, block.timestamp) {
            deposits++;
        } catch {}
    }

    function roundTrip(uint256 who, uint256 shares) external {
        address a = actors[who % 3];
        shares = bound(shares, 1, mv.totalSupply() + 1);
        uint256 b0 = t0.balanceOf(a);
        uint256 b1 = t1.balanceOf(a);
        vm.startPrank(a);
        try mv.deposit(shares, type(uint256).max, type(uint256).max, a, block.timestamp) {
            mv.withdraw(shares, 0, 0, a, block.timestamp);
        } catch {}
        vm.stopPrank();
        if (t0.balanceOf(a) > b0) roundTripProfit += t0.balanceOf(a) - b0;
        if (t1.balanceOf(a) > b1) roundTripProfit += t1.balanceOf(a) - b1;
    }

    function withdraw(uint256 who, uint256 fraction) external {
        address a = actors[who % 3];
        uint256 bal = mv.balanceOf(a);
        if (bal == 0) return;
        uint256 shares = bound(fraction, 1, bal);
        vm.prank(a);
        mv.withdraw(shares, 0, 0, a, block.timestamp); // must never revert
        withdrawals++;
    }

    function swap(bool zeroForOne, uint256 amount) external {
        amount = bound(amount, 1e12, 5e20);
        try router.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amount),
                sqrtPriceLimitX96: zeroForOne
                    ? TickMath.getSqrtRatioAtTick(-5000)
                    : TickMath.getSqrtRatioAtTick(5000)
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        ) {} catch {}
    }

    function harvest() external {
        try mv.harvest() {
            harvests++;
        } catch {}
    }

    function rebalance(int16 offset) external {
        (, int24 spot,,) = cl.getSlot0(key.toId());
        oracle.setTick(spot + int24(offset) % 100);
        try mv.rebalance() {
            rebalances++;
        } catch {}
    }

    function warp(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 2 hours));
    }
}

contract VaultInvariantTest is VaultFixture {
    VaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        _seed(mv, ALICE, 1e20);
        handler = new VaultHandler(mv, cl, router, oracle, t0, t1, key, [ALICE, BOB, KEEPER]);
        address[3] memory a = [ALICE, BOB, KEEPER];
        for (uint256 i; i < 3; ++i) {
            vm.prank(a[i]);
            t0.approve(address(handler), type(uint256).max);
        }
        t0.approve(address(router), type(uint256).max);
        // the handler trades through the router as itself
        t0.mint(address(handler), 1e30);
        t1.mint(address(handler), 1e30);
        vm.startPrank(address(handler));
        t0.approve(address(router), type(uint256).max);
        t1.approve(address(router), type(uint256).max);
        vm.stopPrank();
        targetContract(address(handler));
    }

    /// The fee credits are always backed by the vault's balance.
    function invariant_creditsBacked() public view {
        assertGe(t0.balanceOf(address(mv)), mv.protocolOwed0() + mv.curatorOwed0());
        assertGe(t1.balanceOf(address(mv)), mv.protocolOwed1() + mv.curatorOwed1());
    }

    /// Shares are conserved: the supply is exactly what the holders and the dead address hold.
    function invariant_sharesConserved() public view {
        uint256 sum = mv.balanceOf(mv.DEAD());
        address[3] memory a = handler.actorsList();
        for (uint256 i; i < 3; ++i) {
            sum += mv.balanceOf(a[i]);
        }
        assertEq(sum, mv.totalSupply());
        assertGe(mv.balanceOf(mv.DEAD()), mv.DEAD_SHARES());
    }

    /// What all holders could withdraw never exceeds what the vault holds, and every holder CAN withdraw.
    function invariant_everyoneCanWithdrawAndTotalsCover() public {
        uint256 snap = vm.snapshotState();
        try mv.harvest() {} catch {} // book uncollected fees so totalAmounts covers everything
        (uint256 t0a, uint256 t1a) = mv.totalAmounts();
        uint256 sum0;
        uint256 sum1;
        address[3] memory a = handler.actorsList();
        for (uint256 i; i < 3; ++i) {
            uint256 bal = mv.balanceOf(a[i]);
            if (bal == 0) continue;
            vm.prank(a[i]);
            (uint256 o0, uint256 o1) = mv.withdraw(bal, 0, 0, a[i], block.timestamp);
            sum0 += o0;
            sum1 += o1;
        }
        vm.revertToState(snap);
        assertLe(sum0, t0a, "token0 over-withdrawn");
        assertLe(sum1, t1a, "token1 over-withdrawn");
    }

    /// Depositing and withdrawing in one block never pays out more than it took.
    function invariant_noRoundTripProfit() public view {
        assertEq(handler.roundTripProfit(), 0);
    }

}
