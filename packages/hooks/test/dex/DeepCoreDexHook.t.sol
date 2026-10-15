// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {DeepCoreDynamicFeeHook} from "../../src/dex/DeepCoreDynamicFeeHook.sol";
import {DeepCoreDexHook} from "../../src/dex/DeepCoreDexHook.sol";
import {OracleModule} from "../../src/oracle/OracleModule.sol";
import {IDeepCoreOracle} from "../../src/oracle/IDeepCoreOracle.sol";
import {OracleBehaviour} from "../oracle/OracleBehaviour.sol";
import {DeepCoreDynamicFeeHookTest} from "./DeepCoreDynamicFeeHook.t.sol";

/// @notice The ENTIRE accepted dynamic-fee suite, run against `DeepCoreDexHook`: the oracle must not
/// change one behaviour of the fee, the share, the tuner, the roles or the funds.
contract DeepCoreDexHookFeeTest is DeepCoreDynamicFeeHookTest {
    function _newHook() internal override returns (DeepCoreDynamicFeeHook) {
        return new DeepCoreDexHook(
            manager, IVault(address(vault)), SAFE, RECIPIENT, FEE_CAP, SHARE, MAX_SHARE, NOTICE, NOTICE, MAX_MOVE, 100, 600, 16
        );
    }

    function test_dex_isTheDynamicFeeHookPlusTheOracle() public view {
        DeepCoreDexHook dex = DeepCoreDexHook(payable(address(hook)));
        assertEq(dex.kind(), keccak256("deepcore.oracle.truncated-twap.v1"));
        assertEq(dex.ORACLE_MAX_TICK_DELTA(), 100);
        (, uint16 card, uint16 next) = dex.stateOf(id);
        assertEq(card, 1, "the pool opened in setUp is observed");
        assertEq(next, 16);
    }

    /// @dev The oracle's write sits in front of the fee and must not change it: the swap's fee in
    /// core's Swap event equals `currentFee` read one call earlier, as on the accepted hook.
    function test_dex_feeOfEverySwapUnchangedByTheOracleWrite() public {
        for (uint256 i; i < 6; ++i) {
            vm.warp(vm.getBlockTimestamp() + 7);
            bool zf1 = i % 2 == 0;
            uint24 expected = hook.currentFee(id, zf1);
            (,, uint24 protocolPips) = _parts(zf1);
            vm.recordLogs();
            _swap(key, zf1, -int256(1 ether) * int256(i + 1));
            assertEq(_swapFee(vm.getRecordedLogs()), expected - protocolPips, "LP part of the fee in Swap event");
        }
    }

    function _parts(bool zf1) internal view returns (uint24 total, uint24 lp, uint24 protocol) {
        (,,, total, lp, protocol) = hook.feeParts(id, zf1);
    }
}

/// @notice The oracle's behaviour suite, run against `DeepCoreDexHook`.
contract DeepCoreDexHookOracleTest is OracleBehaviour {
    address internal constant SAFE = address(0x5AFE);
    address internal constant RECIPIENT = address(0xFEE5);

    function _deployHook(uint24 maxDelta, uint32 minWindow, uint16 initialCard) internal override returns (address) {
        return address(
            new DeepCoreDexHook(
                manager, IVault(address(vault)), SAFE, RECIPIENT, 50_000, 1_500, 3_000, 7 days, 7 days, 500, maxDelta, minWindow, initialCard
            )
        );
    }

    function _keyFee() internal pure override returns (uint24) {
        return LPFeeLibrary.DYNAMIC_FEE_FLAG;
    }

    function _beforeInit(PoolKey memory k) internal override {
        DeepCoreDynamicFeeHook.FeeConfig memory c;
        c.baseFee = 3_000;
        c.volSlope = 10;
        c.sameSecondSlope = 50;
        c.minBaseFee = 500;
        c.maxBaseFee = 10_000;
        c.maxVolSlope = 40;
        c.maxSameSecondSlope = 100;
        c.maxFee = 30_000;
        c.volCap = 2_000;
        c.decaySeconds = 1_800;
        c.deadband = 5;
        c.maxBaseFeeStep = 500;
        c.maxSlopeStep = 5;
        c.minTuneInterval = 3_600;
        DeepCoreDynamicFeeHook(payable(address(k.hooks))).configure(k, c, 3_000);
    }

    function test_dex_bitmapUnchanged_0x08C3() public view {
        assertEq(DeepCoreDexHook(payable(address(key.hooks))).getHooksRegistrationBitmap(), 0x08C3);
    }

    function test_dex_aPoolTheFeeHookRefusesIsNeverObserved() public {
        // an unconfigured pool cannot be born, so it never gets an observation either
        PoolId none = PoolId.wrap(bytes32(uint256(9)));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreOracle.PoolNotObserved.selector, none));
        _oracle().consult(none, 600);
    }
}
