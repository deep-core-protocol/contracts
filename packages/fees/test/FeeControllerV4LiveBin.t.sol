// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {BinPoolManagerOwner, IBinPoolManagerWithPauseOwnable} from "infinity-core/src/pool-bin/BinPoolManagerOwner.sol";
import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";

import {TokenFixture} from "infinity-core/test/helpers/TokenFixture.sol";

import {DeepCoreProtocolFeeControllerV2} from "../src/DeepCoreProtocolFeeControllerV2.sol";
import {DeepCoreProtocolFeeControllerV4} from "../src/DeepCoreProtocolFeeControllerV4.sol";
import {MockBinLaunchHook, MockBinLaunchKit} from "./FeeControllerV3LiveBin.t.sol";

/// @dev Real Vault + BinPoolManager + BinPoolManagerOwner, and V4 naming two Bin kits, each on its
/// own hook. The same V4 rule on the other manager; the fixtures are the V3 Bin suite's.
contract FeeControllerV4LiveBinTest is Test, TokenFixture {
    using PoolIdLibrary for PoolKey;
    using BinPoolParametersHelper for bytes32;

    Vault vault;
    BinPoolManager poolManager;
    BinPoolManagerOwner wrapper;
    DeepCoreProtocolFeeControllerV2 v2;
    DeepCoreProtocolFeeControllerV4 v4;
    MockBinLaunchHook hookA;
    MockBinLaunchKit kitA;
    MockBinLaunchHook hookB;
    MockBinLaunchKit kitB;

    address safe = makeAddr("governanceSafe");
    address guardian = makeAddr("opsGuardian");
    address attacker = makeAddr("attacker");

    uint24 constant ACTIVE_ID = 2 ** 23;
    uint24 constant PACKED_999 = uint24(999) | (uint24(999) << 12);

    function setUp() public {
        initializeTokens();
        vault = new Vault();
        poolManager = new BinPoolManager(vault);
        vault.registerApp(address(poolManager));
        wrapper = new BinPoolManagerOwner(IBinPoolManagerWithPauseOwnable(address(poolManager)));
        poolManager.transferOwnership(address(wrapper));

        v2 = new DeepCoreProtocolFeeControllerV2(safe, guardian);
        hookA = new MockBinLaunchHook();
        kitA = new MockBinLaunchKit(poolManager, hookA);
        hookB = new MockBinLaunchHook();
        kitB = new MockBinLaunchKit(poolManager, hookB);

        address[] memory kits = new address[](2);
        kits[0] = address(kitA);
        kits[1] = address(kitB);
        v4 = new DeepCoreProtocolFeeControllerV4(safe, IProtocolFeeController(address(v2)), kits, new address[](0), 7 days);
        wrapper.setProtocolFeeController(v4);
    }

    function _launchKey(MockBinLaunchHook hook, uint16 binStep) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(hook)),
            poolManager: poolManager,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: bytes32(uint256(1)).setBinStep(binStep)
        });
    }

    function _stamped(PoolKey memory key) internal view returns (uint24 protocolFee) {
        (, protocolFee,) = poolManager.getSlot0(key.toId());
    }

    function test_LiveBin_BothKits_BornAtZero_AndTheOwnerCannotChargeEither() public {
        PoolKey memory a = _launchKey(hookA, 10);
        PoolKey memory b = _launchKey(hookB, 10);
        kitA.createLockedLaunch(a, ACTIVE_ID);
        kitB.createLockedLaunch(b, ACTIVE_ID);
        assertEq(_stamped(a), 0);
        assertEq(_stamped(b), 0);

        vm.startPrank(safe);
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.LockedLaunchPoolKeepsZeroFee.selector, a.toId())
        );
        v4.setPoolProtocolFee(address(poolManager), a, PACKED_999);
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.LockedLaunchPoolKeepsZeroFee.selector, b.toId())
        );
        v4.setPoolProtocolFee(address(poolManager), b, PACKED_999);
        vm.stopPrank();
        assertEq(_stamped(a), 0);
        assertEq(_stamped(b), 0);
    }

    function test_LiveBin_NormalPool_PaysTheConfiguredFee() public {
        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: 3000,
            parameters: bytes32(0).setBinStep(10)
        });
        poolManager.initialize(key, ACTIVE_ID);
        assertEq(_stamped(key), PACKED_999);
    }

    function test_LiveBin_Spoof_HookPoolNotThroughAKit() public {
        PoolKey memory a = _launchKey(hookA, 10);
        PoolKey memory b = _launchKey(hookB, 10);
        vm.startPrank(attacker);
        hookA.claim(a);
        poolManager.initialize(a, ACTIVE_ID);
        hookB.claim(b);
        poolManager.initialize(b, ACTIVE_ID);
        vm.stopPrank();
        assertEq(_stamped(a), PACKED_999);
        assertEq(_stamped(b), PACKED_999);
    }
}
