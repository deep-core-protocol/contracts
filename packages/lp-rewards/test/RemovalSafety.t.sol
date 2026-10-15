// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Currency} from "infinity-core/src/types/Currency.sol";
import {CLPosition} from "infinity-core/src/pool-cl/libraries/CLPosition.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IDeepCoreLiquidityRewards as I} from "../src/interfaces/IDeepCoreLiquidityRewards.sol";
import {RewardsFixture} from "./utils/RewardsFixture.sol";
import {PausableToken, FalseReturningToken, FeeOnTransferToken, ReentrantToken} from "./utils/Tokens.sol";

/// @notice THE REMOVAL RULE: no reward token, no accumulator value and no state of the mirror can make a
/// liquidity removal revert. Every removal here goes through REAL core (and the real position manager).
contract RemovalSafetyTest is RewardsFixture {
    Currency internal R;
    PausableToken internal pt;

    function setUp() public override {
        super.setUp();
        R = Currency.wrap(address(rwd));
        pt = new PausableToken();
        pt.mint(CREATOR, 1e30);
        vm.startPrank(CREATOR);
        pt.approve(address(hook), type(uint256).max);
        hook.allowRewardToken(key, Currency.wrap(address(pt)));
        vm.stopPrank();
    }

    function _startBoth() internal {
        vm.startPrank(CREATOR);
        hook.startStream(key, R, 1000e18, 10 days, REFUND);
        hook.startStream(key, Currency.wrap(address(pt)), 1000e18, 10 days, REFUND);
        vm.stopPrank();
    }

    function test_pausedRewardToken_removalAndBurnSucceed_claimCreditsThePausedToken() public {
        uint256 a = _mintNft(LP1, -1000, 1000, 1e18);
        uint256 b = _mintNft(LP2, -1000, 1000, 1e18);
        _startBoth();
        vm.warp(T0 + 5 days);
        pt.setPaused(true);

        // liquidity operations never touch the reward token
        _decreaseNft(LP1, a, 5e17, "");
        _burnNft(LP2, b, abi.encode(LP2));
        _swap(true, -1e15);

        // a claim pays the healthy token and credits the paused one instead of reverting
        vm.prank(LP1);
        uint256[] memory got = hook.claim(id, _nftKey(a, -1000, 1000), LP1);
        assertGt(got[0], 0);
        assertGt(got[1], 0);
        assertEq(rwd.balanceOf(LP1), got[0]);
        assertEq(pt.balanceOf(LP1), 0);
        assertEq(hook.credit(LP1, Currency.wrap(address(pt))), got[1]);

        // the credit is pulled once the issuer unpauses
        vm.prank(LP1);
        vm.expectRevert();
        hook.claimCredit(Currency.wrap(address(pt)), LP1);
        pt.setPaused(false);
        vm.prank(LP1);
        hook.claimCredit(Currency.wrap(address(pt)), LP1);
        assertEq(pt.balanceOf(LP1), got[1]);
    }

    function test_blockedRecipient_claimCredits_andAnotherRecipientWorks() public {
        uint256 d = _mintNft(LP1, -500, 500, 1e18);
        _startBoth();
        vm.warp(T0 + 10 days);
        pt.setBlocked(LP1, true);
        // removal is unaffected by the block
        _decreaseNft(LP1, d, 1e17, "");
        vm.prank(LP1);
        uint256[] memory got = hook.claim(id, _nftKey(d, -500, 500), LP1);
        assertGt(got[0], 0);
        assertGt(got[1], 0);
        assertEq(hook.credit(LP1, Currency.wrap(address(pt))), got[1]);
        address cold = makeAddr("cold");
        vm.prank(LP1);
        hook.claimCredit(Currency.wrap(address(pt)), cold);
        assertEq(pt.balanceOf(cold), got[1]);
    }

    function test_falseReturningToken_isCredited() public {
        FalseReturningToken ft = new FalseReturningToken();
        ft.mint(CREATOR, 1e24);
        vm.startPrank(CREATOR);
        ft.approve(address(hook), type(uint256).max);
        hook.allowRewardToken(key, Currency.wrap(address(ft)));
        hook.startStream(key, Currency.wrap(address(ft)), 100e18, 1 days, REFUND);
        vm.stopPrank();
        uint256 a = _mintNft(LP1, -1000, 1000, 1e18);
        vm.warp(T0 + 1 days);
        ft.setOff(true);
        _decreaseNft(LP1, a, 1e17, "");
        vm.prank(LP1);
        uint256[] memory got = hook.claim(id, _nftKey(a, -1000, 1000), LP1);
        assertGt(got[2], 0);
        assertEq(hook.credit(LP1, Currency.wrap(address(ft))), got[2]);
        assertEq(ft.balanceOf(LP1), 0);
    }

    function test_reentrantRewardToken_cannotReenter() public {
        ReentrantToken rt = new ReentrantToken();
        rt.mint(CREATOR, 1e24);
        vm.startPrank(CREATOR);
        rt.approve(address(hook), type(uint256).max);
        hook.allowRewardToken(key, Currency.wrap(address(rt)));
        hook.startStream(key, Currency.wrap(address(rt)), 100e18, 1 days, REFUND);
        vm.stopPrank();
        uint256 a = _mintNft(LP1, -1000, 1000, 1e18);
        vm.warp(T0 + 1 days);
        // during the claim's transfer the token calls back into the hook
        rt.arm(address(hook), abi.encodeCall(hook.claim, (id, _nftKey(a, -1000, 1000), address(rt))));
        vm.prank(LP1);
        uint256[] memory got = hook.claim(id, _nftKey(a, -1000, 1000), LP1);
        assertFalse(rt.lastReentrySucceeded());
        assertEq(bytes4(rt.lastReentryError()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(rt.balanceOf(LP1), got[2]);
    }

    function test_feeOnTransferReward_booksWhatArrived() public {
        FeeOnTransferToken ft = new FeeOnTransferToken();
        ft.mint(CREATOR, 1e24);
        vm.startPrank(CREATOR);
        ft.approve(address(hook), type(uint256).max);
        hook.allowRewardToken(key, Currency.wrap(address(ft)));
        hook.startStream(key, Currency.wrap(address(ft)), 1000e18, 1 days, REFUND);
        vm.stopPrank();
        (,, uint256 und,) = hook.streamOf(id, Currency.wrap(address(ft)));
        assertEq(und, _net(990e18));
        assertEq(hook.totalOwed(Currency.wrap(address(ft))), 990e18);
        assertEq(ft.balanceOf(address(hook)), 990e18);
    }

    function test_accumulatorNearOverflow_wrapsAndRemovalSucceeds() public {
        uint256 a = _mintNft(LP1, -1000, 1000, 1e18);
        _modifyDirect(-200, 200, 1e18, bytes32(0), "");
        _startBoth();
        hook.corruptGrowth(id, 0, type(uint256).max - 5);
        hook.corruptGrowth(id, 1, type(uint256).max);
        vm.warp(T0 + 3 days);
        _swapToTick(300);
        _swapToTick(-300);
        vm.warp(T0 + 4 days);
        _decreaseNft(LP1, a, 1e18, "");
        _modifyDirect(-200, 200, -1e18, bytes32(0), "");
        _burnNft(LP1, a, abi.encode(LP1));
        // the wrapped differences still paid something sane: never more than the pool's accrued ledger
        address[] memory cs = new address[](3);
        cs[0] = LP1;
        cs[1] = REFUND;
        cs[2] = address(router);
        assertEq(_ledger(R, cs), hook.totalOwed(R));
        assertLe(hook.totalOwed(R), rwd.balanceOf(address(hook)));
    }

    function test_removal_ofUntrackedAndZeroPositions_succeeds() public {
        // a position below the minimum liquidity (never mirrored), and zero-delta pokes
        uint256 dust = _mintNft(LP2, -1000, 1000, 10);
        _decreaseNft(LP2, dust, 0, "");
        _decreaseNft(LP2, dust, 10, abi.encode(LP2));
        uint256 a = _mintNft(LP1, -1000, 1000, 1e18);
        _decreaseNft(LP1, a, 0, abi.encode(LP1));
        _decreaseNft(LP1, a, 1e18, "");
        _burnNft(LP1, a, abi.encode(LP1)); // no liquidity left: the position manager makes no pool call
        _burnNft(LP2, dust, "");
        assertEq(hook.eligibleLiquidity(id), 0);
        assertEq(manager.getLiquidity(id), 0);
    }

    /// @notice A deliberately corrupted mirror: every number the removal path reads is set to a fuzzed value,
    /// then every position is removed through real core and the real position manager. None may revert.
    function testFuzz_corruptedMirror_removalNeverReverts(
        uint128 eligible,
        uint128 mirroredTotal,
        int24 lastTick,
        uint128 gross,
        int128 net,
        uint256 outside,
        uint128 posLiq,
        uint256 insideLast,
        uint256 earned,
        uint256 growth,
        uint128 und,
        uint128 accrued,
        uint256 rate,
        uint256 word
    ) public {
        lastTick = int24(bound(lastTick, -887_272, 887_272));
        uint256 a = _mintNft(LP1, -1000, 1000, 1e18);
        uint256 b = _mintNft(LP2, -100, 100, 5e17);
        _modifyDirect(-500, 500, 3e18, bytes32(uint256(5)), "");
        _startBoth();
        vm.warp(T0 + 1 days);

        hook.corruptEligible(id, eligible);
        hook.corruptMirroredTotal(id, mirroredTotal);
        hook.corruptLastTick(id, lastTick);
        hook.corruptTick(id, -1000, gross, net, outside);
        hook.corruptTick(id, 100, gross / 2, int128(-(int256(net) / 2)), ~outside);
        hook.corruptPosition(id, _pid(address(posm), -1000, 1000, bytes32(a)), posLiq, insideLast, earned);
        hook.corruptGrowth(id, 0, growth);
        hook.corruptStream(id, 0, und, accrued, rate);
        hook.corruptBitmapWord(id, int16(int256(word % 200)) - 100, word);

        vm.warp(T0 + 2 days);
        _swap(true, -1e14);
        vm.warp(T0 + 3 days);
        _swap(false, -2e14);

        _decreaseNft(LP1, a, 4e17, "");
        _burnNft(LP1, a, abi.encode(LP1));
        _burnNft(LP2, b, "");
        _modifyDirect(-500, 500, -3e18, bytes32(uint256(5)), abi.encode(LP1));
        // the pool is empty in core whatever the mirror believes
        assertEq(manager.getLiquidity(id), 0);
    }

    /// @notice The mirror's counters ZEROED under live positions (the shape a wrong subtraction would leave):
    /// every later removal subtracts from zero, and must saturate rather than revert.
    function test_zeroedMirror_removalsSaturate() public {
        uint256 a = _mintNft(LP1, -1000, 1000, 1e18);
        _modifyDirect(-500, 500, 3e18, bytes32(uint256(5)), "");
        _startBoth();
        vm.warp(T0 + 1 days);
        hook.corruptEligible(id, 0);
        hook.corruptMirroredTotal(id, 0);
        hook.corruptTick(id, -1000, 0, 0, 0);
        hook.corruptTick(id, 1000, 1, 0, 0);
        hook.corruptTick(id, -500, 0, 0, 0);
        hook.corruptTick(id, 500, 0, 0, 0);
        hook.corruptPosition(id, _pid(address(posm), -1000, 1000, bytes32(a)), 1, 0, 0);
        _swap(true, -1e14);
        _decreaseNft(LP1, a, 4e17, "");
        _burnNft(LP1, a, abi.encode(LP1));
        _modifyDirect(-500, 500, -3e18, bytes32(uint256(5)), "");
        assertEq(manager.getLiquidity(id), 0);
        assertEq(hook.eligibleLiquidity(id), 0);
    }

    /// @notice A position whose settled rewards are WRONG (here: absurdly large) can take at most its own
    /// pool's accrued ledger, never the stream's undistributed funds, the protocol's fees or another pool's.
    function test_corruptedEarned_claimCappedByThePoolsAccruedLedger() public {
        uint256 a = _mintNft(LP1, -1000, 1000, 1e18);
        _startBoth();
        vm.warp(T0 + 1 days);
        hook.corruptPosition(id, _pid(address(posm), -1000, 1000, bytes32(a)), 1e18, 0, 1e40);
        // accrue, then read the ledger the claim may draw from
        _swap(true, -1e10);
        (uint128 undBefore, uint128 accrued,,,,) = hook.streamRaw(id, 0);
        vm.prank(LP1);
        uint256[] memory got = hook.claim(id, _nftKey(a, -1000, 1000), LP1);
        assertLe(got[0], accrued, "paid above the pool's accrued ledger");
        (uint128 undAfter, uint128 accruedAfter,,,,) = hook.streamRaw(id, 0);
        assertEq(undAfter, undBefore, "the undistributed stream was touched");
        assertEq(accruedAfter, 0);
        assertEq(hook.credit(LP1, R), 0);
        address[] memory cs = new address[](1);
        cs[0] = LP1;
        assertEq(_ledger(R, cs), hook.totalOwed(R));
        assertLe(hook.totalOwed(R), rwd.balanceOf(address(hook)));
    }

    function _pid(address s, int24 lo, int24 hi, bytes32 salt) internal pure returns (bytes32) {
        return CLPosition.calculatePositionKey(s, lo, hi, salt);
    }
}
