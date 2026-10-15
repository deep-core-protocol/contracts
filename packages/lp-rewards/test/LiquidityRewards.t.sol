// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";

import {DeepCoreLiquidityRewardsHook} from "../src/DeepCoreLiquidityRewardsHook.sol";
import {LiquidityRewardsModule} from "../src/LiquidityRewardsModule.sol";
import {IDeepCoreLiquidityRewards as I} from "../src/interfaces/IDeepCoreLiquidityRewards.sol";
import {RewardsFixture} from "./utils/RewardsFixture.sol";

contract LiquidityRewardsTest is RewardsFixture {
    using CLPoolParametersHelper for bytes32;
    using PoolIdLibrary for PoolKey;

    Currency internal R;

    function setUp() public override {
        super.setUp();
        R = Currency.wrap(address(rwd));
    }

    /*//////////////////////////////////////////////////////////////
                         DEPLOYMENT AND IDENTITY
    //////////////////////////////////////////////////////////////*/

    function test_bitmapAndIdentity() public view {
        assertEq(hook.getHooksRegistrationBitmap(), 0x0095);
        assertEq(hook.kind(), keccak256("deepcore.liquidity-rewards.cl.v1"));
        assertEq(hook.owner(), SAFE);
        assertEq(hook.protocolFeeRecipient(), SAFE);
        assertEq(hook.POSITION_MANAGER(), address(posm));
        assertEq(hook.RECYCLE_DELAY(), RECYCLE);
        assertEq(hook.RECLAIM_DELAY(), RECLAIM);
        assertEq(hook.protocolFeeBps(), FEE_BPS);
        assertEq(hook.maxProtocolFeeBps(), MAX_FEE_BPS);
    }

    function test_realHookFitsEip170() public {
        DeepCoreLiquidityRewardsHook real = new DeepCoreLiquidityRewardsHook(manager, _params(1_000));
        emit log_named_uint("DeepCoreLiquidityRewardsHook runtime bytes", address(real).code.length);
        assertLe(address(real).code.length, 24_576);
    }

    function test_constructorGuards() public {
        LiquidityRewardsModule.ModuleParams memory p = _params(1);
        p.positionManager = address(0);
        vm.expectRevert(I.ZeroAddress.selector);
        new DeepCoreLiquidityRewardsHook(manager, p);

        p = _params(1);
        p.protocolFeeRecipient = address(0);
        vm.expectRevert(I.ZeroAddress.selector);
        new DeepCoreLiquidityRewardsHook(manager, p);

        p = _params(1);
        p.maxFeeBps = 301;
        vm.expectRevert(abi.encodeWithSelector(I.FeeAboveCap.selector, 301, 300));
        new DeepCoreLiquidityRewardsHook(manager, p);

        p = _params(1);
        p.initialFeeBps = 301;
        p.maxFeeBps = 300;
        vm.expectRevert(abi.encodeWithSelector(I.FeeAboveCap.selector, 301, 300));
        new DeepCoreLiquidityRewardsHook(manager, p);

        p = _params(1);
        p.feeNoticeSeconds = 1 days - 1;
        vm.expectRevert(abi.encodeWithSelector(I.InvalidNotice.selector, 1 days - 1));
        new DeepCoreLiquidityRewardsHook(manager, p);

        p = _params(1);
        p.recycleDelay = 30 days - 1;
        vm.expectRevert(I.InvalidDelay.selector);
        new DeepCoreLiquidityRewardsHook(manager, p);

        p = _params(1);
        p.reclaimDelay = 731 days;
        vm.expectRevert(I.InvalidDelay.selector);
        new DeepCoreLiquidityRewardsHook(manager, p);

        p = _params(0);
        vm.expectRevert(I.ZeroAmount.selector);
        new DeepCoreLiquidityRewardsHook(manager, p);
    }

    function test_renounceReverts_ownershipTwoStep() public {
        vm.prank(SAFE);
        vm.expectRevert(I.RenounceDisabled.selector);
        hook.renounceOwnership();

        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        hook.transferOwnership(STRANGER);

        address next = makeAddr("nextSafe");
        vm.prank(SAFE);
        hook.transferOwnership(next);
        assertEq(hook.owner(), SAFE);
        vm.prank(next);
        hook.acceptOwnership();
        assertEq(hook.owner(), next);
    }

    /*//////////////////////////////////////////////////////////////
                              CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function _freshKey(uint24 fee) internal view returns (PoolKey memory k) {
        k = key;
        k.fee = fee;
    }

    function test_configure_refusals() public {
        PoolKey memory k = _freshKey(500);
        Currency[] memory none = new Currency[](0);
        I.RewardsConfig memory cfg = I.RewardsConfig({rewardTokens: none, minWidthTicks: 0});

        // already configured (the fixture's pool)
        vm.expectRevert(I.PoolAlreadyConfigured.selector);
        hook.configureRewards(key, cfg);

        PoolKey memory wrongHook = _freshKey(500);
        wrongHook.hooks = IHooks(address(0xBEEF));
        vm.expectRevert(I.WrongHook.selector);
        hook.configureRewards(wrongHook, cfg);

        PoolKey memory wrongPm = _freshKey(500);
        wrongPm.poolManager = IPoolManager(address(0xBEEF));
        vm.expectRevert(I.WrongPoolManager.selector);
        hook.configureRewards(wrongPm, cfg);

        Currency[] memory four = new Currency[](4);
        for (uint256 i; i < 4; ++i) four[i] = Currency.wrap(address(uint160(i + 1)));
        vm.expectRevert(I.TooManyRewardTokens.selector);
        hook.configureRewards(k, I.RewardsConfig({rewardTokens: four, minWidthTicks: 0}));

        Currency[] memory dup = new Currency[](2);
        dup[0] = R;
        dup[1] = R;
        vm.expectRevert(I.DuplicateRewardToken.selector);
        hook.configureRewards(k, I.RewardsConfig({rewardTokens: dup, minWidthTicks: 0}));

        vm.expectRevert(I.MinWidthTooLarge.selector);
        hook.configureRewards(k, I.RewardsConfig({rewardTokens: none, minWidthTicks: 1_774_545}));
    }

    function test_initialize_refusesAnUnconfiguredPool_acceptsAConfiguredOne() public {
        PoolKey memory k = _freshKey(500);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                ICLHooks.beforeInitialize.selector,
                abi.encodeWithSelector(I.PoolNotConfigured.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(k, SQRT_RATIO_1_1);
        (bool before,,,,) = hook.poolConfig(k.toId());
        assertFalse(before);

        vm.prank(STRANGER);
        hook.configureRewards(k, I.RewardsConfig({rewardTokens: _rewardList(R), minWidthTicks: 20}));
        manager.initialize(k, SQRT_RATIO_1_1);
        (bool init, int24 spacing, int24 last, uint24 minW,) = hook.poolConfig(k.toId());
        assertTrue(init);
        assertEq(spacing, SPACING);
        assertEq(last, 0);
        assertEq(minW, 20);
        assertEq(hook.poolOwner(k.toId()), STRANGER);
        assertEq(hook.zeroLiquiditySince(k.toId()), block.timestamp);
    }

    function test_allowRewardToken() public {
        MockLike t2 = new MockLike();
        vm.prank(STRANGER);
        vm.expectRevert(I.NotPoolOwner.selector);
        hook.allowRewardToken(key, Currency.wrap(address(t2)));

        vm.prank(CREATOR);
        vm.expectRevert(I.DuplicateRewardToken.selector);
        hook.allowRewardToken(key, R);

        vm.startPrank(CREATOR);
        hook.allowRewardToken(key, Currency.wrap(address(t2)));
        hook.allowRewardToken(key, Currency.wrap(address(0)));
        vm.expectRevert(I.TooManyRewardTokens.selector);
        hook.allowRewardToken(key, Currency.wrap(address(0x1234)));
        vm.stopPrank();
        assertEq(hook.rewardTokens(id).length, 3);
    }

    function test_poolOwnership_twoStep() public {
        vm.prank(STRANGER);
        vm.expectRevert(I.NotPoolOwner.selector);
        hook.transferPoolOwnership(id, STRANGER);

        vm.prank(CREATOR);
        hook.transferPoolOwnership(id, LP1);
        vm.prank(STRANGER);
        vm.expectRevert(I.NotPendingPoolOwner.selector);
        hook.acceptPoolOwnership(id);
        assertEq(hook.poolOwner(id), CREATOR);
        vm.prank(LP1);
        hook.acceptPoolOwnership(id);
        assertEq(hook.poolOwner(id), LP1);
        assertEq(hook.pendingPoolOwner(id), address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                 STREAMS
    //////////////////////////////////////////////////////////////*/

    function test_startStream_refusals() public {
        vm.prank(STRANGER);
        vm.expectRevert(I.NotPoolOwner.selector);
        hook.startStream(key, R, 1e18, 1 days, REFUND);

        vm.startPrank(CREATOR);
        vm.expectRevert(I.DurationOutOfRange.selector);
        hook.startStream(key, R, 1e18, 1 days - 1, REFUND);
        vm.expectRevert(I.DurationOutOfRange.selector);
        hook.startStream(key, R, 1e18, 365 days + 1, REFUND);
        vm.expectRevert(I.InvalidRefundRecipient.selector);
        hook.startStream(key, R, 1e18, 1 days, address(0));
        vm.expectRevert(I.ZeroAmount.selector);
        hook.startStream(key, R, 0, 1 days, REFUND);
        vm.expectRevert(I.TokenNotAllowed.selector);
        hook.startStream(key, Currency.wrap(address(0xABCD)), 1e18, 1 days, REFUND);
        vm.deal(CREATOR, 1 ether);
        vm.expectRevert(I.NativeNotAccepted.selector);
        hook.startStream{value: 1}(key, R, 1e18, 1 days, REFUND);
        hook.startStream(key, R, 1e18, 1 days, REFUND);
        vm.expectRevert(I.StreamRunning.selector);
        hook.startStream(key, R, 1e18, 1 days, REFUND);
        vm.stopPrank();
    }

    function test_startStream_booksFeeAndRate() public {
        _start(1000e18, 10 days);
        (uint256 rate, uint64 finish, uint256 und, address refund) = hook.streamOf(id, R);
        assertEq(und, _net(1000e18));
        assertEq(rate, (_net(1000e18) << 64) / 10 days);
        assertEq(finish, T0 + 10 days);
        assertEq(refund, REFUND);
        assertEq(hook.protocolOwed(R), 10e18);
        assertEq(hook.totalOwed(R), 1000e18);
        assertEq(rwd.balanceOf(address(hook)), 1000e18);

        hook.flushProtocolFees(R);
        assertEq(rwd.balanceOf(SAFE), 10e18);
        assertEq(hook.totalOwed(R), 990e18);
        vm.expectRevert(I.NothingToFlush.selector);
        hook.flushProtocolFees(R);
    }

    function test_singleLp_takesTheWholeStream() public {
        uint256 tid = _mintNft(LP1, -1000, 1000, 1e18);
        _start(1000e18, 10 days);
        vm.warp(T0 + 5 days);
        assertApproxEqAbs(_earned0(_nftKey(tid, -1000, 1000)), _net(1000e18) / 2, 1e6);
        vm.warp(T0 + 20 days);
        uint256 e = _earned0(_nftKey(tid, -1000, 1000));
        uint256 got = _claim(LP1, _nftKey(tid, -1000, 1000), LP1);
        assertEq(got, e);
        assertApproxEqAbs(got, _net(1000e18), 2);
        assertLe(got, _net(1000e18));
        assertEq(rwd.balanceOf(LP1), got);
        vm.prank(LP1);
        vm.expectRevert(I.NothingToClaim.selector);
        hook.claim(id, _nftKey(tid, -1000, 1000), LP1);
    }

    function test_twoLps_lateJoiner_shareByTimeAndLiquidity() public {
        uint256 a = _mintNft(LP1, -1000, 1000, 1e18);
        _start(1000e18, 10 days);
        vm.warp(T0 + 5 days);
        uint256 b = _mintNft(LP2, -1000, 1000, 1e18);
        vm.warp(T0 + 10 days);
        uint256 net = _net(1000e18);
        uint256 ga = _claim(LP1, _nftKey(a, -1000, 1000), LP1);
        uint256 gb = _claim(LP2, _nftKey(b, -1000, 1000), LP2);
        assertApproxEqAbs(ga, net * 3 / 4, 1e6);
        assertApproxEqAbs(gb, net / 4, 1e6);
        assertLe(ga + gb, net);
        assertApproxEqAbs(ga + gb, net, 4);
    }

    function test_outOfRangeEarnsNothing() public {
        uint256 inR = _mintNft(LP1, -100, 100, 1e18);
        uint256 outR = _mintNft(LP2, 100, 200, 1e18);
        _start(1000e18, 10 days);
        vm.warp(T0 + 10 days);
        assertEq(_earned0(_nftKey(outR, 100, 200)), 0);
        assertApproxEqAbs(_claim(LP1, _nftKey(inR, -100, 100), LP1), _net(1000e18), 2);
        vm.prank(LP2);
        vm.expectRevert(I.NothingToClaim.selector);
        hook.claim(id, _nftKey(outR, 100, 200), LP2);
    }

    function test_crossingUpAndDown_paysTimeInRangeOnly() public {
        uint256 a = _mintNft(LP1, -100, 100, 1e18);
        uint256 b = _mintNft(LP2, 100, 300, 1e18);
        _start(1000e18, 10 days);
        vm.warp(T0 + 2 days);
        _swapToTick(150);
        assertEq(_tick(), 150);
        assertEq(hook.eligibleLiquidity(id), 1e18);
        vm.warp(T0 + 5 days);
        _swapToTick(0);
        assertTrue(_tick() >= -100 && _tick() < 100);
        vm.warp(T0 + 10 days);
        uint256 net = _net(1000e18);
        uint256 ga = _claim(LP1, _nftKey(a, -100, 100), LP1);
        uint256 gb = _claim(LP2, _nftKey(b, 100, 300), LP2);
        assertApproxEqAbs(ga, net * 7 / 10, 1e6);
        assertApproxEqAbs(gb, net * 3 / 10, 1e6);
        assertLe(ga + gb, net);
    }

    function test_crossingDownBelowAndBack() public {
        uint256 a = _mintNft(LP1, -300, -100, 1e18);
        uint256 b = _mintNft(LP2, -100, 100, 1e18);
        _start(1000e18, 10 days);
        vm.warp(T0 + 4 days);
        _swapToTick(-150);
        assertEq(hook.eligibleLiquidity(id), 1e18);
        vm.warp(T0 + 6 days);
        _swapToTick(50);
        vm.warp(T0 + 10 days);
        uint256 net = _net(1000e18);
        assertApproxEqAbs(_claim(LP1, _nftKey(a, -300, -100), LP1), net * 2 / 10, 1e6);
        assertApproxEqAbs(_claim(LP2, _nftKey(b, -100, 100), LP2), net * 8 / 10, 1e6);
    }

    function test_tickInitializedBelowPrice_afterGrowth() public {
        // growth accrues to an existing position, then a NEW position whose ticks are below the price
        // is opened: it must not inherit the growth that happened before it existed
        uint256 a = _mintNft(LP1, -1000, 1000, 1e18);
        _start(1000e18, 10 days);
        vm.warp(T0 + 5 days);
        _swapToTick(500);
        uint256 b = _mintNft(LP2, -200, 600, 1e18);
        assertEq(_earned0(_nftKey(b, -200, 600)), 0);
        vm.warp(T0 + 10 days);
        uint256 net = _net(1000e18);
        assertApproxEqAbs(_claim(LP2, _nftKey(b, -200, 600), LP2), net / 4, 1e6);
        assertApproxEqAbs(_claim(LP1, _nftKey(a, -1000, 1000), LP1), net * 3 / 4, 1e6);
    }

    function test_noEligibleLiquidity_finishMovesOut_nothingLost() public {
        _start(1000e18, 10 days);
        vm.warp(T0 + 5 days);
        (, uint64 finish,,) = hook.streamOf(id, R);
        assertEq(finish, T0 + 15 days);
        uint256 a = _mintNft(LP1, -1000, 1000, 1e18);
        vm.warp(T0 + 15 days);
        assertApproxEqAbs(_claim(LP1, _nftKey(a, -1000, 1000), LP1), _net(1000e18), 2);
    }

    function test_topUp_rules() public {
        uint256 a = _mintNft(LP1, -1000, 1000, 1e18);
        rwd.mint(STRANGER, 1e24);
        vm.prank(STRANGER);
        rwd.approve(address(hook), type(uint256).max);

        vm.prank(STRANGER);
        vm.expectRevert(I.NoStream.selector);
        hook.topUp(key, R, 1e18);

        _start(1000e18, 10 days);
        vm.warp(T0 + 5 days);
        (uint256 rate0, uint64 f0,,) = hook.streamOf(id, R);
        vm.prank(STRANGER);
        hook.topUp(key, R, 500e18);
        (uint256 rate1, uint64 f1,,) = hook.streamOf(id, R);
        assertEq(f1, f0, "topUp must never move the finish");
        assertGt(rate1, rate0);
        vm.prank(STRANGER);
        vm.expectRevert(I.ZeroAmount.selector);
        hook.topUp(key, R, 0);

        vm.warp(T0 + 10 days - 1 hours + 1);
        vm.prank(STRANGER);
        vm.expectRevert(I.StreamEndsTooSoon.selector);
        hook.topUp(key, R, 1);

        vm.warp(T0 + 10 days);
        assertApproxEqAbs(_claim(LP1, _nftKey(a, -1000, 1000), LP1), _net(1500e18), 4);
    }

    function test_extendStream_rules() public {
        uint256 a = _mintNft(LP1, -1000, 1000, 1e18);
        vm.prank(CREATOR);
        vm.expectRevert(I.NoStream.selector);
        hook.extendStream(key, R, 1e18, uint64(T0 + 20 days));

        _start(1000e18, 10 days);
        vm.startPrank(CREATOR);
        vm.expectRevert(I.FinishWouldMoveIn.selector);
        hook.extendStream(key, R, 1e18, uint64(T0 + 9 days));
        vm.expectRevert(I.RateWouldFall.selector);
        hook.extendStream(key, R, 1e18, uint64(T0 + 20 days));
        vm.expectRevert(I.DurationOutOfRange.selector);
        hook.extendStream(key, R, 1e30, uint64(T0 + 366 days));
        hook.extendStream(key, R, 1000e18, uint64(T0 + 20 days));
        vm.stopPrank();
        vm.prank(STRANGER);
        vm.expectRevert(I.NotPoolOwner.selector);
        hook.extendStream(key, R, 1e18, uint64(T0 + 20 days));

        vm.warp(T0 + 20 days);
        assertApproxEqAbs(_claim(LP1, _nftKey(a, -1000, 1000), LP1), _net(2000e18), 4);
    }

    function test_nativeRewardStream() public {
        vm.prank(CREATOR);
        hook.allowRewardToken(key, Currency.wrap(address(0)));
        uint256 a = _mintNft(LP1, -1000, 1000, 1e18);
        vm.deal(CREATOR, 100 ether);
        vm.prank(CREATOR);
        vm.expectRevert(I.NativeAmountMismatch.selector);
        hook.startStream{value: 1 ether}(key, Currency.wrap(address(0)), 2 ether, 1 days, REFUND);
        vm.prank(CREATOR);
        hook.startStream{value: 10 ether}(key, Currency.wrap(address(0)), 10 ether, 1 days, REFUND);
        vm.warp(T0 + 1 days);
        vm.prank(LP1);
        uint256[] memory got = hook.claim(id, _nftKey(a, -1000, 1000), LP1);
        assertEq(got[0], 0); // the rwd stream never started
        assertApproxEqAbs(got[1], _net(10 ether), 2);
        assertEq(LP1.balance, got[1]);
    }

    /*//////////////////////////////////////////////////////////////
                              ELIGIBILITY
    //////////////////////////////////////////////////////////////*/

    function test_dustPositionBelowMinimumIsNotMirrored() public {
        uint256 dust = _mintNft(LP1, -1000, 1000, 999);
        uint256 a = _mintNft(LP2, -1000, 1000, 1e18);
        assertEq(hook.eligibleLiquidity(id), 1e18);
        _start(1000e18, 10 days);
        vm.warp(T0 + 10 days);
        assertEq(_earned0(_nftKey(dust, -1000, 1000)), 0);
        assertApproxEqAbs(_claim(LP2, _nftKey(a, -1000, 1000), LP2), _net(1000e18), 2);
        // growing past the minimum makes it eligible from then on
        _increaseNft(LP1, dust, 1, "");
        assertEq(hook.eligibleLiquidity(id), 1e18 + 1000);
    }

    /*//////////////////////////////////////////////////////////////
                              AUTHORISATION
    //////////////////////////////////////////////////////////////*/

    function test_claim_authorisation() public {
        uint256 a = _mintNft(LP1, -1000, 1000, 1e18);
        _start(1000e18, 10 days);
        vm.warp(T0 + 1 days);
        I.PositionKey memory k = _nftKey(a, -1000, 1000);

        vm.prank(STRANGER);
        vm.expectRevert(I.NotPositionOwner.selector);
        hook.claim(id, k, STRANGER);

        vm.prank(LP1);
        vm.expectRevert(I.ZeroAddress.selector);
        hook.claim(id, k, address(0));

        vm.prank(LP1);
        posm.approve(STRANGER, a);
        assertGt(_claim(STRANGER, k, STRANGER), 0);

        vm.warp(T0 + 2 days);
        address op = makeAddr("operator");
        vm.prank(LP1);
        posm.setApprovalForAll(op, true);
        assertGt(_claim(op, k, op), 0);

        // a position held by any other contract: only that contract
        _modifyDirect(-1000, 1000, 1e18, bytes32(uint256(7)), "");
        vm.warp(T0 + 3 days);
        I.PositionKey memory dk = _directKey(-1000, 1000, bytes32(uint256(7)));
        vm.expectRevert(I.NotPositionOwner.selector);
        hook.claim(id, dk, address(this));
        assertGt(_claim(address(router), dk, address(this)), 0);
    }

    function test_transferredNft_newOwnerClaims() public {
        uint256 a = _mintNft(LP1, -1000, 1000, 1e18);
        _start(1000e18, 10 days);
        vm.warp(T0 + 1 days);
        vm.prank(LP1);
        posm.transferFrom(LP1, LP2, a);
        vm.prank(LP1);
        vm.expectRevert(I.NotPositionOwner.selector);
        hook.claim(id, _nftKey(a, -1000, 1000), LP1);
        assertGt(_claim(LP2, _nftKey(a, -1000, 1000), LP2), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            HOOKDATA AND BURN
    //////////////////////////////////////////////////////////////*/

    function test_burnWithHookData_creditsRecipient() public {
        uint256 a = _mintNft(LP1, -1000, 1000, 1e18);
        _start(1000e18, 10 days);
        vm.warp(T0 + 10 days);
        uint256 e = _earned0(_nftKey(a, -1000, 1000));
        _burnNft(LP1, a, abi.encode(LP2));
        assertEq(hook.credit(LP2, R), e);
        assertApproxEqAbs(e, _net(1000e18), 2);
        vm.prank(LP2);
        assertEq(hook.claimCredit(R, LP2), e);
        assertEq(rwd.balanceOf(LP2), e);
        vm.prank(LP2);
        vm.expectRevert(I.NothingToClaim.selector);
        hook.claimCredit(R, LP2);
    }

    function test_decreaseZeroWithHookData_credits_withoutRemoving() public {
        uint256 a = _mintNft(LP1, -1000, 1000, 1e18);
        _start(1000e18, 10 days);
        vm.warp(T0 + 5 days);
        _decreaseNft(LP1, a, 0, abi.encode(LP1));
        assertApproxEqAbs(hook.credit(LP1, R), _net(1000e18) / 2, 1e6);
        assertEq(hook.eligibleLiquidity(id), 1e18);
    }

    function test_hookDataIgnored_onAdd_onNonPosmSender_andMalformed() public {
        uint256 a = _mintNft(LP1, -1000, 1000, 1e18);
        _modifyDirect(-1000, 1000, 1e18, bytes32(uint256(1)), "");
        _start(1000e18, 10 days);
        vm.warp(T0 + 5 days);
        // add through the position manager naming a stranger: ignored
        _increaseNft(LP1, a, 1, abi.encode(STRANGER));
        assertEq(hook.credit(STRANGER, R), 0);
        // removal through any other contract naming a stranger: ignored
        _modifyDirect(-1000, 1000, -1, bytes32(uint256(1)), abi.encode(STRANGER));
        assertEq(hook.credit(STRANGER, R), 0);
        // dirty upper bits, wrong length: ignored, and the removal still succeeds
        _decreaseNft(LP1, a, 1, abi.encodePacked(bytes32(uint256(uint160(STRANGER)) | (uint256(1) << 200))));
        _decreaseNft(LP1, a, 1, abi.encodePacked(STRANGER));
        _decreaseNft(LP1, a, 1, abi.encode(address(0)));
        assertEq(hook.credit(STRANGER, R), 0);
        assertGt(_earned0(_nftKey(a, -1000, 1000)), 0);
    }

    function test_burnWithoutHookData_strandsThenRecycles() public {
        uint256 a = _mintNft(LP1, -1000, 1000, 1e18);
        uint256 b = _mintNft(LP2, -1000, 1000, 1e18);
        _start(1000e18, 10 days);
        vm.warp(T0 + 2 days);
        _burnNft(LP1, a, "");
        I.PositionKey memory k = _nftKey(a, -1000, 1000);
        uint256 stranded = _earned0(k);
        assertApproxEqAbs(stranded, _net(1000e18) / 10, 1e6);
        vm.prank(LP1);
        vm.expectRevert(I.NotPositionOwner.selector);
        hook.claim(id, k, LP1);

        vm.expectRevert(abi.encodeWithSelector(I.RecycleTooSoon.selector, uint64(T0 + 2 days + RECYCLE)));
        hook.recycle(id, k);
        vm.expectRevert(I.PositionStillActive.selector);
        hook.recycle(id, _nftKey(b, -1000, 1000));

        vm.warp(T0 + 2 days + RECYCLE);
        hook.recycle(id, k);
        assertEq(_earned0(k), 0);
        vm.expectRevert(I.NothingToRecycle.selector);
        hook.recycle(id, k);
        // the stream ended long ago: the recycled amount waits as undistributed, reclaimable or re-streamed
        (,, uint256 und,) = hook.streamOf(id, R);
        assertGe(und, stranded);
    }

    function test_recycle_intoARunningStream_raisesRate() public {
        uint256 a = _mintNft(LP1, -1000, 1000, 1e18);
        uint256 b = _mintNft(LP2, -1000, 1000, 1e18);
        _start(1000e18, 200 days);
        vm.warp(T0 + 10 days);
        _burnNft(LP1, a, "");
        vm.warp(T0 + 10 days + RECYCLE);
        (uint256 r0, uint64 f0,,) = hook.streamOf(id, R);
        hook.recycle(id, _nftKey(a, -1000, 1000));
        (uint256 r1, uint64 f1,,) = hook.streamOf(id, R);
        assertEq(f1, f0);
        assertGt(r1, r0);
        vm.warp(T0 + 200 days);
        // LP2 gets everything except what LP1 earned in its 10 days, which came back: so everything
        assertApproxEqAbs(_claim(LP2, _nftKey(b, -1000, 1000), LP2), _net(1000e18) * 195 / 200 + _net(1000e18) / 40, 1e9);
    }

    /*//////////////////////////////////////////////////////////////
                                RECLAIM
    //////////////////////////////////////////////////////////////*/

    function test_reclaim_deadPool() public {
        _start(1000e18, 10 days);
        vm.expectRevert(abi.encodeWithSelector(I.ReclaimTooSoon.selector, uint64(T0 + RECLAIM)));
        hook.reclaim(id, R);
        vm.warp(T0 + RECLAIM);
        uint256 amt = hook.reclaim(id, R);
        assertEq(amt, _net(1000e18));
        assertEq(hook.credit(REFUND, R), amt);
        (uint256 rate, uint64 finish, uint256 und,) = hook.streamOf(id, R);
        assertEq(rate, 0);
        assertEq(und, 0);
        assertEq(finish, block.timestamp);
        vm.expectRevert(I.NothingToReclaim.selector);
        hook.reclaim(id, R);
        vm.prank(REFUND);
        hook.claimCredit(R, REFUND);
        assertEq(rwd.balanceOf(REFUND), amt);
    }

    function test_reclaim_refusedWhileLiquidityEarns_andAfterABreak() public {
        _start(1000e18, 100 days);
        vm.warp(T0 + 20 days);
        uint256 a = _mintNft(LP1, -1000, 1000, 1e18);
        vm.warp(T0 + 25 days);
        _burnNft(LP1, a, abi.encode(LP1)); // zero again from day 25
        vm.warp(T0 + 40 days);
        vm.expectRevert(abi.encodeWithSelector(I.ReclaimTooSoon.selector, uint64(T0 + 25 days + RECLAIM)));
        hook.reclaim(id, R);
        vm.warp(T0 + 25 days + RECLAIM);
        uint256 amt = hook.reclaim(id, R);
        // 5 of 100 days were paid to LP1; the rest is returned
        assertApproxEqAbs(amt, _net(1000e18) * 95 / 100, 1e9);
        assertApproxEqAbs(hook.credit(LP1, R), _net(1000e18) * 5 / 100, 1e9);
    }

    function test_reclaim_finishedStream_dustAndRecycled() public {
        uint256 a = _mintNft(LP1, -1000, 1000, 3e18 + 7);
        _start(1000e18 + 13, 10 days);
        vm.warp(T0 + 10 days);
        _burnNft(LP1, a, abi.encode(LP1));
        // still refused while a position is live? no position is mirrored now; but the pool has had zero
        // liquidity for 0 seconds and the stream finished 0 seconds ago
        vm.expectRevert();
        hook.reclaim(id, R);
        vm.warp(T0 + 10 days + RECLAIM);
        try hook.reclaim(id, R) returns (uint256 dust) {
            assertLe(dust, 4);
        } catch (bytes memory err) {
            assertEq(bytes4(err), I.NothingToReclaim.selector);
        }
        // after that, every unit funded is either paid, credited or the protocol's
        address[] memory cs = new address[](2);
        cs[0] = LP1;
        cs[1] = REFUND;
        assertEq(_ledger(R, cs), hook.totalOwed(R));
        assertEq(hook.credit(LP1, R) + hook.credit(REFUND, R) + hook.protocolOwed(R), 1000e18 + 13);
    }

    /*//////////////////////////////////////////////////////////////
                                 SWEEP
    //////////////////////////////////////////////////////////////*/

    function test_sweep_onlyAboveTheLedger() public {
        _start(1000e18, 10 days);
        vm.expectRevert(I.NothingToSweep.selector);
        hook.sweep(R);
        rwd.mint(address(hook), 5e18);
        vm.prank(STRANGER);
        assertEq(hook.sweep(R), 5e18);
        assertEq(rwd.balanceOf(SAFE), 5e18);
        assertEq(rwd.balanceOf(address(hook)), 1000e18);

        // forced native (no receive function exists: a plain send reverts)
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok);
        vm.deal(address(hook), 3 ether);
        assertEq(hook.sweep(Currency.wrap(address(0))), 3 ether);
        assertEq(SAFE.balance, 3 ether);
    }

    /*//////////////////////////////////////////////////////////////
                              PROTOCOL FEE
    //////////////////////////////////////////////////////////////*/

    function test_protocolFee_housePattern() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        hook.setProtocolFee(50);

        vm.prank(SAFE);
        vm.expectRevert(abi.encodeWithSelector(I.FeeAboveCap.selector, 301, 300));
        hook.setProtocolFee(301);

        vm.prank(SAFE);
        hook.setProtocolFee(200);
        assertEq(hook.protocolFeeBps(), 100, "an increase waits for the notice");
        (uint16 pend, uint64 at) = hook.pendingProtocolFee();
        assertEq(pend, 200);
        assertEq(at, T0 + NOTICE);
        vm.warp(T0 + NOTICE);
        assertEq(hook.protocolFeeBps(), 200, "and applies by itself");

        vm.prank(SAFE);
        hook.setProtocolFee(0);
        assertEq(hook.protocolFeeBps(), 0, "a decrease is immediate");

        vm.prank(SAFE);
        hook.setProtocolFee(300);
        vm.prank(SAFE);
        hook.cancelPendingProtocolFee();
        vm.warp(block.timestamp + NOTICE);
        assertEq(hook.protocolFeeBps(), 0);
        vm.prank(SAFE);
        vm.expectRevert(I.NoPendingFee.selector);
        hook.cancelPendingProtocolFee();

        // funding at a zero fee books nothing for the protocol
        vm.prank(CREATOR);
        hook.startStream(key, R, 100e18, 1 days, REFUND);
        assertEq(hook.protocolOwed(R), 0);
        (,, uint256 und,) = hook.streamOf(id, R);
        assertEq(und, 100e18);
    }

    function test_ownerCannotTouchStreamsOrPositions() public {
        uint256 a = _mintNft(LP1, -1000, 1000, 1e18);
        _start(1000e18, 10 days);
        vm.warp(T0 + 10 days);
        vm.startPrank(SAFE);
        vm.expectRevert(I.NotPositionOwner.selector);
        hook.claim(id, _nftKey(a, -1000, 1000), SAFE);
        vm.expectRevert(I.NotPoolOwner.selector);
        hook.startStream(key, R, 1, 1 days, SAFE);
        vm.expectRevert(abi.encodeWithSelector(I.ReclaimTooSoon.selector, uint64(T0 + 10 days + RECLAIM)));
        hook.reclaim(id, R);
        vm.stopPrank();
    }
}

/// @dev Helpers for the configure-refusal test.
contract MockLike {}

/// @dev A pool whose owner set a minimum width: narrower positions are never mirrored.
contract LiquidityRewardsMinWidthTest is RewardsFixture {
    function _minWidth() internal pure override returns (uint24) {
        return 100;
    }

    function test_narrowPositionEarnsNothing_andDoesNotDilute() public {
        uint256 narrow = _mintNft(LP1, -40, 50, 100e18); // 90 ticks wide: under the minimum
        uint256 exact = _mintNft(LP2, -50, 50, 1e18); // exactly the minimum
        assertEq(hook.eligibleLiquidity(id), 1e18);
        _start(1000e18, 10 days);
        vm.warp(T0 + 10 days);
        assertEq(_earned0(_nftKey(narrow, -40, 50)), 0);
        (uint128 liq,,) = hook.positionOf(id, _nftKey(narrow, -40, 50));
        assertEq(liq, 0, "a narrow position is not even stored");
        assertApproxEqAbs(_claim(LP2, _nftKey(exact, -50, 50), LP2), _net(1000e18), 2);
        // and it leaves freely
        _burnNft(LP1, narrow, abi.encode(LP1));
        assertEq(hook.credit(LP1, Currency.wrap(address(rwd))), 0);
    }
}
