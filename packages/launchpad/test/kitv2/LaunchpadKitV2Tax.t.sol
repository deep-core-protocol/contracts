// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

import {LaunchGuardHook, ILaunchTokenOrigin} from "deepcore-hooks/src/launch/LaunchGuardHook.sol";
import {BinLaunchGuardHook} from "deepcore-hooks/src/launch/BinLaunchGuardHook.sol";
import {LaunchTaxModule} from "deepcore-hooks/src/launch/LaunchTaxModule.sol";
import {IDeepCoreBinLPLocker} from "../../src/interfaces/IDeepCoreBinLPLocker.sol";

import {LaunchpadKitV2} from "../../src/LaunchpadKitV2.sol";
import {
    ILaunchpadKitV2, LaunchParamsV2, LaunchResultV2, ScheduleParams, TaxParams, TenantConfig, BinShape
} from "../../src/interfaces/ILaunchpadKitV2.sol";
import {Preset} from "../../src/libraries/LaunchPresets.sol";
import {KitV2Fixture} from "./KitV2Fixture.sol";

/// @title LaunchpadKitV2Tax
/// @notice The creator tax through the kit: pass-through to both guards, recipients resolved, tenant
/// policy applied, the floor enforced by the GUARD and surfaced through the kit, reconfiguration, and the
/// money path exercised end to end (swap -> pot -> settle -> claim) on a CL and a Bin leg.
contract LaunchpadKitV2TaxTest is KitV2Fixture {
    address constant TENANT = address(0x7E4A);

    function setUp() public {
        _deployAll();
    }

    function _tax() internal pure returns (TaxParams memory t) {
        t.buyBps = 500;
        t.sellBps = 300;
        t.taxSeconds = 1 days;
        t.creatorBps = 7_000;
        t.protocolBps = 1_000;
        t.integratorBps = 2_000;
    }

    function _taxed(string memory tag) internal view returns (LaunchParamsV2 memory p) {
        p = _clAndBin(keccak256(bytes(tag)), address(quote));
        p.tax = _tax();
    }

    function launchAs(LaunchParamsV2 memory p, uint256 value) external {
        _launchWithValue(p, value);
    }

    function _assertSolvent(LaunchTaxModule hook, Currency c) internal view {
        assertGe(hook.backing(c), hook.totalOwed(c), "backing < totalOwed");
    }

    /*//////////////////////////////////////////////////////////////
                              PASS-THROUGH
    //////////////////////////////////////////////////////////////*/

    function test_TAX_keysCarryTheTaxBitmaps() public view {
        assertEq(kit.CL_HOOK_BITMAP(), 0x0CC1);
        assertEq(kit.BIN_HOOK_BITMAP(), 0x0CC5);
        assertEq(clHook.getHooksRegistrationBitmap(), 0x0CC1);
        assertEq(binHook.getHooksRegistrationBitmap(), 0x0CC5);
        assertEq(kit.maxTaxBps(), clHook.MAX_TAX_BPS());
        assertEq(kit.maxTaxIntegratorBps(), clHook.MAX_INTEGRATOR_BPS());
        assertEq(clHook.protocolRecipient(), safe);
        assertEq(binHook.protocolRecipient(), safe);
    }

    function test_TAX_directLaunchConfiguresEveryLegWithResolvedRecipients() public {
        LaunchParamsV2 memory p = _taxed("tax-direct");
        LaunchResultV2 memory r = _launch(p);

        LaunchTaxModule.Tax memory cl = clHook.getTax(PoolId.wrap(r.poolIds[0]));
        LaunchTaxModule.Tax memory bn = binHook.getTax(PoolId.wrap(r.poolIds[1]));
        assertEq(cl.buyBps, 500);
        assertEq(cl.sellBps, 300);
        assertEq(cl.expiresAt, uint40(r.startTime + 1 days), "expiry counts from trading open");
        assertEq(cl.creator, CREATOR, "creator bucket pays the launch creator");
        assertEq(cl.integrator, INTEGRATOR, "integrator bucket pays the tenant wallet");
        assertEq(cl.creatorBps, 7_000);
        assertEq(cl.protocolBps, 1_000);
        assertEq(cl.integratorBps, 2_000);
        assertEq(bn.buyBps, 500);
        assertEq(bn.expiresAt, cl.expiresAt, "every leg carries one expiry");
        assertEq(bn.creator, CREATOR);
        assertEq(bn.integrator, INTEGRATOR);
        assertEq(kit.getLaunch(r.token).integrator, INTEGRATOR, "recorded for reconfiguration");
    }

    /// @dev Found by the live bar: a launch that opens at once (`startDelaySeconds = 0`) claims and taxes in the
    /// second trading opens, so the tax freeze must be `>` (nobody can have traded inside the launch transaction).
    function test_TAX_launchThatOpensImmediatelyCarriesATax() public {
        LaunchParamsV2 memory p = _taxed("tax-now");
        p.schedule.startDelaySeconds = 0;
        LaunchResultV2 memory r = _launch(p);
        assertEq(r.startTime, uint40(vm.getBlockTimestamp()));
        assertEq(clHook.getTax(PoolId.wrap(r.poolIds[0])).buyBps, 500);
        assertEq(binHook.getTax(PoolId.wrap(r.poolIds[1])).buyBps, 500);
        // and it is frozen at once: the operator cannot restate it in a later block
        PoolKey[] memory keys = new PoolKey[](2);
        (keys[0],,) = kit.computeLegKey(r.token, p.legs[0]);
        (keys[1],,) = kit.computeLegKey(r.token, p.legs[1]);
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.prank(OPERATOR);
        vm.expectRevert();
        kit.reconfigureLaunch(r.token, keys, p.schedule, _noTax());
    }

    function test_TAX_zeroBlockMeansNoTaxAndNoDelta() public {
        LaunchParamsV2 memory p = _clAndBin(keccak256("no-tax"), address(quote));
        LaunchResultV2 memory r = _launch(p);
        assertEq(clHook.getTax(PoolId.wrap(r.poolIds[0])).expiresAt, 0);
        assertEq(binHook.getTax(PoolId.wrap(r.poolIds[1])).expiresAt, 0);

        vm.warp(r.startTime + 400);
        quote.mint(address(this), 10 ether);
        _buyCL(_clKey(r.token, p.legs[0]), r.token, 1 ether);
        assertEq(clHook.pendingTax(PoolId.wrap(r.poolIds[0]), Currency.wrap(r.token)), 0);
        assertEq(clHook.totalOwed(Currency.wrap(r.token)), 0);
    }

    /// @dev A consequence of the caps (protocol <= 50%, integrator <= 20%): the creator keeps at least 30% of
    /// any tax. A launch that wants the creator to take nothing simply carries no tax.
    function test_TAX_creatorBucketIsAtLeastThirtyPercentByTheCaps() public {
        LaunchParamsV2 memory p = _taxed("tax-min-creator");
        p.tax.creatorBps = 3_000;
        p.tax.protocolBps = 5_000;
        p.tax.integratorBps = 2_000;
        LaunchResultV2 memory r = _launch(p);
        LaunchTaxModule.Tax memory cl = clHook.getTax(PoolId.wrap(r.poolIds[0]));
        assertEq(cl.creatorBps, 3_000);
        assertEq(cl.protocolBps, 5_000);
        p = _taxed("tax-zero-creator");
        p.tax.creatorBps = 0;
        p.tax.protocolBps = 8_000;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxProtocolShareOutOfBounds.selector, uint16(8_000)));
        this.launchAs(p, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                    THE GUARD'S RULES, THROUGH THE KIT
    //////////////////////////////////////////////////////////////*/

    function test_TAX_floorIsTheGuardsAndTheKitOnlyRelaysIt() public {
        LaunchParamsV2 memory p = _taxed("tax-floor");
        p.tax.protocolBps = 999;
        p.tax.creatorBps = 7_001;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxProtocolShareOutOfBounds.selector, uint16(999)));
        this.launchAs(p, 1 ether);
    }

    function test_TAX_rateCapExpiryCapAndSplitSum() public {
        LaunchParamsV2 memory p = _taxed("tax-rate");
        p.tax.buyBps = 1_001;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxRateTooHigh.selector, uint16(1_001)));
        this.launchAs(p, 1 ether);

        p = _taxed("tax-expiry");
        p.tax.taxSeconds = 180 days; // + the 120 s start delay: past the ceiling
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchTaxModule.TaxExpiryOutOfRange.selector, uint40(block.timestamp + 120 + 180 days), block.timestamp
            )
        );
        this.launchAs(p, 1 ether);

        p = _taxed("tax-sum");
        p.tax.creatorBps = 6_999;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxSplitDoesNotSum.selector, uint256(9_999)));
        this.launchAs(p, 1 ether);

        p = _taxed("tax-integrator-cap");
        p.tax.integratorBps = 2_001;
        p.tax.creatorBps = 6_999;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxIntegratorShareTooHigh.selector, uint16(2_001)));
        this.launchAs(p, 1 ether);
    }

    function test_TAX_integratorBucketNeedsAnIntegrator() public {
        LaunchParamsV2 memory p = _taxed("tax-no-integrator");
        p.integrator = address(0);
        p.integratorBps = 0;
        p.creatorBps = 8_000; // the LP split still sums
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxRecipientMismatch.selector, address(0), uint16(2_000)));
        this.launchAs(p, 1 ether);
    }

    function test_TAX_partialZeroBlockIsRefused() public {
        LaunchParamsV2 memory p = _taxed("tax-partial");
        p.tax.buyBps = 0;
        p.tax.sellBps = 0;
        vm.expectRevert(LaunchTaxModule.TaxWithoutRate.selector);
        this.launchAs(p, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                               TENANTS
    //////////////////////////////////////////////////////////////*/

    function _tenantConfig(uint16 maxTaxBps, uint16 taxIntegratorBps) internal pure returns (TenantConfig memory c) {
        c.integrator = INTEGRATOR;
        c.integratorBps = 1_000;
        c.integratorLaunchFeeWei = 0;
        c.allowedPresets = uint8(1 << uint8(Preset.FairLaunch));
        c.allowedBinShapes = uint8(1 << uint8(BinShape.Linear));
        c.active = true;
        c.maxTaxBps = maxTaxBps;
        c.taxIntegratorBps = taxIntegratorBps;
    }

    function _tenantTaxed(string memory tag) internal view returns (LaunchParamsV2 memory p) {
        p = _taxed(tag);
        p.tenant = TENANT;
    }

    function test_TENANT_capsTheRatesAndForcesItsIntegratorShare() public {
        vm.prank(TENANT);
        kit.setTenantConfig(_tenantConfig(300, 1_500));

        LaunchParamsV2 memory p = _tenantTaxed("tenant-rate");
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.TaxNotAllowed.selector, TENANT, uint16(500)));
        this.launchAs(p, 1 ether);

        p = _tenantTaxed("tenant-share");
        p.tax.buyBps = 300;
        p.tax.sellBps = 200;
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.TaxNotAllowed.selector, TENANT, uint16(2_000)));
        this.launchAs(p, 1 ether);

        p.tax.integratorBps = 1_500;
        p.tax.creatorBps = 7_500;
        LaunchResultV2 memory r = _launch(p);
        LaunchTaxModule.Tax memory cl = clHook.getTax(PoolId.wrap(r.poolIds[0]));
        assertEq(cl.integratorBps, 1_500);
        assertEq(cl.integrator, INTEGRATOR);
        assertEq(cl.buyBps, 300);
    }

    function test_TENANT_zeroCapForbidsATaxButNotAnUntaxedLaunch() public {
        vm.prank(TENANT);
        kit.setTenantConfig(_tenantConfig(0, 0));
        LaunchParamsV2 memory p = _tenantTaxed("tenant-forbid");
        p.tax.integratorBps = 0;
        p.tax.creatorBps = 9_000;
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.TaxNotAllowed.selector, TENANT, uint16(500)));
        this.launchAs(p, 1 ether);
        p.tax = _noTax();
        _launch(p);
    }

    function test_TENANT_configBounds() public {
        TenantConfig memory c = _tenantConfig(1_001, 0);
        vm.prank(TENANT);
        vm.expectRevert(ILaunchpadKitV2.InvalidTenantConfig.selector);
        kit.setTenantConfig(c);
        c = _tenantConfig(1_000, 2_001);
        vm.prank(TENANT);
        vm.expectRevert(ILaunchpadKitV2.InvalidTenantConfig.selector);
        kit.setTenantConfig(c);
        c = _tenantConfig(1_000, 100);
        c.integrator = address(0);
        c.integratorBps = 0;
        vm.prank(TENANT);
        vm.expectRevert(ILaunchpadKitV2.InvalidTenantConfig.selector);
        kit.setTenantConfig(c);
        c = _tenantConfig(1_000, 2_000);
        vm.prank(TENANT);
        kit.setTenantConfig(c);
        assertEq(kit.tenantConfig(TENANT).maxTaxBps, 1_000);
        assertEq(kit.tenantConfig(TENANT).taxIntegratorBps, 2_000);
    }

    /*//////////////////////////////////////////////////////////////
                            RECONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function test_TAX_reconfigureRestatesMovesOrClearsTheTax() public {
        LaunchParamsV2 memory p = _taxed("tax-reconf");
        LaunchResultV2 memory r = _launch(p);
        PoolKey[] memory keys = new PoolKey[](2);
        (keys[0],,) = kit.computeLegKey(r.token, p.legs[0]);
        (keys[1],,) = kit.computeLegKey(r.token, p.legs[1]);

        ScheduleParams memory s = p.schedule;
        s.startDelaySeconds = 3_600;
        TaxParams memory t = _tax();
        t.buyBps = 100;
        t.taxSeconds = 2 days;

        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.NotLaunchOperator.selector, r.token, ATTACKER));
        kit.reconfigureLaunch(r.token, keys, s, t);

        vm.prank(OPERATOR);
        kit.reconfigureLaunch(r.token, keys, s, t);
        LaunchTaxModule.Tax memory cl = clHook.getTax(PoolId.wrap(r.poolIds[0]));
        assertEq(cl.buyBps, 100);
        assertEq(cl.expiresAt, uint40(block.timestamp + 3_600 + 2 days), "expiry follows the new start");
        assertEq(cl.creator, CREATOR);
        assertEq(cl.integrator, INTEGRATOR, "the recorded integrator is restated");
        assertEq(binHook.getTax(PoolId.wrap(r.poolIds[1])).buyBps, 100);

        // The floor holds on reconfiguration too.
        t.protocolBps = 999;
        t.creatorBps = 7_001;
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxProtocolShareOutOfBounds.selector, uint16(999)));
        kit.reconfigureLaunch(r.token, keys, s, t);

        // An all-zero block clears it.
        vm.prank(OPERATOR);
        kit.reconfigureLaunch(r.token, keys, s, _noTax());
        assertEq(clHook.getTax(PoolId.wrap(r.poolIds[0])).expiresAt, 0);
        assertEq(binHook.getTax(PoolId.wrap(r.poolIds[1])).expiresAt, 0);

        // Frozen from startTime, by the guards: the tax cannot be re-added on buyers who committed.
        vm.warp(kit.getLaunch(r.token).startTime);
        vm.prank(OPERATOR);
        vm.expectRevert();
        kit.reconfigureLaunch(r.token, keys, s, _tax());
    }

    /*//////////////////////////////////////////////////////////////
                             THE MONEY PATH
    //////////////////////////////////////////////////////////////*/

    function test_TAX_clLegSwapPotSettleClaim() public {
        LaunchParamsV2 memory p = _taxed("tax-cl-money");
        LaunchResultV2 memory r = _launch(p);
        PoolId id = PoolId.wrap(r.poolIds[0]);
        Currency token = Currency.wrap(r.token);
        Currency q = Currency.wrap(address(quote));
        vm.warp(r.startTime + 400); // FairLaunch decay (300 s) over

        quote.mint(address(this), 10 ether);
        _buyCL(_clKey(r.token, p.legs[0]), r.token, 1 ether);
        uint256 pot = clHook.pendingTax(id, q);
        // An exact-input buy pays the tax in the QUOTE, on what it sends: 5% of 1 ether, to the wei.
        assertEq(pot, uint256(1 ether) * 500 / 10_000, "a buy paid the tax in the quote");
        assertEq(clHook.pendingTax(id, token), 0, "never in the launch token");
        assertEq(clHook.backing(token), 0, "the guard holds no launch token");
        _assertSolvent(clHook, q);

        clHook.settleTax(id, q);
        uint256 toCreator = pot * 7_000 / 10_000;
        uint256 toIntegrator = pot * 2_000 / 10_000;
        assertEq(clHook.claimable(CREATOR, q), toCreator);
        assertEq(clHook.claimable(INTEGRATOR, q), toIntegrator);
        assertEq(clHook.claimable(safe, q), pot - toCreator - toIntegrator, "the Safe is the protocol bucket");

        uint256 before = quote.balanceOf(CREATOR);
        vm.prank(CREATOR);
        assertEq(clHook.claim(q, CREATOR), toCreator);
        assertEq(quote.balanceOf(CREATOR) - before, toCreator);
        vm.prank(INTEGRATOR);
        clHook.claim(q, INTEGRATOR);
        vm.prank(safe);
        clHook.claim(q, safe);
        // Every tax bucket is paid out; what the guard still owes in the quote is the fee pot.
        assertEq(clHook.totalOwed(q), clHook.pendingFee(id, q));
        _assertSolvent(clHook, q);

        // Expired: no tax, no pot growth, no transaction needed. The fee goes on.
        vm.warp(r.startTime + 1 days);
        uint256 feeBefore = clHook.pendingFee(id, q);
        _buyCL(_clKey(r.token, p.legs[0]), r.token, 1 ether);
        assertEq(clHook.pendingTax(id, q), 0);
        assertGt(clHook.pendingFee(id, q), feeBefore, "the fee outlives the tax");
        (uint16 b, uint16 sl) = clHook.currentTaxRates(id);
        assertEq(b + sl, 0);
    }

    function test_TAX_binLegSwapPotSettleClaim_andTheLockerHasNothingToCollect() public {
        LaunchParamsV2 memory p = _taxed("tax-bin-money");
        LaunchResultV2 memory r = _launch(p);
        PoolId id = PoolId.wrap(r.poolIds[1]);
        Currency token = Currency.wrap(r.token);
        Currency q = Currency.wrap(address(quote));
        vm.warp(r.startTime + 400);

        quote.mint(address(this), 10 ether);
        (PoolKey memory key,,) = kit.computeLegKey(r.token, p.legs[1]);
        _buyBin(key, r.token, 1 ether);
        uint256 pot = binHook.pendingTax(id, q);
        assertEq(pot, uint256(1 ether) * 500 / 10_000, "a buy paid the tax in the quote");
        assertEq(binHook.pendingTax(id, token), 0, "never in the launch token");
        uint256 feePot = binHook.pendingFee(id, q);
        assertGt(feePot, 0, "and the fee, in the quote as well");
        _assertSolvent(binHook, q);

        // The pool's own LP fee is zero on a swap, so the locked bins have earned nothing.
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.NothingToCollect.selector, r.lockIds[1]));
        binLocker.collectFees(r.lockIds[1]);

        // `claimFrom` settles both pots: the creator's 70% of the tax and its share of the fee.
        PoolId[] memory ids = new PoolId[](1);
        ids[0] = id;
        uint256 before = quote.balanceOf(CREATOR);
        vm.prank(CREATOR);
        uint256 got = binHook.claimFrom(ids, q, CREATOR);
        assertEq(got, pot * 7_000 / 10_000 + feePot * binHook.getFeeSplit(id).creatorBps / 10_000);
        assertEq(quote.balanceOf(CREATOR) - before, got);
        _assertSolvent(binHook, q);
    }

    function test_TAX_nativeQuoteLegPaysNativeOnBuysAndSells() public {
        LaunchParamsV2 memory p = _oneCL(keccak256("tax-native"), address(0));
        p.tax = _tax();
        LaunchResultV2 memory r = _launch(p);
        PoolId id = PoolId.wrap(r.poolIds[0]);
        vm.warp(r.startTime + 400);
        vm.deal(address(this), 10 ether);
        PoolKey memory key = _clKey(r.token, p.legs[0]);
        _buyCL(key, r.token, 1 ether); // exact-in buy: taxed in NATIVE, on what it sends
        assertEq(clHook.pendingTax(id, Currency.wrap(address(0))), uint256(1 ether) * 500 / 10_000);
        assertEq(clHook.pendingTax(id, Currency.wrap(r.token)), 0, "never in the launch token");
        uint256 afterBuy = clHook.pendingTax(id, Currency.wrap(address(0)));
        // Sell some of it back: the unspecified side is NATIVE out.
        MockERC20(r.token).approve(address(clRouter), type(uint256).max);
        bool launchIs0 = Currency.unwrap(key.currency0) == r.token;
        clRouter.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: launchIs0,
                amountSpecified: -int256(MockERC20(r.token).balanceOf(address(this)) / 2),
                sqrtPriceLimitX96: launchIs0 ? 4295128740 : 1461446703485210103287273052203988822378723970341
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
        uint256 nativePot = clHook.pendingTax(id, Currency.wrap(address(0)));
        assertGt(nativePot, afterBuy, "a sell paid the tax in native");
        assertEq(clHook.pendingTax(id, Currency.wrap(r.token)), 0, "never in the launch token");
        clHook.settleTax(id, Currency.wrap(address(0)));
        uint256 before = CREATOR.balance;
        vm.prank(CREATOR);
        clHook.claim(Currency.wrap(address(0)), CREATOR);
        assertEq(CREATOR.balance - before, nativePot * 7_000 / 10_000);
        _assertSolvent(clHook, Currency.wrap(address(0)));
    }

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTION
    //////////////////////////////////////////////////////////////*/

    function test_TAX_kitRefusesAGuardPayingSomebodyElse() public {
        LaunchpadKitV2.Deployment memory d = _deployment();
        d.clHook = new LaunchGuardHook(ICLPoolManager(address(clPM)), ILaunchTokenOrigin(address(factory)), ATTACKER, 0);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.HookTaxMismatch.selector, address(d.binHook)));
        new LaunchpadKitV2(d);
        d = _deployment();
        d.binHook = new BinLaunchGuardHook(IBinPoolManager(address(binPM)), ILaunchTokenOrigin(address(factory)), ATTACKER, 0);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.HookTaxMismatch.selector, address(d.binHook)));
        new LaunchpadKitV2(d);
    }
}
