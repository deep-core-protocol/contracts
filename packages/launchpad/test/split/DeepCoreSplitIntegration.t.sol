// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";

import {LaunchParamsV2, LaunchResultV2, TenantConfig, BinShape} from "../../src/interfaces/ILaunchpadKitV2.sol";
import {Preset} from "../../src/libraries/LaunchPresets.sol";
import {DeepCoreSplit} from "../../src/split/DeepCoreSplit.sol";
import {DeepCoreSplitFactory} from "../../src/split/DeepCoreSplitFactory.sol";
import {KitV2Fixture} from "../kitv2/KitV2Fixture.sol";

/// @title DeepCoreSplitIntegration
/// @notice A split as the creator AND the integrator of a real Kit v2 launch, on the real Vault, pool managers,
/// lockers and launch guards: locked-LP fees, the creator tax and the kit's integrator launch fee all reach
/// the split through `collect` / `collectKitFees`, and leave to the team and the protocol.
contract DeepCoreSplitIntegrationTest is KitV2Fixture {
    address constant ALICE = address(0xA1);
    address constant BOB = address(0xB2);
    address constant TENANT = address(0x7E4A);

    DeepCoreSplitFactory splitFactory;
    DeepCoreSplit team;

    function setUp() public {
        _deployAll();
        splitFactory = new DeepCoreSplitFactory(safe, safe, 0, 1 ether, 100, 500, 7 days);
        address[] memory p = new address[](2);
        uint96[] memory w = new uint96[](2);
        (p[0], p[1]) = (ALICE, BOB);
        (w[0], w[1]) = (6_000, 4_000);
        team = DeepCoreSplit(payable(splitFactory.createSplit("Team", p, w, new string[](2), 500)));
    }

    function _taxedLaunch(bytes32 salt) internal returns (LaunchParamsV2 memory p, LaunchResultV2 memory r) {
        p = _oneCL(salt, address(quote));
        p.creator = address(team);
        p.integrator = address(team);
        p.tax.buyBps = 500;
        p.tax.sellBps = 300;
        p.tax.taxSeconds = 1 days;
        p.tax.creatorBps = 7_000;
        p.tax.protocolBps = 1_000;
        p.tax.integratorBps = 2_000;
        r = _launch(p);
        vm.warp(r.startTime + 400);
    }

    function test_INTEGRATION_lockerFeesAndCreatorTaxReachTheTeam() public {
        (LaunchParamsV2 memory p, LaunchResultV2 memory r) = _taxedLaunch(keccak256("split-int-a"));
        quote.mint(address(this), 1_000 ether);
        _buyCL(_clKey(r.token, p.legs[0]), r.token, 100 ether);

        // The trade fee and the creator tax, both in the QUOTE, both from the guard: the split is the
        // creator and the integrator of each. One settle per pot, one collect for the lot.
        Currency q = Currency.wrap(address(quote));
        PoolId id = PoolId.wrap(r.poolIds[0]);
        clHook.settleFee(id, q);
        uint256 feeOwed = clHook.claimable(address(team), q);
        assertGt(feeOwed, 0, "the split is credited as creator and integrator of the fee");
        clHook.settleTax(id, q);
        uint256 owed = clHook.claimable(address(team), q);
        assertGt(owed, feeOwed, "and of the tax");
        assertEq(clHook.pendingTax(id, Currency.wrap(r.token)), 0, "nothing is owed in the launch token");
        vm.prank(address(0xBEEF)); // anyone collects
        assertEq(team.collect(address(clHook), q), owed);
        assertEq(clHook.claimable(address(team), q), 0);

        // The locked position earned no LP fee, so the locker holds nothing for the split.
        clLocker.collectFees(r.lockIds[0]);
        assertEq(clLocker.claimable(address(team), q), 0);

        // Out to the team and the protocol, 1% first, then 60/40.
        team.releaseAll(q);
        uint256 toProtocolQ = owed / 100;
        assertEq(quote.balanceOf(ALICE), (owed * 9_900 * 6_000) / (10_000 * 10_000));
        assertEq(quote.balanceOf(BOB), (owed * 9_900 * 4_000) / (10_000 * 10_000));
        assertLe(quote.balanceOf(address(team)), 2);
        assertEq(MockERC20(r.token).balanceOf(ALICE), 0, "the team is paid in the quote alone");
        assertGe(quote.balanceOf(safe), toProtocolQ, "the protocol share went to the Safe");
    }

    function test_INTEGRATION_kitIntegratorFeeReachesTheTeamThroughATenant() public {
        TenantConfig memory c;
        c.integrator = address(team);
        c.integratorBps = 1_000;
        c.integratorLaunchFeeWei = 0.002 ether;
        c.allowedPresets = uint8(1 << uint8(Preset.FairLaunch)) | uint8(1 << uint8(Preset.Custom));
        c.allowedBinShapes = uint8(1 << uint8(BinShape.Linear));
        c.active = true;
        vm.prank(TENANT);
        kit.setTenantConfig(c);

        LaunchParamsV2 memory p = _oneCL(keccak256("split-int-b"), address(quote));
        p.tenant = TENANT;
        p.integrator = address(team);
        p.integratorBps = 1_000;
        p.integratorLaunchFeeWei = 0.002 ether;
        _launch(p);

        assertEq(team.collectKitFees(address(kit)), 0.002 ether);
        team.releaseAll(Currency.wrap(address(0)));
        assertEq(ALICE.balance, 0.002 ether * 9_900 * 6_000 / 1e8);
        assertEq(BOB.balance, 0.002 ether * 9_900 * 4_000 / 1e8);
        assertEq(safe.balance >= 0.00002 ether, true);
    }

    /// @dev The fee is the guard's now, and the guard speaks the lockers' rotation: the SAME
    /// `DeepCoreSplit.acceptCreator(source, id)` a split used for a lock takes over a launch's fee, with the
    /// guard as the source and the pool id as the number. No change to a split that is already deployed.
    function test_INTEGRATION_aCreatorHandsAnExistingLaunchFeeToTheSplit() public {
        LaunchParamsV2 memory p = _oneCL(keccak256("split-int-c"), address(quote));
        LaunchResultV2 memory r = _launch(p); // creator = CREATOR
        uint256 id = uint256(r.poolIds[0]);
        vm.prank(CREATOR);
        clHook.transferCreator(id, address(team));
        assertEq(clHook.pendingCreator(id), address(team));

        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(DeepCoreSplit.NotPayee.selector, address(0xBEEF)));
        team.acceptCreator(address(clHook), id);

        vm.prank(ALICE);
        team.acceptCreator(address(clHook), id);
        assertEq(clHook.getFeeSplit(PoolId.wrap(r.poolIds[0])).creator, address(team));
        assertEq(clHook.pendingCreator(id), address(0));

        vm.warp(r.startTime + 400);
        quote.mint(address(this), 1_000 ether);
        _buyCL(_clKey(r.token, p.legs[0]), r.token, 50 ether);
        Currency q = Currency.wrap(address(quote));
        clHook.settleFee(PoolId.wrap(r.poolIds[0]), q);
        assertGt(clHook.claimable(address(team), q), 0, "the creator share now accrues to the split");
        assertEq(clHook.claimable(CREATOR, q), 0);
        team.collect(address(clHook), q);
        team.releaseAll(q);
        assertGt(quote.balanceOf(ALICE), 0);
    }

    /// @dev The lock's own creator role still rotates to a split as it always did; it carries no fee
    /// on a pool the current guards run, because that pool's LP fee is zero.
    function test_INTEGRATION_theLocksCreatorRoleStillRotatesAndEarnsNothing() public {
        LaunchParamsV2 memory p = _oneCL(keccak256("split-int-d"), address(quote));
        LaunchResultV2 memory r = _launch(p);
        vm.prank(CREATOR);
        clLocker.transferCreator(r.lockIds[0], address(team));
        vm.prank(ALICE);
        team.acceptCreator(address(clLocker), r.lockIds[0]);

        vm.warp(r.startTime + 400);
        quote.mint(address(this), 1_000 ether);
        _buyCL(_clKey(r.token, p.legs[0]), r.token, 50 ether);
        clLocker.collectFees(r.lockIds[0]);
        assertEq(clLocker.claimable(address(team), Currency.wrap(address(quote))), 0);
    }
}
