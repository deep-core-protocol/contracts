// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {BinPoolManagerOwner, IBinPoolManagerWithPauseOwnable} from "infinity-core/src/pool-bin/BinPoolManagerOwner.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IBinHooks} from "infinity-core/src/pool-bin/interfaces/IBinHooks.sol";
import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";

import {TokenFixture} from "infinity-core/test/helpers/TokenFixture.sol";

import {DeepCoreProtocolFeeControllerV2} from "../src/DeepCoreProtocolFeeControllerV2.sol";
import {DeepCoreProtocolFeeControllerV3} from "../src/DeepCoreProtocolFeeControllerV3.sol";
import {ILockedLaunchOracle} from "../src/interfaces/ILockedLaunchOracle.sol";

contract MockBinLaunchHook {
    using PoolIdLibrary for PoolKey;

    mapping(PoolId => address) public launchOwner;

    function getHooksRegistrationBitmap() external pure returns (uint16) {
        return 1;
    }

    function claim(PoolKey calldata key) external {
        require(launchOwner[key.toId()] == address(0), "claimed");
        launchOwner[key.toId()] = msg.sender;
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint24) external view returns (bytes4) {
        require(launchOwner[key.toId()] == sender, "not the claimant");
        return IBinHooks.beforeInitialize.selector;
    }
}

/// @dev Flag before initialize, as the design requires. "Locked" is asserted by the fixture, since
/// the Bin locker does not exist yet; the point here is the manager-side read path.
contract MockBinLaunchKit is ILockedLaunchOracle {
    using PoolIdLibrary for PoolKey;

    IBinPoolManager public immutable manager;
    MockBinLaunchHook public immutable hook;
    mapping(bytes32 => bool) private _lockedLaunch;

    constructor(IBinPoolManager manager_, MockBinLaunchHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function createLockedLaunch(PoolKey calldata key, uint24 activeId) external {
        _lockedLaunch[PoolId.unwrap(key.toId())] = true;
        hook.claim(key);
        manager.initialize(key, activeId);
    }

    function isLockedLaunch(bytes32 poolId) external view returns (bool) {
        return _lockedLaunch[poolId];
    }
}

/// @dev Real Vault + BinPoolManager + BinPoolManagerOwner. The same V3 rule on the other manager.
contract FeeControllerV3LiveBinTest is Test, TokenFixture {
    using PoolIdLibrary for PoolKey;
    using BinPoolParametersHelper for bytes32;

    Vault vault;
    BinPoolManager poolManager;
    BinPoolManagerOwner wrapper;
    DeepCoreProtocolFeeControllerV2 v2;
    DeepCoreProtocolFeeControllerV3 v3;
    MockBinLaunchHook hook;
    MockBinLaunchKit kit;

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
        hook = new MockBinLaunchHook();
        kit = new MockBinLaunchKit(poolManager, hook);
        v3 = new DeepCoreProtocolFeeControllerV3(safe, IProtocolFeeController(address(v2)), address(kit));
        wrapper.setProtocolFeeController(v3);
    }

    function _launchKey(uint16 binStep) internal view returns (PoolKey memory) {
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

    function test_LiveBin_KitLaunch_IsBornAtZero() public {
        PoolKey memory key = _launchKey(10);
        kit.createLockedLaunch(key, ACTIVE_ID);
        assertEq(_stamped(key), 0);
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

    function test_LiveBin_Spoof_HookPoolNotThroughTheKit() public {
        PoolKey memory key = _launchKey(10);
        vm.startPrank(attacker);
        hook.claim(key);
        poolManager.initialize(key, ACTIVE_ID);
        vm.stopPrank();
        assertEq(_stamped(key), PACKED_999);
    }
}
