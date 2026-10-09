// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {IProtocolFeeController} from "infinity-core/src/interfaces/IProtocolFeeController.sol";

import {DeepCoreProtocolFeeControllerV4} from "deepcore-fees/src/DeepCoreProtocolFeeControllerV4.sol";

import {LaunchpadKitV2} from "../../src/LaunchpadKitV2.sol";
import {ILaunchpadKitV2, LaunchParamsV2, LaunchResultV2} from "../../src/interfaces/ILaunchpadKitV2.sol";

import {KitV2Fixture} from "./KitV2Fixture.sol";

/// @dev 999 pips in each direction: what the policy controller charges a pool nobody zeroed.
uint24 constant CHARGED = 999 | (999 << 12);

/// @dev A controller that charges every pool and answers to ONE kit (V3's shape).
contract ChargingSingleController is IProtocolFeeController {
    address public immutable launchOracle;

    constructor(address oracle) {
        launchOracle = oracle;
    }

    function protocolFeeForPool(PoolKey memory) external pure returns (uint24) {
        return CHARGED;
    }
}

/// @dev A controller that charges every pool and answers to a SET of kits (V4's shape). It has no
/// `launchOracle()`, exactly as V4 has none.
contract ChargingSetController is IProtocolFeeController {
    mapping(address => bool) internal _named;

    constructor(address[] memory oracles) {
        for (uint256 i; i < oracles.length; ++i) {
            _named[oracles[i]] = true;
        }
    }

    function isLaunchOracle(address candidate) external view returns (bool) {
        return _named[candidate];
    }

    function protocolFeeForPool(PoolKey memory) external pure returns (uint24) {
        return CHARGED;
    }
}

/// @dev A controller that charges every pool and knows no kit at all (V2's shape).
contract ChargingPlainController is IProtocolFeeController {
    function protocolFeeForPool(PoolKey memory) external pure returns (uint24) {
        return CHARGED;
    }
}

/// @dev Answers `isLaunchOracle` with a word that is not 1. A `bool` it is not, so it names nobody.
contract ChargingOddWordController is IProtocolFeeController {
    function isLaunchOracle(address) external pure returns (uint256) {
        return 2;
    }

    function protocolFeeForPool(PoolKey memory) external pure returns (uint24) {
        return CHARGED;
    }
}

/// @dev Burns whatever gas `isLaunchOracle` is given. The kit's read is bounded, so the launch goes on.
contract ChargingWastefulController is IProtocolFeeController {
    function isLaunchOracle(address) external view returns (bool) {
        uint256 sink;
        while (gasleft() > 0) {
            sink += block.number;
        }
        return sink == 0;
    }

    function protocolFeeForPool(PoolKey memory) external pure returns (uint24) {
        return CHARGED;
    }
}

/// @dev Answers `isLaunchOracle` with two words. One word is the only shape that is read as an answer.
contract ChargingLongAnswerController is IProtocolFeeController {
    function isLaunchOracle(address) external pure returns (uint256, uint256) {
        return (1, 1);
    }

    function protocolFeeForPool(PoolKey memory) external pure returns (uint24) {
        return CHARGED;
    }
}

/// @notice The kit's last check on a fresh pool: if the installed fee controller says it answers to THIS
/// kit, the pool must have been born at a zero protocol fee, or the launch reverts. Under a controller
/// that knows a set of kits (V4) the check read `launchOracle()`, got no answer and never ran; it now asks
/// the set too.
contract LaunchpadKitV2BornAtZeroTest is KitV2Fixture {
    using PoolIdLibrary for PoolKey;

    function setUp() public {
        _deployAll();
    }

    function _install(IProtocolFeeController controller) internal {
        clPM.setProtocolFeeController(controller);
        binPM.setProtocolFeeController(controller);
    }

    function _only(address a) internal pure returns (address[] memory list) {
        list = new address[](1);
        list[0] = a;
    }

    function _legId(LaunchParamsV2 memory p, uint256 leg) internal view returns (bytes32) {
        (PoolKey memory key,,) = kit.computeLegKey(_token(p.userSalt), p.legs[leg]);
        return PoolId.unwrap(key.toId());
    }

    function _expectNotZero(LaunchParamsV2 memory p, uint256 leg) internal {
        vm.expectRevert(
            abi.encodeWithSelector(ILaunchpadKitV2.ProtocolFeeNotZero.selector, _legId(p, leg), CHARGED)
        );
    }

    /*//////////////////////////////////////////////////////////////
                    A CONTROLLER THAT NAMES THIS KIT
    //////////////////////////////////////////////////////////////*/

    function test_FIX_setControllerNamingTheKitAndChargingRevertsTheLaunch_CL() public {
        _install(new ChargingSetController(_only(address(kit))));
        LaunchParamsV2 memory p = _oneCL(keccak256("set-cl"), address(quote));
        _expectNotZero(p, 0);
        _launch(p);
    }

    function test_FIX_setControllerNamingTheKitAndChargingRevertsTheLaunch_Bin() public {
        // Only the Bin manager charges: the CL leg is born at zero under V3 and the Bin leg is refused.
        binPM.setProtocolFeeController(new ChargingSetController(_only(address(kit))));
        LaunchParamsV2 memory p = _clAndBin(keccak256("set-bin"), address(quote));
        _expectNotZero(p, 1);
        _launch(p);
    }

    function test_FIX_setControllerNamingTheKitAmongOthersStillBinds() public {
        address[] memory set = new address[](3);
        set[0] = address(0xB0B1);
        set[1] = address(kit);
        set[2] = address(0xB0B2);
        _install(new ChargingSetController(set));
        LaunchParamsV2 memory p = _oneCL(keccak256("set-among"), address(quote));
        _expectNotZero(p, 0);
        _launch(p);
    }

    function test_singleControllerNamingTheKitAndChargingRevertsTheLaunch() public {
        _install(new ChargingSingleController(address(kit)));
        LaunchParamsV2 memory p = _oneCL(keccak256("single"), address(quote));
        _expectNotZero(p, 0);
        _launch(p);
    }

    /*//////////////////////////////////////////////////////////////
                 A CONTROLLER THAT DOES NOT NAME THIS KIT
    //////////////////////////////////////////////////////////////*/

    function _launchesCharged(IProtocolFeeController controller, bytes32 salt) internal {
        _install(controller);
        LaunchResultV2 memory r = _launch(_oneCL(salt, address(quote)));
        assertEq(_clProtocolFee(r.poolIds[0]), CHARGED, "the pool pays the controller's fee");
        assertTrue(kit.isLockedLaunch(r.poolIds[0]), "and the launch exists");
    }

    function test_setControllerNamingAnotherKitLetsTheLaunchThrough() public {
        _launchesCharged(new ChargingSetController(_only(address(0xB0B1))), keccak256("set-other"));
    }

    function test_singleControllerNamingAnotherKitLetsTheLaunchThrough() public {
        _launchesCharged(new ChargingSingleController(address(0xB0B1)), keccak256("single-other"));
    }

    function test_controllerThatKnowsNoKitLetsTheLaunchThrough() public {
        _launchesCharged(new ChargingPlainController(), keccak256("plain"));
    }

    function test_answerThatIsNotOneIsNotAYes() public {
        _launchesCharged(new ChargingOddWordController(), keccak256("odd"));
    }

    function test_answerLongerThanOneWordIsNotAYes() public {
        _launchesCharged(new ChargingLongAnswerController(), keccak256("long"));
    }

    function test_controllerBurningTheBoundedGasDoesNotStopALaunch() public {
        _install(new ChargingWastefulController());
        LaunchParamsV2 memory p = _oneCL(keccak256("wasteful"), address(quote));
        uint256 value = kit.launchFeeWei() + p.integratorLaunchFeeWei;
        vm.deal(LAUNCHER, LAUNCHER.balance + value);
        vm.prank(LAUNCHER);
        uint256 before = gasleft();
        LaunchResultV2 memory r = kit.createLaunch{value: value}(p);
        uint256 used = before - gasleft();
        assertEq(_clProtocolFee(r.poolIds[0]), CHARGED);
        // One leg, so the controller was asked once: it can cost a launch the bound and no more. The
        // figure is the launch itself plus the 20,000 handed over, with room for the launch to vary.
        assertLt(used, 8_000_000, "a wasteful controller bills the bound, not the block");
    }

    /*//////////////////////////////////////////////////////////////
                         THE REAL V4, WITH THIS KIT
    //////////////////////////////////////////////////////////////*/

    function test_V4_kitLaunchIsBornAtZeroAndTheControllerNamesTheKit() public {
        DeepCoreProtocolFeeControllerV4 v4 =
            new DeepCoreProtocolFeeControllerV4(safe, IProtocolFeeController(address(v2)), _only(address(kit)), new address[](0), 7 days);
        _install(v4);
        assertTrue(v4.isLaunchOracle(address(kit)), "the kit is in the set");

        LaunchResultV2 memory r = _launch(_clAndBin(keccak256("v4"), address(quote)));
        assertEq(_clProtocolFee(r.poolIds[0]), 0, "CL leg");
        assertEq(_binProtocolFee(r.poolIds[1]), 0, "Bin leg");
        assertTrue(v4.isLockedLaunchPool(PoolId.wrap(r.poolIds[0])));
        assertTrue(v4.isLockedLaunchPool(PoolId.wrap(r.poolIds[1])));
    }

    function test_V4_twoKitsBothBornAtZero() public {
        LaunchpadKitV2 other = new LaunchpadKitV2(_deployment());
        address[] memory set = new address[](2);
        set[0] = address(other);
        set[1] = address(kit);
        DeepCoreProtocolFeeControllerV4 v4 =
            new DeepCoreProtocolFeeControllerV4(safe, IProtocolFeeController(address(v2)), set, new address[](0), 7 days);
        _install(v4);

        LaunchResultV2 memory r = _launch(_oneCL(keccak256("v4-second"), address(quote)));
        assertEq(_clProtocolFee(r.poolIds[0]), 0, "the second kit in the set is heard");
        assertTrue(v4.isLockedLaunchPool(PoolId.wrap(r.poolIds[0])));
    }
}
