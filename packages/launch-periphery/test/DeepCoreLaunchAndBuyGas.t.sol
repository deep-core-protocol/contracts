// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {console2} from "forge-std/console2.sol";

import {LaunchParamsV2, LaunchResultV2} from "deepcore-launchpad/src/interfaces/ILaunchpadKitV2.sol";

import {DeepCoreLaunchAndBuy} from "../src/DeepCoreLaunchAndBuy.sol";
import {LaunchAndBuyFixture} from "./LaunchAndBuyFixture.sol";

/// @notice What the convenience costs, measured against the thing it replaces.
///
/// @dev These are NOT deployment figures. CLAUDE.md's DEPLOYMENT RULE (2026-09-19) says a contract
/// compiled alongside `LaunchpadKitV2` gets the kit's 9 000-run compilation profile; this package
/// closes that by using 9 000 runs for EVERYTHING, so the numbers below ARE the release bytecode's -
/// but they are still measured against a fresh in-memory chain with cold storage everywhere, so read
/// them as an upper bound on the marginal cost, not as a mainnet receipt.
contract DeepCoreLaunchAndBuyGasTest is LaunchAndBuyFixture {
    function test_GAS_launchAndBuyVersusLaunchThenBuy() public {
        // (a) A launch through the kit directly, with no buy. The baseline.
        LaunchParamsV2 memory direct = _oneCL(CREATOR, bytes32("gasA"), address(0));
        direct.creator = CREATOR;
        direct.launchOperator = CREATOR;
        direct.launchSteward = CREATOR;
        // The kit salts on ITS caller, so a direct launch by CREATOR needs the tick side recomputed
        // for the address THAT path produces.
        direct.legs[0] = _clLeg(kit.predictLaunchToken(CREATOR, bytes32("gasA")), address(0), 10_000);

        uint256 fee = _kitFee(direct);
        vm.prank(CREATOR);
        uint256 g0 = gasleft();
        kit.createLaunch{value: fee}(direct);
        uint256 plainLaunch = g0 - gasleft();

        // (b) The same launch and a 3 ether buy, in one transaction, through this contract.
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("gasB"), address(0));
        vm.prank(CREATOR);
        uint256 g1 = gasleft();
        lab.launchAndBuy{value: fee + 3 ether}(p, _buy(3 ether));
        uint256 launchAndBuy = g1 - gasleft();

        console2.log("createLaunch (1 native CL leg)      ", plainLaunch);
        console2.log("launchAndBuy (same leg + 3e18 buy)  ", launchAndBuy);
        console2.log("marginal cost of the first buy      ", launchAndBuy - plainLaunch);

        assertGt(launchAndBuy, plainLaunch, "the buy is not free");
    }

    function test_GAS_erc20QuoteAndBinLeg() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("gasC"), address(quoteToken));
        vm.prank(CREATOR);
        uint256 g = gasleft();
        lab.launchAndBuy{value: _kitFee(p)}(p, _buy(3 ether));
        console2.log("launchAndBuy (ERC-20 quote, CL leg) ", g - gasleft());

        LaunchParamsV2 memory b = _oneBin(address(quoteToken));
        vm.prank(CREATOR);
        g = gasleft();
        lab.launchAndBuy{value: _kitFee(b)}(b, _buy(1 ether));
        console2.log("launchAndBuy (ERC-20 quote, Bin leg)", g - gasleft());
    }

    function test_GAS_runtimeSize() public view {
        console2.log("DeepCoreLaunchAndBuy runtime bytes     ", address(lab).code.length);
        assertLt(address(lab).code.length, 24_576, "EIP-170");
    }
}
