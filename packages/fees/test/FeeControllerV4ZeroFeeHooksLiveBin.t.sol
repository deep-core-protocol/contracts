// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {BinPoolManagerOwner, IBinPoolManagerWithPauseOwnable} from "infinity-core/src/pool-bin/BinPoolManagerOwner.sol";
import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {TokenFixture} from "infinity-core/test/helpers/TokenFixture.sol";

import {DeepCoreBinDynamicFeeHook} from "deepcore-hooks/src/dex/DeepCoreBinDynamicFeeHook.sol";

import {DeepCoreProtocolFeeControllerV2} from "../src/DeepCoreProtocolFeeControllerV2.sol";
import {DeepCoreProtocolFeeControllerV4} from "../src/DeepCoreProtocolFeeControllerV4.sol";
import {MockLaunchOracle} from "./utils/V3Mocks.sol";

/// @dev The Bin side of the zero-fee hook list: REAL BinPoolManager, the real V2 and the REAL
/// `DeepCoreBinDynamicFeeHook`. A pool on the listed instance is born at zero, one on an unlisted
/// instance of the same hook pays V2's 999.
contract FeeControllerV4ZeroFeeHooksLiveBinTest is Test, TokenFixture {
    using PoolIdLibrary for PoolKey;
    using BinPoolParametersHelper for bytes32;

    uint24 internal constant ACTIVE_ID = 2 ** 23;
    uint24 internal constant PACKED_999 = uint24(999) | (uint24(999) << 12);
    uint32 internal constant NOTICE = 7 days;

    Vault internal vault;
    BinPoolManager internal manager;
    BinPoolManagerOwner internal wrapper;
    DeepCoreProtocolFeeControllerV2 internal v2;
    DeepCoreProtocolFeeControllerV4 internal v4;
    DeepCoreBinDynamicFeeHook internal listed;
    DeepCoreBinDynamicFeeHook internal unlisted;

    address internal safe = makeAddr("governanceSafe");
    address internal creator = makeAddr("poolCreator");

    function setUp() public {
        vm.warp(1_800_000_000);
        initializeTokens();
        vault = new Vault();
        manager = new BinPoolManager(vault);
        vault.registerApp(address(manager));
        wrapper = new BinPoolManagerOwner(IBinPoolManagerWithPauseOwnable(address(manager)));
        manager.transferOwnership(address(wrapper));

        v2 = new DeepCoreProtocolFeeControllerV2(safe, makeAddr("guardian"));
        listed = _hook();
        unlisted = _hook();
        address[] memory kits = new address[](1);
        kits[0] = address(new MockLaunchOracle());
        address[] memory hooks = new address[](1);
        hooks[0] = address(listed);
        v4 = new DeepCoreProtocolFeeControllerV4(safe, IProtocolFeeController(address(v2)), kits, hooks, NOTICE);
        wrapper.setProtocolFeeController(v4);
    }

    function _hook() internal returns (DeepCoreBinDynamicFeeHook) {
        return new DeepCoreBinDynamicFeeHook(manager, IVault(address(vault)), safe, safe, 50_000, 1_500, 3_000, NOTICE, 1 days, 500);
    }

    function _cfg() internal pure returns (DeepCoreBinDynamicFeeHook.FeeConfig memory c) {
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
        c.deadband = 25;
        c.maxBaseFeeStep = 500;
        c.maxSlopeStep = 5;
        c.minTuneInterval = 3_600;
    }

    function _open(DeepCoreBinDynamicFeeHook hook, uint16 binStep) internal returns (PoolKey memory k) {
        k = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(hook)),
            poolManager: manager,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: bytes32(uint256(hook.getHooksRegistrationBitmap())).setBinStep(binStep)
        });
        vm.prank(creator);
        hook.configure(k, _cfg(), 3_000);
        manager.initialize(k, ACTIVE_ID);
    }

    function _stamped(PoolKey memory k) internal view returns (uint24 protocolFee) {
        (, protocolFee,) = manager.getSlot0(k.toId());
    }

    function test_LiveBin_ListedHookPoolIsBornAtZero_UnlistedPays() public {
        assertEq(_stamped(_open(listed, 10)), 0, "a listed Bin hook's pool is born at zero");
        assertEq(_stamped(_open(unlisted, 10)), PACKED_999, "the same hook, unlisted, pays V2's fee");
    }

    function test_LiveBin_OwnerCannotCharge_AddAndRemove() public {
        PoolKey memory born = _open(listed, 10);
        vm.startPrank(safe);
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreProtocolFeeControllerV4.ZeroFeeHookPoolKeepsZeroFee.selector, born.toId(), address(listed))
        );
        v4.setPoolProtocolFee(address(manager), born, PACKED_999);
        v4.addZeroFeeHook(address(unlisted));
        v4.scheduleZeroFeeHookRemoval(address(listed));
        vm.stopPrank();

        assertEq(_stamped(_open(unlisted, 20)), 0, "added: its new pools are born at zero");
        vm.warp(block.timestamp + NOTICE);
        assertEq(_stamped(_open(listed, 20)), PACKED_999, "removed: its new pools pay again");
    }
}
