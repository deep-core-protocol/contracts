// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {DeepCoreFillRouter} from "../src/DeepCoreFillRouter.sol";
import {DeepCoreFillExecutor} from "../src/DeepCoreFillExecutor.sol";
import {
    MockERC20,
    MockFeeOnTransferERC20,
    MockWrappedNative,
    MockVenue,
    ReentrantVenue,
    NativeRejector
} from "./mocks/Mocks.sol";

contract DeepCoreFillRouterTest is Test {
    DeepCoreFillRouter internal router;
    DeepCoreFillExecutor internal executor;

    MockERC20 internal tokenIn;
    MockERC20 internal tokenOut;
    MockWrappedNative internal wnative;
    MockVenue internal venue;

    address internal constant NATIVE = address(0);

    address internal safe = makeAddr("governanceSafe");
    address internal owner = makeAddr("governanceSafe"); // the Safe is both owner and fee recipient
    address internal trader = makeAddr("trader");
    address internal stranger = makeAddr("stranger");
    address internal recipient = makeAddr("recipient");

    uint16 internal constant INITIAL_BPS = 10; // the owner's decision: 10 bps on a routed fill
    uint16 internal constant CAP_BPS = 50; // the suggested immutable cap
    uint32 internal constant NOTICE = 7 days;

    function setUp() public {
        owner = safe;
        wnative = new MockWrappedNative();
        router = new DeepCoreFillRouter(owner, safe, address(wnative), INITIAL_BPS, CAP_BPS, NOTICE, address(0));
        executor = router.EXECUTOR();

        tokenIn = new MockERC20("In", "IN", 18);
        tokenOut = new MockERC20("Out", "OUT", 18);
        venue = new MockVenue();

        tokenIn.mint(trader, 1_000_000 ether);
        tokenOut.mint(address(venue), 1_000_000 ether);
        vm.deal(address(venue), 1_000 ether);
        vm.deal(trader, 1_000 ether);

        vm.prank(trader);
        tokenIn.approve(address(router), type(uint256).max);
    }

    /*//////////////////////////////////////////////////////////////
                               HELPERS
    //////////////////////////////////////////////////////////////*/

    function _params(address target, address cIn, address cOut, uint256 amountIn, uint256 minOut, bytes memory data)
        internal
        view
        returns (DeepCoreFillRouter.FillParams memory)
    {
        return DeepCoreFillRouter.FillParams({
            target: target,
            currencyIn: cIn,
            currencyOut: cOut,
            amountIn: amountIn,
            minAmountOut: minOut,
            maxFeeBps: CAP_BPS,
            wrapInput: false,
            unwrapOutput: false,
            recipient: recipient,
            deadline: block.timestamp + 1 hours,
            data: data
        });
    }

    function _swapCall(address vIn, address vOut, uint256 amtIn, uint256 amtOut, address to)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodeCall(MockVenue.swap, (vIn, vOut, amtIn, amtOut, to));
    }

    function _budget(uint256 amountIn, uint16 bps) internal pure returns (uint256) {
        return (amountIn * 10_000) / (10_000 + uint256(bps));
    }

    /*//////////////////////////////////////////////////////////////
                          HAPPY PATH: EXACT INPUT
    //////////////////////////////////////////////////////////////*/

    function test_exactInput_feeIsTakenOnTheInputAndTheOutputIsUntouched() public {
        uint256 amountIn = 1_000 ether;
        uint256 budget = _budget(amountIn, INITIAL_BPS);
        uint256 quoted = 2_000 ether; // whatever the venue pays for the whole budget

        bytes memory data = _swapCall(address(tokenIn), address(tokenOut), budget, quoted, address(executor));

        vm.prank(trader);
        (uint256 out, uint256 spent, uint256 fee, uint256 refund) =
            router.fill(_params(address(venue), address(tokenIn), address(tokenOut), amountIn, quoted, data));

        // The recipient receives exactly what the venue produced. The fee did not touch it.
        assertEq(out, quoted, "output must be the raw venue output");
        assertEq(tokenOut.balanceOf(recipient), quoted);

        assertEq(spent, budget, "the venue consumed the whole budget");
        assertEq(fee, (budget * INITIAL_BPS) / 10_000, "fee is bps of what reached the venue");
        assertEq(spent + fee + refund, amountIn, "every unit of the input is accounted for");
        assertLe(spent + fee, amountIn, "outlay never exceeds what the caller signed");

        assertEq(tokenIn.balanceOf(address(router)), fee, "the router keeps exactly the fee");
        assertEq(router.totalFeeCollected(address(tokenIn)), fee);
        assertEq(tokenIn.balanceOf(address(executor)), 0, "the executor holds nothing at rest");
    }

    /*//////////////////////////////////////////////////////////////
                         HAPPY PATH: EXACT OUTPUT
    //////////////////////////////////////////////////////////////*/

    /// @dev The hazard CLAUDE.md names: the fee must never turn an exact-output swap into a worse
    /// fill than quoted. The caller asks for an exact output and caps the input; the venue consumes
    /// part of the budget and refunds the rest.
    function test_exactOutput_outlayIsBoundedAndTheOutputIsExact() public {
        uint256 maxIn = 1_000 ether;
        uint256 budget = _budget(maxIn, INITIAL_BPS);
        uint256 consumed = 600 ether; // what the venue actually needs
        uint256 exactOut = 1_234 ether;

        bytes memory data = _swapCall(address(tokenIn), address(tokenOut), consumed, exactOut, address(executor));

        uint256 traderBefore = tokenIn.balanceOf(trader);

        vm.prank(trader);
        (uint256 out, uint256 spent, uint256 fee, uint256 refund) =
            router.fill(_params(address(venue), address(tokenIn), address(tokenOut), maxIn, exactOut, data));

        assertEq(out, exactOut, "the exact output asked for, in full");
        assertEq(spent, consumed, "charged on what was consumed, not on the budget");
        assertEq(fee, (consumed * INITIAL_BPS) / 10_000);
        assertLe(spent + fee, maxIn, "the fee cannot push the outlay past the quoted maximum");
        assertEq(traderBefore - tokenIn.balanceOf(trader), spent + fee, "the caller paid exactly spent + fee");
        assertEq(refund, maxIn - spent - fee);
        assertEq(budget - consumed + (maxIn - budget) - fee, refund, "refund is the unspent budget plus unused fee room");
    }

    function test_exactOutput_aVenueThatConsumesNothingIsChargedNothing() public {
        uint256 maxIn = 500 ether;
        // The venue pays out of its own inventory and consumes zero input.
        bytes memory data = _swapCall(address(tokenIn), address(tokenOut), 0, 1 ether, address(executor));

        uint256 traderBefore = tokenIn.balanceOf(trader);
        vm.prank(trader);
        (uint256 out, uint256 spent, uint256 fee, uint256 refund) =
            router.fill(_params(address(venue), address(tokenIn), address(tokenOut), maxIn, 1 ether, data));

        assertEq(out, 1 ether);
        assertEq(spent, 0);
        assertEq(fee, 0, "no consumption, no fee");
        assertEq(refund, maxIn);
        assertEq(tokenIn.balanceOf(trader), traderBefore, "the caller is whole");
    }

    /*//////////////////////////////////////////////////////////////
                          THE INVARIANT, FUZZED
    //////////////////////////////////////////////////////////////*/

    /// @dev For any size, any fee inside the cap and any venue consumption, the caller's total outlay
    /// is bounded by the amount they signed and the output is never reduced by the fee.
    function testFuzz_outlayNeverExceedsAmountIn(uint256 amountIn, uint16 bps, uint256 consumeBps) public {
        amountIn = bound(amountIn, 1e6, 100_000 ether);
        bps = uint16(bound(uint256(bps), 0, CAP_BPS));
        consumeBps = bound(consumeBps, 0, 10_000);

        if (bps != router.feeBps()) {
            vm.prank(owner);
            router.setFeeBps(bps);
            if (bps > router.feeBps()) {
                vm.warp(block.timestamp + NOTICE);
            }
        }
        uint16 inForce = router.feeBps();

        uint256 budget = _budget(amountIn, inForce);
        uint256 consumed = (budget * consumeBps) / 10_000;
        uint256 produced = 1 ether;

        tokenIn.mint(trader, amountIn);
        bytes memory data = _swapCall(address(tokenIn), address(tokenOut), consumed, produced, address(executor));

        DeepCoreFillRouter.FillParams memory p =
            _params(address(venue), address(tokenIn), address(tokenOut), amountIn, produced, data);
        p.maxFeeBps = type(uint16).max;
        p.deadline = block.timestamp + 1 hours;

        uint256 before = tokenIn.balanceOf(trader);
        vm.prank(trader);
        (uint256 out, uint256 spent, uint256 fee,) = router.fill(p);

        assertLe(spent + fee, amountIn, "INVARIANT: outlay <= amountIn");
        assertEq(before - tokenIn.balanceOf(trader), spent + fee, "the caller pays exactly spent + fee");
        assertEq(out, produced, "INVARIANT: the output is the raw venue output");
        assertEq(fee, (spent * inForce) / 10_000, "the fee is bps of what was consumed");
    }

    /*//////////////////////////////////////////////////////////////
                                 NATIVE
    //////////////////////////////////////////////////////////////*/

    function test_nativeIn_tokenOut() public {
        uint256 amountIn = 10 ether;
        uint256 budget = _budget(amountIn, INITIAL_BPS);
        bytes memory data = _swapCall(NATIVE, address(tokenOut), budget, 42 ether, address(executor));

        vm.prank(trader);
        (uint256 out,, uint256 fee, uint256 refund) =
            router.fill{value: amountIn}(_params(address(venue), NATIVE, address(tokenOut), amountIn, 42 ether, data));

        assertEq(out, 42 ether);
        assertEq(tokenOut.balanceOf(recipient), 42 ether);
        assertEq(address(router).balance, fee, "the fee accrues in native");
        assertEq(refund, amountIn - budget - fee);
        assertEq(address(executor).balance, 0);
    }

    function test_tokenIn_nativeOut() public {
        uint256 amountIn = 100 ether;
        uint256 budget = _budget(amountIn, INITIAL_BPS);
        bytes memory data = _swapCall(address(tokenIn), NATIVE, budget, 3 ether, address(executor));

        uint256 recipientBefore = recipient.balance;
        vm.prank(trader);
        (uint256 out,, uint256 fee,) =
            router.fill(_params(address(venue), address(tokenIn), NATIVE, amountIn, 3 ether, data));

        assertEq(out, 3 ether);
        assertEq(recipient.balance - recipientBefore, 3 ether);
        assertEq(tokenIn.balanceOf(address(router)), fee, "the fee accrues in the input currency");
        assertEq(address(router).balance, 0, "no native is left behind");
    }

    function test_nativeIn_valueMustMatchAmountIn() public {
        bytes memory data = _swapCall(NATIVE, address(tokenOut), 1 ether, 1 ether, address(executor));
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFillRouter.UnexpectedValue.selector, 10 ether, 9 ether));
        router.fill{value: 9 ether}(_params(address(venue), NATIVE, address(tokenOut), 10 ether, 0, data));
    }

    function test_erc20In_refusesValue() public {
        bytes memory data = _swapCall(address(tokenIn), address(tokenOut), 1 ether, 1 ether, address(executor));
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFillRouter.UnexpectedValue.selector, 0, 1 wei));
        router.fill{value: 1 wei}(_params(address(venue), address(tokenIn), address(tokenOut), 10 ether, 0, data));
    }

    /*//////////////////////////////////////////////////////////////
                            WRAP / UNWRAP
    //////////////////////////////////////////////////////////////*/

    function test_wrapInput_venueSeesWrappedNativeAndTheFeeStaysNative() public {
        uint256 amountIn = 10 ether;
        uint256 budget = _budget(amountIn, INITIAL_BPS);
        // The venue only deals in wrapped native.
        bytes memory data = _swapCall(address(wnative), address(tokenOut), budget, 7 ether, address(executor));

        DeepCoreFillRouter.FillParams memory p =
            _params(address(venue), NATIVE, address(tokenOut), amountIn, 7 ether, data);
        p.wrapInput = true;

        vm.prank(trader);
        (uint256 out, uint256 spent, uint256 fee,) = router.fill{value: amountIn}(p);

        assertEq(out, 7 ether);
        assertEq(spent, budget);
        assertEq(address(router).balance, fee, "the fee is held in native, not in the wrapper");
        assertEq(wnative.balanceOf(address(router)), 0, "no wrapped dust is left behind");
        assertEq(wnative.balanceOf(address(executor)), 0);
    }

    function test_wrapInput_partialConsumptionIsUnwrappedBackToTheCaller() public {
        uint256 amountIn = 10 ether;
        uint256 consumed = 4 ether;
        bytes memory data = _swapCall(address(wnative), address(tokenOut), consumed, 7 ether, address(executor));

        DeepCoreFillRouter.FillParams memory p =
            _params(address(venue), NATIVE, address(tokenOut), amountIn, 7 ether, data);
        p.wrapInput = true;

        uint256 before = trader.balance;
        vm.prank(trader);
        (, uint256 spent, uint256 fee, uint256 refund) = router.fill{value: amountIn}(p);

        assertEq(spent, consumed);
        assertEq(before - trader.balance, spent + fee, "the caller's native outlay is spent + fee");
        assertEq(refund, amountIn - spent - fee);
        assertEq(wnative.balanceOf(address(router)), 0);
    }

    function test_unwrapOutput_recipientGetsNative() public {
        uint256 amountIn = 100 ether;
        uint256 budget = _budget(amountIn, INITIAL_BPS);
        vm.deal(address(this), 5 ether);
        wnative.deposit{value: 5 ether}();
        wnative.transfer(address(venue), 5 ether);

        bytes memory data = _swapCall(address(tokenIn), address(wnative), budget, 5 ether, address(executor));
        DeepCoreFillRouter.FillParams memory p =
            _params(address(venue), address(tokenIn), NATIVE, amountIn, 5 ether, data);
        p.unwrapOutput = true;

        uint256 recipientBefore = recipient.balance;
        vm.prank(trader);
        (uint256 out,,,) = router.fill(p);

        assertEq(out, 5 ether);
        assertEq(recipient.balance - recipientBefore, 5 ether);
        assertEq(wnative.balanceOf(address(router)), 0);
    }

    function test_wrapMismatchIsRefused() public {
        bytes memory data = _swapCall(address(tokenIn), address(tokenOut), 1, 1, address(executor));
        DeepCoreFillRouter.FillParams memory p =
            _params(address(venue), address(tokenIn), address(tokenOut), 1 ether, 0, data);
        p.wrapInput = true;
        vm.prank(trader);
        vm.expectRevert(DeepCoreFillRouter.WrapMismatch.selector);
        router.fill(p);

        p.wrapInput = false;
        p.unwrapOutput = true;
        vm.prank(trader);
        vm.expectRevert(DeepCoreFillRouter.WrapMismatch.selector);
        router.fill(p);
    }

    function test_wrappingRefusedWhenNoWrappedNativeIsConfigured() public {
        DeepCoreFillRouter bare = new DeepCoreFillRouter(owner, safe, address(0), INITIAL_BPS, CAP_BPS, NOTICE, address(0));
        DeepCoreFillRouter.FillParams memory p = _params(address(venue), NATIVE, address(tokenOut), 1 ether, 0, "");
        p.wrapInput = true;
        vm.prank(trader);
        vm.expectRevert(DeepCoreFillRouter.WrappedNativeNotSet.selector);
        bare.fill{value: 1 ether}(p);
    }

    /*//////////////////////////////////////////////////////////////
                          THE DRAINER, CLOSED
    //////////////////////////////////////////////////////////////*/

    /// @dev The reason `DeepCoreFillExecutor` exists. A victim has an unlimited allowance to the router.
    /// An attacker points the fill at the TOKEN and hands it `transferFrom(victim, attacker, ...)`.
    /// If the router made that call itself it would succeed. It does not: the call comes from the
    /// executor, which nobody approves.
    function test_DRAINER_aTokenAsTheTargetCannotSpendTheRoutersAllowances() public {
        address victim = trader; // already approved the router for the maximum
        address attacker = makeAddr("attacker");
        uint256 victimBefore = tokenIn.balanceOf(victim);
        assertEq(tokenIn.allowance(victim, address(router)), type(uint256).max, "precondition: max allowance");

        bytes memory drain = abi.encodeCall(IERC20.transferFrom, (victim, attacker, victimBefore));

        tokenIn.mint(attacker, 1 ether);
        vm.startPrank(attacker);
        tokenIn.approve(address(router), type(uint256).max);
        vm.expectRevert(bytes("ALLOWANCE"));
        router.fill(_params(address(tokenIn), address(tokenIn), address(tokenOut), 1 ether, 0, drain));
        vm.stopPrank();

        assertEq(tokenIn.balanceOf(victim), victimBefore, "the victim is untouched");
        assertEq(tokenIn.balanceOf(attacker), 1 ether);
    }

    /// @dev The positive half of the drainer test: the arbitrary call is made BY the executor, which
    /// nobody approves, and never by the router, which everybody does.
    function test_theVenueIsCalledByTheExecutorNotTheRouter() public {
        uint256 amountIn = 10 ether;
        uint256 budget = _budget(amountIn, INITIAL_BPS);
        bytes memory data = _swapCall(address(tokenIn), address(tokenOut), budget, 1 ether, address(executor));
        vm.prank(trader);
        router.fill(_params(address(venue), address(tokenIn), address(tokenOut), amountIn, 1 ether, data));
        assertEq(venue.lastCaller(), address(executor), "the caller-chosen call must come from the executor");
        assertTrue(venue.lastCaller() != address(router));
    }

    /// @dev A venue can hand input currency back to the router out of its own pocket. The router
    /// cannot tell that apart from an unspent refund and does not try to: it reads as a smaller
    /// `spent`, so the venue has paid the caller's fee for them. Nobody is stolen from, the
    /// accounting stays exact, and the caller can only end up better off.
    function test_aVenuePushingInputBackIsTreatedAsARefundAndCostsOnlyTheVenue() public {
        uint256 amountIn = 100 ether;
        uint256 budget = _budget(amountIn, INITIAL_BPS);
        uint256 push = 50 ether;
        tokenIn.mint(address(venue), 500 ether);

        bytes memory data = abi.encodeCall(
            MockVenue.swapAndPush,
            (address(tokenIn), address(tokenOut), budget, 1 ether, address(executor), address(router), push)
        );

        uint256 before = tokenIn.balanceOf(trader);
        vm.prank(trader);
        (uint256 out, uint256 spent, uint256 fee, uint256 refund) =
            router.fill(_params(address(venue), address(tokenIn), address(tokenOut), amountIn, 1 ether, data));

        assertEq(out, 1 ether);
        assertEq(spent, budget - push);
        assertEq(fee, (spent * INITIAL_BPS) / 10_000);
        assertEq(spent + fee + refund, amountIn, "the accounting still closes exactly");
        assertEq(before - tokenIn.balanceOf(trader), spent + fee);
        assertEq(tokenIn.balanceOf(address(router)), fee, "nothing is left over and nothing is short");
    }

    /// @dev A push LARGER than the budget would make a naive `unspent` underflow and revert an
    /// otherwise good fill. It is clamped instead: the fill succeeds, `spent` bottoms out at zero and
    /// the surplus becomes a flushable donation to the protocol.
    function test_aVenuePushingMoreThanTheBudgetIsClampedRatherThanUnderflowing() public {
        uint256 amountIn = 100 ether;
        uint256 budget = _budget(amountIn, INITIAL_BPS);
        uint256 push = budget + 25 ether;
        tokenIn.mint(address(venue), 500 ether);

        bytes memory data = abi.encodeCall(
            MockVenue.swapAndPush,
            (address(tokenIn), address(tokenOut), budget, 1 ether, address(executor), address(router), push)
        );

        uint256 before = tokenIn.balanceOf(trader);
        vm.prank(trader);
        (, uint256 spent, uint256 fee, uint256 refund) =
            router.fill(_params(address(venue), address(tokenIn), address(tokenOut), amountIn, 1 ether, data));

        assertEq(spent, 0, "clamped, not underflowed");
        assertEq(fee, 0);
        assertEq(refund, amountIn);
        assertEq(tokenIn.balanceOf(trader), before, "the caller is whole");
        vm.prank(stranger);
        assertEq(router.flushFees(address(tokenIn)), push - budget, "the surplus leaves by the usual door");
    }

    /// @dev The venue is handed the budget and is approved for the budget - never for what the
    /// caller parted with. That bound is what makes `spent + fee <= amountIn` true.
    function test_theVenueCanNeverConsumeMoreThanTheBudget() public {
        uint256 amountIn = 100 ether;
        // The calldata asks for the WHOLE input, not the budget.
        bytes memory data = _swapCall(address(tokenIn), address(tokenOut), amountIn, 1 ether, address(executor));
        vm.prank(trader);
        vm.expectRevert(bytes("ALLOWANCE"));
        router.fill(_params(address(venue), address(tokenIn), address(tokenOut), amountIn, 1 ether, data));
    }

    /// @dev No allowance survives a fill. The executor holds nothing at rest, so a surviving one
    /// would reach nothing - but a venue that could re-enter later on a stale approval is exactly
    /// the kind of thing that is cheap to close and expensive to explain.
    function test_noAllowanceSurvivesAFill() public {
        uint256 amountIn = 100 ether;
        uint256 budget = _budget(amountIn, INITIAL_BPS);
        // The venue consumes only part of what it was approved for.
        bytes memory data = _swapCall(address(tokenIn), address(tokenOut), budget / 2, 1 ether, address(executor));
        vm.prank(trader);
        router.fill(_params(address(venue), address(tokenIn), address(tokenOut), amountIn, 1 ether, data));
        assertEq(tokenIn.allowance(address(executor), address(venue)), 0, "the approval must be put back to zero");
    }

    function test_targetCannotBeTheRouterOrTheExecutor() public {
        vm.startPrank(trader);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFillExecutor.InvalidTarget.selector, address(router)));
        router.fill(_params(address(router), address(tokenIn), address(tokenOut), 1 ether, 0, ""));

        vm.expectRevert(abi.encodeWithSelector(DeepCoreFillExecutor.InvalidTarget.selector, address(executor)));
        router.fill(_params(address(executor), address(tokenIn), address(tokenOut), 1 ether, 0, ""));
        vm.stopPrank();
    }

    function test_targetWithNoCodeIsRefused() public {
        address eoa = makeAddr("eoa");
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFillExecutor.TargetHasNoCode.selector, eoa));
        router.fill(_params(eoa, address(tokenIn), address(tokenOut), 1 ether, 0, ""));
    }

    function test_executorRefusesEveryoneButTheRouter() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFillExecutor.NotRouter.selector, stranger));
        executor.execute(address(venue), "", address(tokenIn), address(tokenOut));
    }

    /*//////////////////////////////////////////////////////////////
                              REENTRANCY
    //////////////////////////////////////////////////////////////*/

    function _reentrancyCase(ReentrantVenue.Mode mode) internal {
        ReentrantVenue attacker = new ReentrantVenue(router);
        attacker.setMode(mode);
        bytes memory data = abi.encodeCall(ReentrantVenue.attack, (address(tokenIn), address(tokenOut)));

        vm.prank(trader);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        router.fill(_params(address(attacker), address(tokenIn), address(tokenOut), 1 ether, 0, data));
    }

    function test_reentrancy_fillFromInsideAFill() public {
        _reentrancyCase(ReentrantVenue.Mode.FillAgain);
    }

    function test_reentrancy_flushFeesFromInsideAFill() public {
        _reentrancyCase(ReentrantVenue.Mode.FlushFees);
    }

    function test_reentrancy_executeDirectlyFromInsideAFill() public {
        // `execute` is onlyRouter, so a venue calling it directly is refused before the guard.
        ReentrantVenue attacker = new ReentrantVenue(router);
        attacker.setMode(ReentrantVenue.Mode.ExecuteDirectly);
        bytes memory data = abi.encodeCall(ReentrantVenue.attack, (address(tokenIn), address(tokenOut)));
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFillExecutor.NotRouter.selector, address(attacker)));
        router.fill(_params(address(attacker), address(tokenIn), address(tokenOut), 1 ether, 0, data));
    }

    function test_reentrancy_sweepStrayFromInsideAFillCannotDivertTheFunds() public {
        _reentrancyCase(ReentrantVenue.Mode.SweepStray);
    }

    /*//////////////////////////////////////////////////////////////
                         SLIPPAGE AND BOUNDS
    //////////////////////////////////////////////////////////////*/

    function test_shortFillReverts() public {
        uint256 amountIn = 100 ether;
        uint256 budget = _budget(amountIn, INITIAL_BPS);
        bytes memory data = _swapCall(address(tokenIn), address(tokenOut), budget, 9 ether, address(executor));

        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFillRouter.InsufficientOutput.selector, 9 ether, 10 ether));
        router.fill(_params(address(venue), address(tokenIn), address(tokenOut), amountIn, 10 ether, data));
    }

    function test_aVenueThatKeepsEverythingAndPaysNothingRevertsTheWholeFill() public {
        uint256 amountIn = 100 ether;
        uint256 budget = _budget(amountIn, INITIAL_BPS);
        bytes memory data = abi.encodeCall(MockVenue.steal, (address(tokenIn), budget));

        uint256 before = tokenIn.balanceOf(trader);
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFillRouter.InsufficientOutput.selector, 0, 1));
        router.fill(_params(address(venue), address(tokenIn), address(tokenOut), amountIn, 1, data));
        assertEq(tokenIn.balanceOf(trader), before, "the caller loses nothing but gas");
    }

    function test_deadlineIsEnforced() public {
        DeepCoreFillRouter.FillParams memory p =
            _params(address(venue), address(tokenIn), address(tokenOut), 1 ether, 0, "");
        p.deadline = block.timestamp - 1;
        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreFillRouter.DeadlinePassed.selector, block.timestamp - 1, block.timestamp)
        );
        router.fill(p);
    }

    function test_zeroRecipientAndZeroAmountAreRefused() public {
        DeepCoreFillRouter.FillParams memory p =
            _params(address(venue), address(tokenIn), address(tokenOut), 1 ether, 0, "");
        p.recipient = address(0);
        vm.prank(trader);
        vm.expectRevert(DeepCoreFillRouter.ZeroAddress.selector);
        router.fill(p);

        p.recipient = recipient;
        p.amountIn = 0;
        vm.prank(trader);
        vm.expectRevert(DeepCoreFillRouter.ZeroAmount.selector);
        router.fill(p);
    }

    function test_identicalCurrenciesAreRefused() public {
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFillRouter.IdenticalCurrencies.selector, address(tokenIn)));
        router.fill(_params(address(venue), address(tokenIn), address(tokenIn), 1 ether, 0, ""));
    }

    function test_identicalVenueCurrenciesAreRefused() public {
        // currencyIn is the wrapper itself and the output is native-with-unwrap: both legs would be
        // the wrapper at the venue, and the two balance deltas would conflate.
        DeepCoreFillRouter.FillParams memory p = _params(address(venue), address(wnative), NATIVE, 1 ether, 0, "");
        p.unwrapOutput = true;
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFillRouter.IdenticalCurrencies.selector, address(wnative)));
        router.fill(p);
    }

    function test_venueRevertsBubbleUp() public {
        vm.prank(trader);
        vm.expectRevert(MockVenue.VenueRevert.selector);
        router.fill(
            _params(
                address(venue), address(tokenIn), address(tokenOut), 1 ether, 0, abi.encodeCall(MockVenue.boom, ())
            )
        );
    }

    function test_silentVenueRevertBecomesANamedError() public {
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFillExecutor.VenueCallFailed.selector, address(venue)));
        router.fill(
            _params(
                address(venue),
                address(tokenIn),
                address(tokenOut),
                1 ether,
                0,
                abi.encodeCall(MockVenue.boomSilently, ())
            )
        );
    }

    function test_aRecipientThatRefusesNativeRevertsTheFillRatherThanStranding() public {
        NativeRejector rejector = new NativeRejector();
        uint256 amountIn = 100 ether;
        uint256 budget = _budget(amountIn, INITIAL_BPS);
        bytes memory data = _swapCall(address(tokenIn), NATIVE, budget, 1 ether, address(executor));

        DeepCoreFillRouter.FillParams memory p =
            _params(address(venue), address(tokenIn), NATIVE, amountIn, 1 ether, data);
        p.recipient = address(rejector);
        vm.prank(trader);
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreFillRouter.NativeTransferFailed.selector, address(rejector), 1 ether)
        );
        router.fill(p);
    }

    /*//////////////////////////////////////////////////////////////
                       FEE-ON-TRANSFER: CANNOT BREAK IT
    //////////////////////////////////////////////////////////////*/

    function test_feeOnTransferInput_theRouterStaysSolventAndChargesOnWhatArrived() public {
        MockFeeOnTransferERC20 fot = new MockFeeOnTransferERC20("FoT", "FOT", 100); // 1% burn per transfer
        fot.mint(trader, 1_000 ether);
        vm.prank(trader);
        fot.approve(address(router), type(uint256).max);

        uint256 amountIn = 1_000 ether;
        uint256 received = amountIn - (amountIn * 100) / 10_000; // what actually lands on the router
        uint256 budget = _budget(received, INITIAL_BPS);
        uint256 atVenue = budget - (budget * 100) / 10_000; // the transfer to the executor burns again

        bytes memory data = _swapCall(address(fot), address(tokenOut), atVenue, 1 ether, address(executor));

        vm.prank(trader);
        (uint256 out, uint256 spent, uint256 fee, uint256 refund) =
            router.fill(_params(address(venue), address(fot), address(tokenOut), amountIn, 1 ether, data));

        assertEq(out, 1 ether, "the output leg is unaffected");
        // Accounting is on measured deltas, so nothing is over-paid and the router never runs a deficit.
        assertLe(spent + fee, received, "the router cannot promise more than it received");
        assertGe(fot.balanceOf(address(router)), 0);
        assertEq(refund, received - spent - fee);
    }

    function test_feeOnTransferOutput_theRecipientGetsWhatArrivedOrTheFillReverts() public {
        MockFeeOnTransferERC20 fotOut = new MockFeeOnTransferERC20("FoTOut", "FOTO", 100);
        fotOut.mint(address(venue), 1_000 ether);

        uint256 amountIn = 100 ether;
        uint256 budget = _budget(amountIn, INITIAL_BPS);
        bytes memory data = _swapCall(address(tokenIn), address(fotOut), budget, 10 ether, address(executor));

        // The executor receives 9.9, and the sweep to the router burns again: 9.801 lands.
        uint256 atExecutor = 10 ether - (10 ether * 100) / 10_000;
        uint256 atRouter = atExecutor - (atExecutor * 100) / 10_000;

        // Quoting the pre-burn number reverts, honestly, instead of silently under-delivering.
        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFillRouter.InsufficientOutput.selector, atRouter, 10 ether));
        router.fill(_params(address(venue), address(tokenIn), address(fotOut), amountIn, 10 ether, data));

        vm.prank(trader);
        (uint256 out,,,) = router.fill(_params(address(venue), address(tokenIn), address(fotOut), amountIn, 1, data));
        assertEq(out, atRouter);
        // The recipient's own transfer burns once more; what matters is the router promised nothing it
        // could not deliver.
        assertEq(fotOut.balanceOf(recipient), atRouter - (atRouter * 100) / 10_000);
    }

    /*//////////////////////////////////////////////////////////////
                         ACCRUED FEES ARE NEVER A SOURCE
    //////////////////////////////////////////////////////////////*/

    function test_aResidentFeeBalanceIsNeverPaidOutToACaller() public {
        // First fill leaves a fee on the router.
        uint256 amountIn = 1_000 ether;
        uint256 budget = _budget(amountIn, INITIAL_BPS);
        bytes memory data = _swapCall(address(tokenIn), address(tokenOut), budget, 1 ether, address(executor));
        vm.prank(trader);
        (,, uint256 fee1,) =
            router.fill(_params(address(venue), address(tokenIn), address(tokenOut), amountIn, 1 ether, data));
        assertGt(fee1, 0);
        assertEq(tokenIn.balanceOf(address(router)), fee1);

        // A second, identical fill must behave identically - the resting balance changes nothing.
        vm.prank(trader);
        (, uint256 spent2, uint256 fee2, uint256 refund2) =
            router.fill(_params(address(venue), address(tokenIn), address(tokenOut), amountIn, 1 ether, data));
        assertEq(spent2, budget);
        assertEq(fee2, fee1);
        assertEq(spent2 + fee2 + refund2, amountIn);
        assertEq(tokenIn.balanceOf(address(router)), fee1 + fee2);
    }

    /*//////////////////////////////////////////////////////////////
                            GOVERNANCE: THE FEE
    //////////////////////////////////////////////////////////////*/

    function test_increaseWaitsTheNotice_decreaseIsImmediate() public {
        assertEq(router.feeBps(), INITIAL_BPS);

        vm.prank(owner);
        router.setFeeBps(25);
        assertEq(router.feeBps(), INITIAL_BPS, "an increase is not the fee yet");
        (uint16 pendingBps, uint64 at) = router.pendingFee();
        assertEq(pendingBps, 25);
        assertEq(at, uint64(block.timestamp + NOTICE));

        vm.warp(block.timestamp + NOTICE - 1);
        assertEq(router.feeBps(), INITIAL_BPS);
        vm.warp(block.timestamp + 1);
        assertEq(router.feeBps(), 25, "it applies itself, with no transaction");

        vm.prank(owner);
        router.setFeeBps(1);
        assertEq(router.feeBps(), 1, "a decrease is immediate");
    }

    function test_aNewIncreaseRestartsTheNotice() public {
        vm.prank(owner);
        router.setFeeBps(20);
        vm.warp(block.timestamp + NOTICE - 10);
        vm.prank(owner);
        router.setFeeBps(30);
        vm.warp(block.timestamp + 11);
        assertEq(router.feeBps(), INITIAL_BPS, "the first notice cannot be inherited by the second");
        vm.warp(block.timestamp + NOTICE);
        assertEq(router.feeBps(), 30);
    }

    function test_pendingIncreaseCanBeCancelled() public {
        vm.prank(owner);
        router.setFeeBps(40);
        vm.prank(owner);
        router.cancelPendingFee();
        vm.warp(block.timestamp + NOTICE * 2);
        assertEq(router.feeBps(), INITIAL_BPS);

        vm.prank(owner);
        vm.expectRevert(DeepCoreFillRouter.NoPendingFee.selector);
        router.cancelPendingFee();
    }

    function test_theCapBinds() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFillRouter.FeeAboveCap.selector, CAP_BPS + 1, CAP_BPS));
        router.setFeeBps(CAP_BPS + 1);
    }

    function test_theContractCeilingBindsTheCapAtDeployment() public {
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreFillRouter.FeeAboveCap.selector, uint16(101), router.ABSOLUTE_MAX_FEE_BPS())
        );
        new DeepCoreFillRouter(owner, safe, address(wnative), 10, 101, NOTICE, address(0));
    }

    function test_constructorRefusesABadNoticeAndAZeroRecipient() public {
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFillRouter.InvalidNotice.selector, uint32(1 hours)));
        new DeepCoreFillRouter(owner, safe, address(wnative), 10, CAP_BPS, 1 hours, address(0));

        vm.expectRevert(DeepCoreFillRouter.ZeroAddress.selector);
        new DeepCoreFillRouter(owner, address(0), address(wnative), 10, CAP_BPS, NOTICE, address(0));
    }

    function test_aStrangerCannotSetAnything() public {
        vm.startPrank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        router.setFeeBps(0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        router.cancelPendingFee();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        router.exemptVenue(address(venue));
        vm.stopPrank();
    }

    function test_renounceIsDisabled() public {
        vm.prank(owner);
        vm.expectRevert(DeepCoreFillRouter.RenounceDisabled.selector);
        router.renounceOwnership();
        assertEq(router.owner(), owner);
    }

    /// @dev A governance increase must never reprice a transaction that was already quoted and signed.
    function test_aScheduledIncreaseCannotRepriceASignedTransaction() public {
        vm.prank(owner);
        router.setFeeBps(50);
        vm.warp(block.timestamp + NOTICE);
        assertEq(router.feeBps(), 50);

        bytes memory data = _swapCall(address(tokenIn), address(tokenOut), 1 ether, 1 ether, address(executor));
        DeepCoreFillRouter.FillParams memory p =
            _params(address(venue), address(tokenIn), address(tokenOut), 100 ether, 0, data);
        p.maxFeeBps = INITIAL_BPS; // what the caller was quoted before the increase landed
        p.deadline = block.timestamp + 1 hours;

        vm.prank(trader);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFillRouter.FeeAboveQuoted.selector, uint16(50), INITIAL_BPS));
        router.fill(p);
    }

    /*//////////////////////////////////////////////////////////////
                          GOVERNANCE: EXEMPTIONS
    //////////////////////////////////////////////////////////////*/

    function test_anExemptVenuePaysZeroAndTheExemptionIsIrreversible() public {
        vm.prank(owner);
        router.exemptVenue(address(venue));
        assertTrue(router.isFeeExempt(address(venue)));

        (uint16 bps, uint256 budget, uint256 maxFee) = router.quoteFill(address(venue), 100 ether);
        assertEq(bps, 0);
        assertEq(budget, 100 ether);
        assertEq(maxFee, 0);

        bytes memory data = _swapCall(address(tokenIn), address(tokenOut), 100 ether, 1 ether, address(executor));
        vm.prank(trader);
        (, uint256 spent, uint256 fee, uint256 refund) =
            router.fill(_params(address(venue), address(tokenIn), address(tokenOut), 100 ether, 1 ether, data));
        assertEq(spent, 100 ether);
        assertEq(fee, 0, "0 on an exempt venue - the DeepCore-pool case");
        assertEq(refund, 0);

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreFillRouter.AlreadyExempt.selector, address(venue)));
        router.exemptVenue(address(venue));
    }

    /// @dev "0 on a DeepCore pool" must not depend on a transaction somebody remembers to send on each
    /// chain, so the first exemption is a constructor argument.
    function test_theConstructorCanExemptDeepCoresOwnRouterFromBirth() public {
        vm.expectEmit(true, false, false, false);
        emit DeepCoreFillRouter.VenueFeeExempted(address(venue));
        DeepCoreFillRouter r =
            new DeepCoreFillRouter(owner, safe, address(wnative), INITIAL_BPS, CAP_BPS, NOTICE, address(venue));
        assertTrue(r.isFeeExempt(address(venue)));
        (uint16 bps,, uint256 maxFee) = r.quoteFill(address(venue), 1 ether);
        assertEq(bps, 0);
        assertEq(maxFee, 0);
        // Everything else still pays.
        (bps,,) = r.quoteFill(address(0xBEEF), 1 ether);
        assertEq(bps, INITIAL_BPS);
    }

    function test_quoteFillMatchesWhatAFillActuallyDoes() public {
        uint256 amountIn = 777 ether;
        (uint16 bps, uint256 budget, uint256 maxFee) = router.quoteFill(address(venue), amountIn);
        assertEq(bps, INITIAL_BPS);

        bytes memory data = _swapCall(address(tokenIn), address(tokenOut), budget, 1 ether, address(executor));
        vm.prank(trader);
        (, uint256 spent, uint256 fee,) =
            router.fill(_params(address(venue), address(tokenIn), address(tokenOut), amountIn, 1 ether, data));
        assertEq(spent, budget, "the quote's budget is what the venue may consume");
        assertEq(fee, maxFee, "the quote's fee is what a full consumption costs");
    }

    /*//////////////////////////////////////////////////////////////
                                 FLUSH
    //////////////////////////////////////////////////////////////*/

    function test_flushIsPermissionlessAndPaysOnlyTheRecipient() public {
        uint256 amountIn = 1_000 ether;
        uint256 budget = _budget(amountIn, INITIAL_BPS);
        bytes memory data = _swapCall(address(tokenIn), address(tokenOut), budget, 1 ether, address(executor));
        vm.prank(trader);
        (,, uint256 fee,) =
            router.fill(_params(address(venue), address(tokenIn), address(tokenOut), amountIn, 1 ether, data));

        vm.prank(stranger);
        uint256 flushed = router.flushFees(address(tokenIn));
        assertEq(flushed, fee);
        assertEq(tokenIn.balanceOf(safe), fee, "only the immutable recipient is ever paid");
        assertEq(tokenIn.balanceOf(address(router)), 0);

        vm.expectRevert(abi.encodeWithSelector(DeepCoreFillRouter.NothingToFlush.selector, address(tokenIn)));
        router.flushFees(address(tokenIn));
    }

    function test_forcedAndMisdirectedValueLeavesByTheSameDoor() public {
        // Misdirected ERC-20 and plain native both become flushable.
        tokenOut.mint(address(router), 5 ether);
        vm.deal(address(this), 3 ether);
        (bool ok,) = address(router).call{value: 3 ether}("");
        assertTrue(ok);

        vm.prank(stranger);
        assertEq(router.flushFees(address(tokenOut)), 5 ether);
        vm.prank(stranger);
        assertEq(router.flushFees(NATIVE), 3 ether);
        assertEq(tokenOut.balanceOf(safe), 5 ether);
        assertEq(safe.balance, 3 ether);
    }

    function test_strayValueOnTheExecutorLeavesToTheProtocolRecipient() public {
        tokenOut.mint(address(executor), 2 ether);
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(executor).call{value: 1 ether}("");
        assertTrue(ok);

        vm.prank(stranger);
        assertEq(executor.sweepStray(address(tokenOut)), 2 ether);
        vm.prank(stranger);
        assertEq(executor.sweepStray(NATIVE), 1 ether);
        assertEq(tokenOut.balanceOf(safe), 2 ether);
        assertEq(safe.balance, 1 ether);

        vm.expectRevert(abi.encodeWithSelector(DeepCoreFillExecutor.NothingToSweep.selector, NATIVE));
        executor.sweepStray(NATIVE);
    }

    /*//////////////////////////////////////////////////////////////
                            WIRING / IMMUTABLES
    //////////////////////////////////////////////////////////////*/

    function test_theExecutorIsBoundToThisRouterAndToTheSafe() public view {
        assertEq(executor.ROUTER(), address(router));
        assertEq(executor.protocolFeeRecipient(), safe);
        assertEq(router.protocolFeeRecipient(), safe);
        assertEq(router.WNATIVE(), address(wnative));
        assertEq(router.maxFeeBps(), CAP_BPS);
        assertEq(router.feeNoticeSeconds(), NOTICE);
    }

    function test_executorConstructorRefusesZeroAddresses() public {
        vm.expectRevert(DeepCoreFillExecutor.ZeroAddress.selector);
        new DeepCoreFillExecutor(address(0), safe);
        vm.expectRevert(DeepCoreFillExecutor.ZeroAddress.selector);
        new DeepCoreFillExecutor(address(router), address(0));
    }

    receive() external payable {}
}
