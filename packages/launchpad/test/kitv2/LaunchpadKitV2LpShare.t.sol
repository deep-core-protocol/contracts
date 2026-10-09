// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

import {BinShape, LaunchResultV2} from "../../src/interfaces/ILaunchpadKitV2.sol";

import {KitV2Fixture} from "./KitV2Fixture.sol";

/// @notice A launch through the kit on guards that leave liquidity providers a share of each buy's
/// trade fee (`LP_SHARE_BPS`). Every other kit suite runs the guards at a share of zero; this one runs
/// them at 2,000 and at the cap, and checks where each part of the fee lands.
abstract contract LaunchpadKitV2LpShareBase is KitV2Fixture {
    function setUp() public {
        _deployAll();
    }

    function _sellCL(PoolKey memory key, address token, uint256 amountIn) internal {
        bool launchIs0 = Currency.unwrap(key.currency0) == token;
        IERC20(token).approve(address(clRouter), type(uint256).max);
        clRouter.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: launchIs0,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: launchIs0 ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
    }

    /// @dev What the locker collected, as (quote, launch token), whichever way the pair sorts.
    function _collect(uint256 lockId, PoolKey memory key, address token) internal returns (uint256 inQuote, uint256 inToken) {
        (uint256 a0, uint256 a1) = clLocker.collectFees(lockId);
        (inQuote, inToken) = Currency.unwrap(key.currency0) == token ? (a1, a0) : (a0, a1);
    }

    function test_SHARE_bothGuardsCarryTheSameShare() public view {
        assertEq(clHook.LP_SHARE_BPS(), _lpShareBps());
        assertEq(binHook.LP_SHARE_BPS(), _lpShareBps());
        assertEq(clHook.MAX_LP_SHARE_BPS(), 5_000);
    }

    function test_SHARE_thePartsSumToTheFee() public {
        LaunchResultV2 memory r = _launch(_oneCL(keccak256("share-parts"), address(quote)));
        PoolId id = PoolId.wrap(r.poolIds[0]);
        vm.warp(block.timestamp + 120);
        uint24 fee = clHook.currentFee(id);
        (uint24 buyLp, uint24 buyGuard, uint24 sellGuard) = clHook.currentFeeParts(id);
        assertGt(fee, 0, "the schedule charges a fee");
        assertEq(buyLp, uint256(fee) * _lpShareBps() / 10_000, "the pool's part of a buy");
        assertEq(uint256(buyLp) + buyGuard, fee, "a buyer never pays more than the fee");
        assertEq(sellGuard, fee, "a sell pays the guard all of it");
    }

    function test_SHARE_aBuyPaysThePoolItsPartAndTheGuardTheRest() public {
        LaunchResultV2 memory r = _launch(_oneCL(keccak256("share-buy"), address(quote)));
        PoolKey memory key = _clKey(r.token, _clLeg(r.token, address(quote), 10_000));
        PoolId id = PoolId.wrap(r.poolIds[0]);
        Currency q = Currency.wrap(address(quote));
        vm.warp(block.timestamp + 120);
        (uint24 buyLp, uint24 buyGuard,) = clHook.currentFeeParts(id);

        uint256 accruedBefore = clPM.protocolFeesAccrued(q);
        _buyCL(key, r.token, 100 ether);
        assertEq(clPM.protocolFeesAccrued(q), accruedBefore, "no core protocol fee");

        // The guard's part, on the quote the buyer sent.
        uint256 guardTook = uint256(100 ether) * buyGuard / 1e6;
        assertEq(clHook.pendingFee(id, q), guardTook, "the guard's part");
        assertEq(clHook.pendingFee(id, Currency.wrap(r.token)), 0, "never in the launch token");

        // The pool's part, on what was left, to the only liquidity there is: the locked position.
        (uint256 inQuote, uint256 inToken) = _collect(r.lockIds[0], key, r.token);
        uint256 poolTook = (uint256(100 ether) - guardTook) * buyLp / 1e6;
        assertEq(inToken, 0, "the pool's part is never in the launch token");
        assertApproxEqAbs(inQuote, poolTook, 10, "the pool's part, in the quote");
        assertLe(guardTook + inQuote, uint256(100 ether) * clHook.currentFee(id) / 1e6, "together at most the fee");

        // And the lock pays it by its own split.
        uint256 c = clLocker.claimable(CREATOR, q);
        uint256 i = clLocker.claimable(INTEGRATOR, q);
        uint256 pr = clLocker.claimable(safe, q);
        assertEq(c + i + pr, inQuote, "the lock's split sums exactly");
        assertGe(pr, inQuote * 2_000 / 10_000, "protocol never below its floor");
    }

    function test_SHARE_aSellPaysThePoolNothing() public {
        LaunchResultV2 memory r = _launch(_oneCL(keccak256("share-sell"), address(quote)));
        PoolKey memory key = _clKey(r.token, _clLeg(r.token, address(quote), 10_000));
        PoolId id = PoolId.wrap(r.poolIds[0]);
        Currency q = Currency.wrap(address(quote));
        vm.warp(block.timestamp + 120);

        _buyCL(key, r.token, 100 ether);
        _collect(r.lockIds[0], key, r.token);
        uint256 potAfterBuy = clHook.pendingFee(id, q);
        uint24 fee = clHook.currentFee(id);

        uint256 quoteBefore = quote.balanceOf(address(this));
        _sellCL(key, r.token, IERC20(r.token).balanceOf(address(this)) / 2);
        uint256 received = quote.balanceOf(address(this)) - quoteBefore;
        uint256 taken = clHook.pendingFee(id, q) - potAfterBuy;
        assertEq(taken, (received + taken) * fee / 1e6, "the whole fee, on the quote the pool paid out");
        assertEq(clHook.pendingFee(id, Currency.wrap(r.token)), 0, "never in the launch token");

        (uint256 inQuote, uint256 inToken) = _collect(r.lockIds[0], key, r.token);
        assertEq(inQuote, 0, "a sell left the pool no fee in the quote");
        assertEq(inToken, 0, "and none in the launch token");
    }

    function test_SHARE_binBuyPaysTheGuardItsPart() public {
        LaunchResultV2 memory r = _launch(_clAndBin(keccak256("share-bin"), address(quote)));
        (PoolKey memory key,,) = kit.computeLegKey(r.token, _binLeg(address(quote), 4_000, BinShape.Linear, 10));
        PoolId id = PoolId.wrap(r.poolIds[1]);
        Currency q = Currency.wrap(address(quote));
        vm.warp(block.timestamp + 120);
        (uint24 buyLp, uint24 buyGuard, uint24 sellGuard) = binHook.currentFeeParts(id);
        assertEq(uint256(buyLp) + buyGuard, sellGuard, "the parts sum to the fee");

        _buyBin(key, r.token, 1 ether);
        assertEq(binHook.pendingFee(id, q), uint256(1 ether) * buyGuard / 1e6, "the guard's part");
        assertEq(binHook.pendingFee(id, Currency.wrap(r.token)), 0, "never in the launch token");
        assertEq(_binProtocolFee(r.poolIds[1]), 0, "born at zero");
    }

    function test_SHARE_bothLegsBornAtZero() public {
        LaunchResultV2 memory r = _launch(_clAndBin(keccak256("share-zero"), address(quote)));
        assertEq(_clProtocolFee(r.poolIds[0]), 0);
        assertEq(_binProtocolFee(r.poolIds[1]), 0);
        assertTrue(kit.isLockedLaunch(r.poolIds[0]));
        assertTrue(kit.isLockedLaunch(r.poolIds[1]));
    }
}

contract LaunchpadKitV2LpShare2000Test is LaunchpadKitV2LpShareBase {
    function _lpShareBps() internal pure override returns (uint16) {
        return 2_000;
    }
}

contract LaunchpadKitV2LpShareCapTest is LaunchpadKitV2LpShareBase {
    function _lpShareBps() internal pure override returns (uint16) {
        return 5_000;
    }
}
