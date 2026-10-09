// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {LaunchGuardHook} from "deepcore-hooks/src/launch/LaunchGuardHook.sol";
import {BinLaunchGuardHook} from "deepcore-hooks/src/launch/BinLaunchGuardHook.sol";

import {KitV2Fixture} from "./KitV2Fixture.sol";
import {LaunchParamsV2, LaunchResultV2, ScheduleParams} from "../../src/interfaces/ILaunchpadKitV2.sol";
import {Preset} from "../../src/libraries/LaunchPresets.sol";

/// @notice Security review 2026-09-18 (M-1). A launch whose guard schedule is `enabled == false` (the
/// `NoTax` preset, or `Custom` with `enabled = false`) trades from birth, yet the guards used to keep its
/// configuration writable until `startTime`, which the kit lets the launcher put up to 30 days out. The
/// operator could let the public buy into the open pool and then, through `reconfigureLaunch`, close
/// trading for 30 days at a time (repeatable) or impose the 50% -> 10% schedule on every holder's exit.
///
/// The fix lives in both guards: the first swap freezes the configuration whatever `startTime` says.
/// These tests drive the whole path through the kit. On the pre-fix guards
/// `test_FIX_operatorCannotCloseALiveDisabledLaunchOnItsHolders` fails at the `expectRevert` (the
/// reconfigure went through and the holder's sell then reverted `TradingNotOpen`).
contract LaunchpadKitV2DisabledFreezeTest is KitV2Fixture {
    function setUp() public {
        _deployAll();
    }

    function _noTaxSchedule(uint32 startDelay) internal pure returns (ScheduleParams memory) {
        return ScheduleParams({
            preset: Preset.NoTax,
            initialFeeBips: 0,
            finalFeeBips: 0,
            decaySeconds: 0,
            enabled: false,
            startDelaySeconds: startDelay
        });
    }

    function _rugSchedule() internal pure returns (ScheduleParams memory) {
        return ScheduleParams({
            preset: Preset.Custom,
            initialFeeBips: 500_000,
            finalFeeBips: 100_000,
            decaySeconds: 30 days,
            enabled: true,
            startDelaySeconds: 30 days
        });
    }

    function _noTaxCL(uint32 startDelay) internal returns (LaunchResultV2 memory r, PoolKey memory key) {
        LaunchParamsV2 memory p = _oneCL(keccak256("review-notax-cl"), address(quote));
        p.schedule = _noTaxSchedule(startDelay);
        r = _launch(p);
        key = _clKey(r.token, p.legs[0]);
    }

    function _sell(PoolKey memory key, address token, uint256 amountIn) internal {
        bool launchIs0 = Currency.unwrap(key.currency0) == token;
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

    /// @dev Unchanged behaviour, stated: a NoTax launch is tradable immediately even with `startTime` ahead.
    function test_disabledLaunchTradesBeforeStartTime() public {
        (LaunchResultV2 memory r, PoolKey memory key) = _noTaxCL(30 days);
        assertGt(r.startTime, block.timestamp, "start is in the future");
        _buyCL(key, r.token, 1 ether);
        assertGt(MockERC20(r.token).balanceOf(address(this)), 0, "buyer holds launch tokens");
    }

    /// @dev Before anybody trades, the operator keeps the pre-open freedom the kit documents.
    function test_FIX_disabledLaunchStaysReconfigurableUntilSomebodyTrades() public {
        (LaunchResultV2 memory r, PoolKey memory key) = _noTaxCL(30 days);
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = key;
        vm.prank(OPERATOR);
        kit.reconfigureLaunch(r.token, keys, _rugSchedule(), _noTax());
        assertTrue(clHook.getLaunch(key.toId()).enabled, "flip went through with no trade yet");
    }

    /// @dev THE ATTACK, refused: once the public has bought, the operator cannot close or re-price the pool.
    function test_FIX_operatorCannotCloseALiveDisabledLaunchOnItsHolders() public {
        (LaunchResultV2 memory r, PoolKey memory key) = _noTaxCL(30 days);
        address token = r.token;
        _buyCL(key, token, 1 ether);
        uint256 held = MockERC20(token).balanceOf(address(this));
        MockERC20(token).approve(address(clRouter), type(uint256).max);

        vm.warp(block.timestamp + 29 days);
        PoolKey[] memory keys = new PoolKey[](1);
        keys[0] = key;
        vm.prank(OPERATOR);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchGuardHook.LaunchAlreadyStarted.selector, key.toId(), uint256(r.startTime))
        );
        kit.reconfigureLaunch(token, keys, _rugSchedule(), _noTax());

        // The holder's exit is exactly what they bought under: open, at the NoTax fee.
        assertEq(clHook.currentFee(key.toId()), 3_000);
        _sell(key, token, held);
        assertEq(MockERC20(token).balanceOf(address(this)), 0, "sold everything");
    }

    /// @dev Same on a Bin leg: a launch with a traded Bin leg cannot be reconfigured either.
    function test_FIX_tradedDisabledBinLegFreezesTheLaunch() public {
        LaunchParamsV2 memory p = _clAndBin(keccak256("review-notax-bin"), address(quote));
        p.schedule = _noTaxSchedule(30 days);
        LaunchResultV2 memory r = _launch(p);
        PoolKey memory clKey = _clKey(r.token, p.legs[0]);
        (PoolKey memory binKey,,) = kit.computeLegKey(r.token, p.legs[1]);

        _buyBin(binKey, r.token, 1 ether); // only the Bin leg trades
        assertTrue(binHook.getLaunch(binKey.toId()).launched, "bin leg recorded its first swap");
        assertFalse(clHook.getLaunch(clKey.toId()).launched, "cl leg untouched");

        PoolKey[] memory keys = new PoolKey[](2);
        keys[0] = clKey;
        keys[1] = binKey;
        vm.prank(OPERATOR);
        vm.expectRevert(
            abi.encodeWithSelector(
                BinLaunchGuardHook.LaunchAlreadyStarted.selector, binKey.toId(), uint256(r.startTime)
            )
        );
        kit.reconfigureLaunch(r.token, keys, _noTaxSchedule(1 days), _noTax());
    }
}
