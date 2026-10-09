// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {console} from "forge-std/console.sol";

import {LaunchpadKitV2} from "../../src/LaunchpadKitV2.sol";
import {BinShape, LegParams, LaunchParamsV2} from "../../src/interfaces/ILaunchpadKitV2.sol";

import {KitV2Fixture} from "./KitV2Fixture.sol";

/// @notice The gas budget in docs/kit-v2-integration.md "Kit v2 (implemented)" is measured here, not estimated.
/// @dev Each case runs in its own test, so storage and accounts start cold as in a real first launch of a
/// token (the managers, lockers, hooks and registry are already deployed). The number is the whole
/// `createLaunch` call as the launcher's transaction executes it, minus the 21k intrinsic and calldata cost.
/// Ceilings are asserted so a regression is a failing test, with headroom of roughly 15%.
contract LaunchpadKitV2GasTest is KitV2Fixture {
    function setUp() public {
        _deployAll();
    }

    function _measure(string memory label, LaunchParamsV2 memory p) internal returns (uint256 used) {
        uint256 fee = kit.launchFeeWei();
        vm.deal(LAUNCHER, 1 ether);
        vm.prank(LAUNCHER);
        uint256 g = gasleft();
        kit.createLaunch{value: fee}(p);
        used = g - gasleft();
        console.log(label, used);
    }

    function test_GAS_oneCL() public {
        uint256 used = _measure("createLaunch: 1 CL leg                  ", _oneCL(keccak256("g1"), address(quote)));
        assertLt(used, 2_700_000);
    }

    function test_GAS_oneCL_native() public {
        uint256 used = _measure("createLaunch: 1 CL leg, native quote    ", _oneCL(keccak256("g1n"), address(0)));
        assertLt(used, 2_700_000);
    }

    function test_GAS_oneCLOneBin10() public {
        uint256 used =
            _measure("createLaunch: 1 CL + 1 Bin (10 bins)     ", _clAndBin(keccak256("g2"), address(quote)));
        assertLt(used, 6_500_000);
    }

    function test_GAS_oneBin32() public {
        LegParams[] memory legs = new LegParams[](1);
        legs[0] = _binLeg(address(quote), 10_000, BinShape.Linear, 32);
        uint256 used = _measure("createLaunch: 1 Bin (32 bins)            ", _params(keccak256("g3"), legs));
        assertLt(used, 12_000_000);
    }

    /// @dev The caps `script/DeployLaunchpadKitV2.s.sol` deploys with. Duplicated, not imported: the script
    /// test asserts the deployed kit reports exactly these.
    uint8 internal constant DEPLOY_MAX_LEGS = 4;
    uint16 internal constant DEPLOY_MAX_BINS_PER_LEG = 20;

    /// @dev Measured 2026-09-14: four 32-bin legs cost 35.5M, over Nitro's 32M block. That is why the deployment
    /// caps a leg at 20 bins. This is the worst case those caps allow, and it must leave real headroom.
    function test_GAS_worstCaseDeploymentCaps() public {
        LegParams[] memory legs = new LegParams[](DEPLOY_MAX_LEGS);
        legs[0] = _binLeg(address(quote), 2_500, BinShape.Flat, DEPLOY_MAX_BINS_PER_LEG);
        legs[1] = _binLeg(address(stock), 2_500, BinShape.Flat, DEPLOY_MAX_BINS_PER_LEG);
        legs[2] = _binLeg(address(0), 2_500, BinShape.Flat, DEPLOY_MAX_BINS_PER_LEG);
        legs[3] = _binLeg(address(weth), 2_500, BinShape.Flat, DEPLOY_MAX_BINS_PER_LEG);
        uint256 used = _measure("createLaunch: 4 Bin legs x 20 bins       ", _params(keccak256("g4"), legs));
        // Arbitrum Nitro's per-block gas limit is 32,000,000. Keep >= 10% free for L1 data and busy blocks.
        assertLt(used, 28_800_000, "worst case must fit one block with headroom");
    }

    function test_GAS_bytecodeUnderEip170() public view {
        assertLe(address(kit).code.length, 24_576, "LaunchpadKitV2 runtime size");
        console.log("LaunchpadKitV2 runtime bytes", address(kit).code.length);
    }
}
