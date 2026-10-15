// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {DeepCoreDCA} from "../src/DeepCoreDCA.sol";
import {OrdersFeeBase} from "../src/base/OrdersFeeBase.sol";
import {OrdersFixture} from "./OrdersFixture.sol";
import {FeeOnTransferToken, ReentrantSwapHook} from "./mocks/Mocks.sol";

contract DeepCoreDCATest is OrdersFixture {
    using CLPoolParametersHelper for bytes32;

    function _create(address who, DeepCoreDCA.CreateParams memory p) internal returns (uint256 id) {
        Currency inC = p.zeroForOne ? p.key.currency0 : p.key.currency1;
        uint256 value = inC.isNative() ? uint256(p.slices) * (uint256(p.amountPerSlice) + p.tipPerSlice) : 0;
        vm.prank(who);
        id = dca.create{value: value}(p);
    }

    /*//////////////////////////////////////////////////////////////
                                 CREATE
    //////////////////////////////////////////////////////////////*/

    function test_create_escrowsSlicesAndTips() public {
        uint256 before = t0.balanceOf(BOB);
        uint256 id = _create(BOB, _dcaParams(keyCL, true, 1e18, 1e15, 5));
        assertEq(id, 1);
        assertEq(before - t0.balanceOf(BOB), 5 * (1e18 + 1e15));
        assertEq(dca.totalOwed(c0), 5 * (1e18 + 1e15));
        DeepCoreDCA.Plan memory s = dca.getPlan(id);
        assertEq(s.owner, BOB);
        assertEq(s.recipient, ALICE);
        assertEq(s.slicesLeft, 5);
        assertEq(s.feeBps, FEE_BPS);
        assertEq(s.nextAt, block.timestamp);
        assertTrue(dca.isDue(id));
    }

    function test_create_refusals() public {
        DeepCoreDCA.CreateParams memory p = _dcaParams(keyCL, true, 1e18, 0, 5);
        p.key.poolManager = IPoolManager(address(0xBEEF));
        vm.expectRevert(DeepCoreDCA.WrongPoolManager.selector);
        _create(BOB, p);

        p = _dcaParams(keyCL, true, 0, 0, 5);
        vm.expectRevert(DeepCoreDCA.ZeroAmount.selector);
        _create(BOB, p);

        p = _dcaParams(keyCL, true, 1e18, 0, 5);
        p.minPriceX96 = 0;
        vm.expectRevert(DeepCoreDCA.ZeroAmount.selector);
        _create(BOB, p);

        p = _dcaParams(keyCL, true, 1e18, 0, 0);
        vm.expectRevert(DeepCoreDCA.BadSchedule.selector);
        _create(BOB, p);

        p = _dcaParams(keyCL, true, 1e18, 0, 5);
        p.interval = 59;
        vm.expectRevert(DeepCoreDCA.BadSchedule.selector);
        _create(BOB, p);

        p = _dcaParams(keyCL, true, 1e18, 0, 5);
        p.deadline = uint64(block.timestamp);
        vm.expectRevert(DeepCoreDCA.BadSchedule.selector);
        _create(BOB, p);

        p = _dcaParams(keyCL, true, 1e18, 0, 5);
        p.recipient = address(0);
        vm.expectRevert(OrdersFeeBase.ZeroAddress.selector);
        _create(BOB, p);

        p = _dcaParams(keyCL, true, 1e18, 0, 5);
        p.integrator = SITE;
        p.integratorBps = 11;
        vm.expectRevert(abi.encodeWithSelector(OrdersFeeBase.IntegratorBpsAboveCap.selector, uint16(11)));
        _create(BOB, p);

        p = _dcaParams(keyCL, true, 1e18, 0, 5);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDCA.WrongValue.selector, 0, 1));
        dca.create{value: 1}(p);

        p = _dcaParams(keyNative, true, 1e18, 0, 5);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDCA.WrongValue.selector, 5e18, 1e18));
        dca.create{value: 1e18}(p);
    }

    function test_create_refusesFeeOnTransfer() public {
        FeeOnTransferToken tax = new FeeOnTransferToken();
        (Currency a, Currency b) =
            address(tax) < address(t1) ? (Currency.wrap(address(tax)), c1) : (c1, Currency.wrap(address(tax)));
        PoolKey memory k =
            PoolKey(a, b, IHooks(address(0)), IPoolManager(address(cl)), 3000, bytes32(0).setTickSpacing(SPACING));
        tax.mint(BOB, 1e21);
        vm.prank(BOB);
        tax.approve(address(dca), type(uint256).max);
        bool taxIs0 = Currency.unwrap(a) == address(tax);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDCA.FeeOnTransferUnsupported.selector, 2e18, 198e16));
        _create(BOB, _dcaParams(k, taxIs0, 1e18, 0, 2));
    }

    /*//////////////////////////////////////////////////////////////
                                EXECUTE
    //////////////////////////////////////////////////////////////*/

    function test_execute_paysRecipientFeesAndTip() public {
        DeepCoreDCA.CreateParams memory p = _dcaParams(keyCL, true, 1e18, 1e15, 3);
        p.integrator = SITE;
        p.integratorBps = 5;
        uint256 id = _create(BOB, p);
        uint256 aliceBefore = t1.balanceOf(ALICE);
        uint256 keeperBefore = t0.balanceOf(KEEPER);
        vm.prank(KEEPER);
        uint256 net = dca.execute(id);
        uint256 got = t1.balanceOf(ALICE) - aliceBefore;
        assertEq(got, net);
        assertEq(t0.balanceOf(KEEPER) - keeperBefore, 1e15, "tip in the input currency");
        uint256 gross = net + dca.protocolOwed(c1) + dca.integratorOwed(SITE, c1);
        assertEq(dca.protocolOwed(c1), gross * FEE_BPS / 10_000);
        assertEq(dca.integratorOwed(SITE, c1), gross * 5 / 10_000);
        DeepCoreDCA.Plan memory s = dca.getPlan(id);
        assertEq(s.slicesLeft, 2);
        assertEq(s.nextAt, block.timestamp + 1 hours);
        assertEq(dca.totalOwed(c0), 2 * (1e18 + 1e15));
        assertEq(t0.balanceOf(address(dca)), dca.totalOwed(c0));
        assertEq(t1.balanceOf(address(dca)), dca.totalOwed(c1));
        assertFalse(dca.isDue(id));
    }

    function test_execute_notDueThenDue_lastSliceDeletesPlan() public {
        uint256 id = _create(BOB, _dcaParams(keyCL, true, 1e18, 0, 2));
        dca.execute(id);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDCA.NotDue.selector, uint64(block.timestamp + 1 hours)));
        dca.execute(id);
        vm.warp(block.timestamp + 1 hours);
        dca.execute(id);
        assertEq(dca.getPlan(id).owner, address(0));
        vm.expectRevert(DeepCoreDCA.UnknownPlan.selector);
        dca.execute(id);
        assertEq(dca.totalOwed(c0), 0);
    }

    function test_execute_refusesBelowUserBound() public {
        DeepCoreDCA.CreateParams memory p = _dcaParams(keyCL, true, 1e18, 0, 2);
        p.minPriceX96 = (uint256(1) << 96) * 101 / 100; // wants 1.01 out per 1 in at a 1.0 price
        uint256 id = _create(BOB, p);
        vm.expectRevert(); // BelowMinOut, from inside the lock
        dca.execute(id);
        assertEq(dca.getPlan(id).slicesLeft, 2, "a refused slice leaves the plan untouched");
    }

    function test_execute_sandwichBoundedByUserBound() public {
        DeepCoreDCA.CreateParams memory p = _dcaParams(keyCL, true, 1e18, 0, 2);
        p.minPriceX96 = (uint256(1) << 96) * 98 / 100;
        uint256 id = _create(BOB, p);
        // an attacker pushes price down 5% before the slice
        _swapToTick(keyCL, -500);
        vm.expectRevert();
        dca.execute(id);
        _swapToTick(keyCL, 0);
        uint256 net = dca.execute(id);
        assertGe(net, dca.minOutPerSlice(id) == 0 ? 0 : 0.98e18);
    }

    function test_execute_expired() public {
        DeepCoreDCA.CreateParams memory p = _dcaParams(keyCL, true, 1e18, 0, 2);
        p.deadline = uint64(block.timestamp + 2 hours);
        uint256 id = _create(BOB, p);
        vm.warp(block.timestamp + 2 hours + 1);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDCA.Expired.selector, p.deadline));
        dca.execute(id);
        vm.prank(BOB);
        assertEq(dca.cancel(id, BOB), 2e18, "expired escrow comes back whole");
    }

    function test_execute_partialFillRefused() public {
        // a pool with one narrow position: a large slice runs out of liquidity
        PoolKey memory k = keyCL;
        k.fee = 500;
        cl.initialize(k, SQRT_1_1);
        _addCL(k, -10, 10, 1e18, 0);
        DeepCoreDCA.CreateParams memory p = _dcaParams(k, true, 1e20, 0, 1);
        p.minPriceX96 = 1; // no price bound in the way: the refusal must be the partial fill itself
        uint256 id = _create(BOB, p);
        vm.expectPartialRevert(DeepCoreDCA.PartialFill.selector);
        dca.execute(id);
    }

    function test_execute_startAtInFuture() public {
        DeepCoreDCA.CreateParams memory p = _dcaParams(keyCL, true, 1e18, 0, 2);
        p.startAt = uint64(block.timestamp + 1 days);
        uint256 id = _create(BOB, p);
        assertFalse(dca.isDue(id));
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDCA.NotDue.selector, p.startAt));
        dca.execute(id);
        vm.warp(p.startAt);
        dca.execute(id);
    }

    function test_native_inAndOut() public {
        uint256 id = _create(BOB, _dcaParams(keyNative, true, 1e18, 1e15, 2));
        assertEq(address(dca).balance, 2 * (1e18 + 1e15));
        uint256 k = KEEPER.balance;
        vm.prank(KEEPER);
        dca.execute(id);
        assertEq(KEEPER.balance - k, 1e15);
        // native out: sell t1 for native, recipient ALICE
        uint256 id2 = _create(BOB, _dcaParams(keyNative, false, 1e18, 0, 1));
        uint256 a = ALICE.balance;
        uint256 net = dca.execute(id2);
        assertEq(ALICE.balance - a, net);
        assertEq(address(dca).balance, dca.totalOwed(Currency.wrap(address(0))));
    }

    function test_bin_plan() public {
        uint256 id = _create(BOB, _dcaParams(keyBin, false, 1e18, 0, 2));
        uint256 a = t0.balanceOf(ALICE);
        uint256 net = dca.execute(id);
        assertEq(t0.balanceOf(ALICE) - a, net);
        assertGt(net, 0.98e18);
    }

    /*//////////////////////////////////////////////////////////////
                                 CANCEL
    //////////////////////////////////////////////////////////////*/

    function test_cancel_anyTimeRefundsRest() public {
        uint256 id = _create(BOB, _dcaParams(keyCL, true, 1e18, 1e15, 4));
        dca.execute(id);
        uint256 before = t0.balanceOf(BOB);
        vm.prank(BOB);
        uint256 refund = dca.cancel(id, BOB);
        assertEq(refund, 3 * (1e18 + 1e15));
        assertEq(t0.balanceOf(BOB) - before, refund);
        assertEq(dca.totalOwed(c0), 0);
        assertEq(t0.balanceOf(address(dca)), 0);
    }

    function test_cancel_refusals() public {
        uint256 id = _create(BOB, _dcaParams(keyCL, true, 1e18, 0, 2));
        vm.prank(STRANGER);
        vm.expectRevert(DeepCoreDCA.NotOwner.selector);
        dca.cancel(id, STRANGER);
        vm.prank(SAFE);
        vm.expectRevert(DeepCoreDCA.NotOwner.selector);
        dca.cancel(id, SAFE);
        vm.prank(BOB);
        vm.expectRevert(OrdersFeeBase.ZeroAddress.selector);
        dca.cancel(id, address(0));
        vm.prank(BOB);
        vm.expectRevert(DeepCoreDCA.UnknownPlan.selector);
        dca.cancel(99, BOB);
    }

    /*//////////////////////////////////////////////////////////////
                          ADMIN CANNOT REACH ESCROW
    //////////////////////////////////////////////////////////////*/

    function test_rescue_cannotTouchEscrow() public {
        _create(BOB, _dcaParams(keyCL, true, 1e18, 0, 3));
        vm.prank(SAFE);
        vm.expectRevert(OrdersFeeBase.NothingToRescue.selector);
        dca.rescueSurplus(c0, SAFE);
        t0.mint(address(dca), 1e18);
        vm.prank(SAFE);
        assertEq(dca.rescueSurplus(c0, SAFE), 1e18);
        assertEq(t0.balanceOf(address(dca)), 3e18);
    }

    function test_feeFrozenPerPlan() public {
        uint256 id = _create(BOB, _dcaParams(keyCL, true, 1e18, 0, 3));
        vm.prank(SAFE);
        dca.setProtocolFee(50);
        vm.warp(block.timestamp + NOTICE);
        dca.execute(id);
        uint256 gross = t1.balanceOf(address(dca)); // only the protocol fee stays
        assertEq(dca.getPlan(id).feeBps, FEE_BPS);
        assertGt(gross, 0);
        vm.prank(SAFE);
        vm.expectRevert(OrdersFeeBase.RenounceDisabled.selector);
        dca.renounceOwnership();
        dca.flushProtocolFees(c1);
        assertEq(t1.balanceOf(SAFE), gross);
    }

    /*//////////////////////////////////////////////////////////////
                              REENTRANCY
    //////////////////////////////////////////////////////////////*/

    function test_reentrancy_hookCannotReenter() public {
        ReentrantSwapHook hook = new ReentrantSwapHook();
        PoolKey memory k = PoolKey({
            currency0: c0,
            currency1: c1,
            hooks: IHooks(address(hook)),
            poolManager: IPoolManager(address(cl)),
            fee: 3000,
            parameters: bytes32(uint256(1 << 7)).setTickSpacing(SPACING)
        });
        cl.initialize(k, SQRT_1_1);
        _addCL(k, -6000, 6000, 1e21, 0);
        uint256 id = _create(BOB, _dcaParams(k, true, 1e18, 0, 3));
        hook.arm(address(dca), abi.encodeCall(DeepCoreDCA.execute, (id)));
        vm.expectRevert();
        dca.execute(id);
        hook.arm(address(dca), abi.encodeCall(DeepCoreDCA.cancel, (id, BOB)));
        vm.expectRevert();
        dca.execute(id);
        assertEq(dca.getPlan(id).slicesLeft, 3);
        // disarmed, it runs
        hook.arm(address(0x1), "");
        dca.execute(id);
    }

    function test_lockAcquired_onlyVault() public {
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDCA.NotVault.selector, address(this)));
        dca.lockAcquired("");
    }

    function test_native_refusedFromStrangers() public {
        vm.prank(STRANGER);
        (bool ok,) = address(dca).call{value: 1}("");
        assertFalse(ok);
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_escrowMatchesSchedule(uint96 amount, uint64 tip, uint8 slices, uint8 runs) public {
        vm.assume(amount > 1e6 && amount < 5e17 && slices > 0);
        uint256 id = _create(BOB, _dcaParams(keyCL, true, amount, tip, slices));
        uint256 n = runs % (uint256(slices) + 1);
        uint256 t = block.timestamp; // via-IR caches block.timestamp inside a test: keep our own clock
        for (uint256 i; i < n; ++i) {
            dca.execute(id);
            t += 1 hours;
            vm.warp(t);
        }
        uint256 left = slices - n;
        assertEq(dca.totalOwed(c0), left * (uint256(amount) + tip));
        assertEq(t0.balanceOf(address(dca)), dca.totalOwed(c0));
        assertEq(t1.balanceOf(address(dca)), dca.totalOwed(c1));
        if (left != 0) {
            vm.prank(BOB);
            assertEq(dca.cancel(id, BOB), left * (uint256(amount) + tip));
        }
        assertEq(t0.balanceOf(address(dca)), 0);
    }
}
