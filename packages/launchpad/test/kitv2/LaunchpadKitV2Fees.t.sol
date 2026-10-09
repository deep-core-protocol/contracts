// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {LaunchpadMetadata} from "deepcore-registry/src/IDeepCoreLaunchRegistry.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";

import {
    ILaunchpadKitV2,
    BinShape,
    LegParams,
    ScheduleParams,
    LaunchParamsV2,
    LaunchResultV2,
    TenantConfig
} from "../../src/interfaces/ILaunchpadKitV2.sol";
import {Preset} from "../../src/libraries/LaunchPresets.sol";

import {KitV2Fixture} from "./KitV2Fixture.sol";

/// @dev Refuses native value, to prove a hostile fee recipient cannot block launches.
contract NativeRefuser {
    receive() external payable {
        revert("no");
    }
}

/// @notice The launch fee (Kit v2 decision #1), the integrator fee, tenant configs, payouts, and ownership.
contract LaunchpadKitV2FeesTest is KitV2Fixture {
    function setUp() public {
        _deployAll();
    }

    function _p(string memory tag) internal view returns (LaunchParamsV2 memory) {
        return _oneCL(keccak256(bytes(tag)), address(quote));
    }

    /*//////////////////////////////////////////////////////////////
                             LAUNCH FEE: SET
    //////////////////////////////////////////////////////////////*/

    function test_FEE_initialValueAndImmutables() public view {
        assertEq(kit.launchFeeWei(), INITIAL_LAUNCH_FEE);
        assertEq(kit.maxLaunchFeeWei(), MAX_LAUNCH_FEE);
        assertEq(kit.launchFeeNoticeSeconds(), NOTICE);
        assertEq(kit.maxIntegratorLaunchFeeWei(), MAX_INTEGRATOR_FEE);
        assertEq(kit.protocolFeeRecipient(), safe);
        assertEq(kit.owner(), safe);
        (uint256 pending, uint64 at) = kit.pendingLaunchFee();
        assertEq(pending, 0);
        assertEq(at, 0);
    }

    /// @dev MUTATION-CHECKED: without the notice (effectiveAt = now) this test fails.
    function test_FEE_raiseWaitsForNoticeThenAppliesByItself() public {
        uint256 t0 = 1_000_000; // a literal: see test_FEE_replacingAPendingRaiseRestartsTheNotice
        vm.warp(t0);
        vm.expectEmit(address(kit));
        emit ILaunchpadKitV2.LaunchFeeIncreaseScheduled(INITIAL_LAUNCH_FEE, 0.005 ether, uint64(t0 + NOTICE));
        vm.prank(safe);
        kit.setLaunchFee(0.005 ether);

        (uint256 pending, uint64 at) = kit.pendingLaunchFee();
        assertEq(pending, 0.005 ether);
        assertEq(at, t0 + NOTICE);
        assertEq(kit.launchFeeWei(), INITIAL_LAUNCH_FEE, "not yet");

        // A launch one second before maturity pays the old fee...
        vm.warp(t0 + NOTICE - 1);
        _launchWithValue(_p("before"), INITIAL_LAUNCH_FEE);
        assertEq(kit.feesOwed(safe), INITIAL_LAUNCH_FEE);

        // ...and at maturity the new fee is in force without anybody applying it.
        vm.warp(t0 + NOTICE);
        assertEq(kit.launchFeeWei(), 0.005 ether);
        (pending, at) = kit.pendingLaunchFee();
        assertEq(at, 0, "matured: no longer pending");
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.InsufficientLaunchFee.selector, 0.005 ether, INITIAL_LAUNCH_FEE));
        this.launchAs(_p("under"), INITIAL_LAUNCH_FEE);
        _launchWithValue(_p("after"), 0.005 ether);
        assertEq(kit.feesOwed(safe), INITIAL_LAUNCH_FEE + 0.005 ether, "never retroactive");
    }

    function launchAs(LaunchParamsV2 memory p, uint256 value) external {
        vm.deal(LAUNCHER, LAUNCHER.balance + value);
        vm.prank(LAUNCHER);
        kit.createLaunch{value: value}(p);
    }

    function test_FEE_lowerIsImmediateAndCancelsPendingRaise() public {
        vm.startPrank(safe);
        kit.setLaunchFee(0.008 ether);
        vm.expectEmit(address(kit));
        emit ILaunchpadKitV2.PendingLaunchFeeCancelled(0.008 ether, uint64(block.timestamp + NOTICE));
        vm.expectEmit(address(kit));
        emit ILaunchpadKitV2.LaunchFeeChanged(INITIAL_LAUNCH_FEE, 0.0002 ether);
        kit.setLaunchFee(0.0002 ether);
        vm.stopPrank();
        assertEq(kit.launchFeeWei(), 0.0002 ether, "immediate");
        vm.warp(block.timestamp + NOTICE + 1);
        assertEq(kit.launchFeeWei(), 0.0002 ether, "the cancelled raise never lands");
    }

    function test_FEE_zeroIsAllowed() public {
        vm.prank(safe);
        kit.setLaunchFee(0);
        LaunchResultV2 memory r = _launchWithValue(_p("free"), 0);
        assertEq(r.protocolFeeWei, 0);
        assertEq(kit.feesOwed(safe), 0);
    }

    /// @dev MUTATION-CHECKED: removing the cap check makes this test fail.
    function test_FEE_capIsImmutableAndEnforced() public {
        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.LaunchFeeAboveCap.selector, MAX_LAUNCH_FEE + 1, MAX_LAUNCH_FEE));
        kit.setLaunchFee(MAX_LAUNCH_FEE + 1);
        kit.setLaunchFee(MAX_LAUNCH_FEE); // exactly the cap is fine
        vm.stopPrank();
        vm.warp(block.timestamp + NOTICE);
        assertEq(kit.launchFeeWei(), MAX_LAUNCH_FEE);
    }

    function test_FEE_replacingAPendingRaiseRestartsTheNotice() public {
        // A literal, not `block.timestamp`: via-IR may re-read TIMESTAMP at each use, after `vm.warp`.
        uint256 t0 = 1_000_000;
        vm.warp(t0);
        vm.prank(safe);
        kit.setLaunchFee(0.002 ether);
        vm.warp(t0 + NOTICE - 10);
        vm.prank(safe);
        kit.setLaunchFee(0.003 ether);
        vm.warp(t0 + NOTICE + 1);
        assertEq(kit.launchFeeWei(), INITIAL_LAUNCH_FEE, "the replacement cannot inherit the old clock");
        vm.warp(t0 + NOTICE - 10 + NOTICE);
        assertEq(kit.launchFeeWei(), 0.003 ether);
    }

    function test_FEE_cancelPending() public {
        vm.prank(safe);
        vm.expectRevert(ILaunchpadKitV2.NoPendingLaunchFee.selector);
        kit.cancelPendingLaunchFee();

        vm.prank(safe);
        kit.setLaunchFee(0.004 ether);
        vm.prank(safe);
        kit.cancelPendingLaunchFee();
        vm.warp(block.timestamp + NOTICE);
        assertEq(kit.launchFeeWei(), INITIAL_LAUNCH_FEE);
    }

    function test_FEE_maturedRaiseCannotBeCancelledRetroactively() public {
        vm.prank(safe);
        kit.setLaunchFee(0.004 ether);
        vm.warp(block.timestamp + NOTICE);
        vm.prank(safe);
        vm.expectRevert(ILaunchpadKitV2.NoPendingLaunchFee.selector);
        kit.cancelPendingLaunchFee();
        assertEq(kit.launchFeeWei(), 0.004 ether);
        // The owner lowers it the normal way, immediately.
        vm.prank(safe);
        kit.setLaunchFee(0.001 ether);
        assertEq(kit.launchFeeWei(), 0.001 ether);
    }

    /*//////////////////////////////////////////////////////////////
                         MSG.VALUE ACCOUNTING
    //////////////////////////////////////////////////////////////*/

    function test_VALUE_underpaymentReverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(ILaunchpadKitV2.InsufficientLaunchFee.selector, INITIAL_LAUNCH_FEE, INITIAL_LAUNCH_FEE - 1)
        );
        this.launchAs(_p("under"), INITIAL_LAUNCH_FEE - 1);
    }

    function test_VALUE_excessIsRefundedToTheLauncher() public {
        LaunchParamsV2 memory p = _p("over"); // built BEFORE the prank: it makes a view call
        vm.deal(LAUNCHER, 5 ether);
        vm.prank(LAUNCHER);
        kit.createLaunch{value: 1 ether}(p);
        assertEq(LAUNCHER.balance, 5 ether - INITIAL_LAUNCH_FEE, "paid exactly the fee");
        assertEq(address(kit).balance, INITIAL_LAUNCH_FEE);
        assertEq(kit.totalFeesOwed(), INITIAL_LAUNCH_FEE);
    }

    function test_VALUE_refundToAContractThatRefusesRevertsTheLaunch() public {
        // A launcher that cannot take its own refund must send the exact amount; nothing is stranded.
        NativeRefuser refuser = new NativeRefuser();
        vm.deal(address(refuser), 1 ether);
        LaunchParamsV2 memory p = _oneCL(keccak256("refuser"), address(quote));
        p.legs[0] = _clLeg(kit.predictLaunchToken(address(refuser), keccak256("refuser")), address(quote), 10_000);
        vm.prank(address(refuser));
        vm.expectRevert(
            abi.encodeWithSelector(ILaunchpadKitV2.NativeTransferFailed.selector, address(refuser), 1 ether - INITIAL_LAUNCH_FEE)
        );
        kit.createLaunch{value: 1 ether}(p);
        vm.prank(address(refuser));
        kit.createLaunch{value: INITIAL_LAUNCH_FEE}(p);
    }

    /*//////////////////////////////////////////////////////////////
                             INTEGRATOR FEE
    //////////////////////////////////////////////////////////////*/

    function test_INTEGRATOR_feeCreditedAndClaimable() public {
        LaunchParamsV2 memory p = _p("integrator");
        p.integratorLaunchFeeWei = 0.002 ether;
        LaunchResultV2 memory r = _launch(p);
        assertEq(r.integratorFeeWei, 0.002 ether);
        assertEq(kit.feesOwed(INTEGRATOR), 0.002 ether);
        assertEq(kit.totalFeesOwed(), INITIAL_LAUNCH_FEE + 0.002 ether);

        address payable to = payable(address(0xFEE));
        vm.prank(INTEGRATOR);
        assertEq(kit.claimFees(to), 0.002 ether);
        assertEq(to.balance, 0.002 ether);
        assertEq(kit.feesOwed(INTEGRATOR), 0);
        vm.prank(INTEGRATOR);
        vm.expectRevert(ILaunchpadKitV2.NothingToClaim.selector);
        kit.claimFees(to);
    }

    function test_INTEGRATOR_capEnforced() public {
        LaunchParamsV2 memory p = _p("integrator-cap");
        p.integratorLaunchFeeWei = MAX_INTEGRATOR_FEE + 1;
        vm.expectRevert(
            abi.encodeWithSelector(ILaunchpadKitV2.IntegratorFeeAboveCap.selector, MAX_INTEGRATOR_FEE + 1, MAX_INTEGRATOR_FEE)
        );
        this.launchAs(p, 1 ether);
    }

    function test_INTEGRATOR_feeNeedsARecipient() public {
        LaunchParamsV2 memory p = _p("integrator-none");
        p.integrator = address(0);
        p.integratorBps = 0;
        p.creatorBps = 8_000;
        p.integratorLaunchFeeWei = 1;
        vm.expectRevert(ILaunchpadKitV2.IntegratorFeeWithoutIntegrator.selector);
        this.launchAs(p, 1 ether);
    }

    function test_INTEGRATOR_aRecipientThatRefusesNativeCannotBlockLaunches() public {
        NativeRefuser refuser = new NativeRefuser();
        LaunchParamsV2 memory p = _p("hostile-integrator");
        p.integrator = address(refuser);
        p.integratorLaunchFeeWei = 0.001 ether;
        _launch(p); // pull-credited: the launch does not depend on the recipient
        assertEq(kit.feesOwed(address(refuser)), 0.001 ether);
    }

    function test_PAYOUT_flushProtocolFeesIsPermissionlessAndPaysOnlyTheSafe() public {
        _launch(_p("flush"));
        uint256 before = safe.balance;
        vm.prank(ATTACKER);
        assertEq(kit.flushProtocolFees(), INITIAL_LAUNCH_FEE);
        assertEq(safe.balance - before, INITIAL_LAUNCH_FEE);
        assertEq(ATTACKER.balance, 0);
        assertEq(kit.totalFeesOwed(), 0);
        vm.expectRevert(ILaunchpadKitV2.NothingToClaim.selector);
        kit.flushProtocolFees();
    }

    function test_PAYOUT_claimToZeroReverts() public {
        vm.expectRevert(ILaunchpadKitV2.ZeroAddress.selector);
        kit.claimFees(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                                 TENANTS
    //////////////////////////////////////////////////////////////*/

    address constant TENANT = address(0x7E4A);

    function _tenantConfig() internal pure returns (TenantConfig memory c) {
        c.integrator = INTEGRATOR;
        c.integratorBps = 1_000;
        c.integratorLaunchFeeWei = 0.001 ether;
        c.allowedPresets = uint8(1 << uint8(Preset.FairLaunch)) | uint8(1 << uint8(Preset.Custom));
        c.allowedBinShapes = uint8(1 << uint8(BinShape.Linear));
        c.restrictQuotes = true;
        c.active = true;
    }

    function _tenantParams(string memory tag) internal view returns (LaunchParamsV2 memory p) {
        p = _clAndBin(keccak256(bytes(tag)), address(quote));
        p.tenant = TENANT;
        p.integratorLaunchFeeWei = 0.001 ether;
    }

    function test_TENANT_happyPath() public {
        vm.startPrank(TENANT);
        kit.setTenantConfig(_tenantConfig());
        kit.setTenantQuote(address(quote), true);
        vm.stopPrank();
        LaunchResultV2 memory r = _launch(_tenantParams("tenant-ok"));
        assertEq(kit.getLaunch(r.token).tenant, TENANT);
        assertEq(kit.feesOwed(INTEGRATOR), 0.001 ether);
    }

    function test_TENANT_inactiveOrUnknownReverts() public {
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.TenantNotActive.selector, TENANT));
        this.launchAs(_tenantParams("tenant-none"), 1 ether);
    }

    function test_TENANT_valuesMustMatchTheStoredConfig() public {
        vm.startPrank(TENANT);
        kit.setTenantConfig(_tenantConfig());
        kit.setTenantQuote(address(quote), true);
        vm.stopPrank();
        LaunchParamsV2 memory p = _tenantParams("tenant-mismatch");
        p.integratorLaunchFeeWei = 0; // a launcher cannot drop the tenant's fee...
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.TenantConfigMismatch.selector, TENANT));
        this.launchAs(p, 1 ether);

        // ...and a tenant raising its fee cannot re-price a launch already signed.
        TenantConfig memory c = _tenantConfig();
        c.integratorLaunchFeeWei = 0.004 ether;
        vm.prank(TENANT);
        kit.setTenantConfig(c);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.TenantConfigMismatch.selector, TENANT));
        this.launchAs(_tenantParams("tenant-frontrun"), 1 ether);
    }

    function test_TENANT_presetShapeAndQuotePolicy() public {
        vm.prank(TENANT);
        kit.setTenantConfig(_tenantConfig());

        LaunchParamsV2 memory p = _tenantParams("tenant-quote");
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.QuoteNotAllowed.selector, TENANT, address(quote)));
        this.launchAs(p, 1 ether);
        vm.prank(TENANT);
        kit.setTenantQuote(address(quote), true);

        p = _tenantParams("tenant-preset");
        p.schedule.preset = Preset.Stealth;
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.PresetNotAllowed.selector, TENANT, Preset.Stealth));
        this.launchAs(p, 1 ether);

        p = _tenantParams("tenant-shape");
        p.legs[1].bin.shape = BinShape.Exponential;
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.BinShapeNotAllowed.selector, TENANT, BinShape.Exponential));
        this.launchAs(p, 1 ether);
    }

    function test_TENANT_configValidation() public {
        TenantConfig memory c = _tenantConfig();
        c.integratorLaunchFeeWei = uint96(MAX_INTEGRATOR_FEE + 1);
        vm.expectRevert(ILaunchpadKitV2.InvalidTenantConfig.selector);
        kit.setTenantConfig(c);

        c = _tenantConfig();
        c.integratorBps = 2_001; // above the lockers' integrator cap
        vm.expectRevert(ILaunchpadKitV2.InvalidTenantConfig.selector);
        kit.setTenantConfig(c);

        c = _tenantConfig();
        c.integrator = address(0);
        vm.expectRevert(ILaunchpadKitV2.InvalidTenantConfig.selector);
        kit.setTenantConfig(c);

        c = _tenantConfig();
        c.allowedPresets = 0;
        vm.expectRevert(ILaunchpadKitV2.InvalidTenantConfig.selector);
        kit.setTenantConfig(c);
    }

    function test_TENANT_onlyTheTenantWritesItsConfig() public {
        vm.prank(TENANT);
        kit.setTenantConfig(_tenantConfig());
        // The kit owner has no route to a tenant's config: writing always targets msg.sender.
        TenantConfig memory c = _tenantConfig();
        c.integrator = ATTACKER;
        vm.prank(safe);
        kit.setTenantConfig(c);
        assertEq(kit.tenantConfig(TENANT).integrator, INTEGRATOR);
        assertEq(kit.tenantConfig(safe).integrator, ATTACKER);
    }

    /*//////////////////////////////////////////////////////////////
                         OWNERSHIP AND ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_ACCESS_everyOwnerFunctionRejectsStrangers() public {
        address[3] memory strangers = [ATTACKER, LAUNCHER, INTEGRATOR];
        for (uint256 i; i < strangers.length; ++i) {
            vm.startPrank(strangers[i]);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, strangers[i]));
            kit.setLaunchFee(0);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, strangers[i]));
            kit.cancelPendingLaunchFee();
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, strangers[i]));
            kit.transferOwnership(strangers[i]);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, strangers[i]));
            kit.acceptOwnership();
            vm.stopPrank();
        }
    }

    function test_ACCESS_renounceAlwaysReverts() public {
        vm.prank(safe);
        vm.expectRevert(ILaunchpadKitV2.RenounceDisabled.selector);
        kit.renounceOwnership();
        vm.prank(ATTACKER);
        vm.expectRevert(ILaunchpadKitV2.RenounceDisabled.selector);
        kit.renounceOwnership();
        assertEq(kit.owner(), safe);
    }

    function test_ACCESS_ownable2Step() public {
        address next = address(0x5AFE2);
        vm.prank(safe);
        kit.transferOwnership(next);
        assertEq(kit.owner(), safe, "nominated, not transferred");
        assertEq(kit.pendingOwner(), next);
        vm.prank(next);
        kit.acceptOwnership();
        assertEq(kit.owner(), next);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, safe));
        kit.setLaunchFee(0);
    }

    /// @dev The owner has exactly the fee. It cannot reach a launch, a flag, a tenant, fees owed to others, or
    /// a listing's steward.
    function test_ACCESS_ownerHasNoOtherPower() public {
        LaunchParamsV2 memory p = _clAndBin(keccak256("owner-scope"), address(quote));
        p.integratorLaunchFeeWei = 0.001 ether;
        LaunchResultV2 memory r = _launch(p);
        PoolKey[] memory keys = new PoolKey[](2);
        (keys[0],,) = kit.computeLegKey(r.token, p.legs[0]);
        (keys[1],,) = kit.computeLegKey(r.token, p.legs[1]);

        vm.startPrank(safe);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.NotLaunchOperator.selector, r.token, safe));
        kit.reconfigureLaunch(r.token, keys, p.schedule, _noTax());
        // Claiming pays the CALLER's own balance only. The Safe's is the protocol fee, nothing more.
        uint256 got = kit.claimFees(safe);
        assertEq(got, INITIAL_LAUNCH_FEE);
        assertEq(kit.feesOwed(INTEGRATOR), 0.001 ether, "integrator balance untouched");
        LaunchpadMetadata memory m;
        m.name = "owner";
        kit.registerLaunchpad(m);
        vm.stopPrank();
        assertEq(launchRegistry.getLaunchpad(address(kit)).steward, LAUNCHPAD_STEWARD);
        assertTrue(kit.isLockedLaunch(r.poolIds[0]));
    }

    /* ---- acceptance finding A, 2026-09-18: a misdirected ERC-20 has an owner-only path out ---- */

    function test_FIX_rescueERC20_ownerOnly_nothingToRescue_happyPath() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);

        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.NothingToRescue.selector, address(stray)));
        kit.rescueERC20(address(stray), safe);

        stray.mint(address(kit), 5e18);

        address[3] memory strangers = [ATTACKER, LAUNCHER, INTEGRATOR];
        for (uint256 i; i < strangers.length; ++i) {
            vm.prank(strangers[i]);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, strangers[i]));
            kit.rescueERC20(address(stray), strangers[i]);
        }
        vm.prank(safe);
        vm.expectRevert(ILaunchpadKitV2.RescueToZero.selector);
        kit.rescueERC20(address(stray), address(0));

        vm.prank(safe);
        vm.expectEmit(true, true, false, true, address(kit));
        emit ILaunchpadKitV2.ERC20Rescued(address(stray), address(0xBEEF), 5e18);
        kit.rescueERC20(address(stray), address(0xBEEF));
        assertEq(stray.balanceOf(address(0xBEEF)), 5e18);
        assertEq(stray.balanceOf(address(kit)), 0);
    }

    /// The rescue cannot reach fee credit: it is native, accounted per address, never an ERC-20 balance.
    function test_FIX_rescueERC20_cannotTouchNativeFeeCredit() public {
        uint256 before = address(kit).balance;
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        stray.mint(address(kit), 1);
        vm.prank(safe);
        kit.rescueERC20(address(stray), safe);
        assertEq(address(kit).balance, before);
    }
}
