// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {LaunchGuardHook} from "deepcore-hooks/src/launch/LaunchGuardHook.sol";
import {BinLaunchGuardHook} from "deepcore-hooks/src/launch/BinLaunchGuardHook.sol";
import {
    ILaunchpadKitV2,
    LegKind,
    BinShape,
    LegParams,
    ScheduleParams,
    TaxParams,
    LaunchParamsV2,
    LaunchResultV2,
    LaunchRecordV2
} from "deepcore-launchpad/src/interfaces/ILaunchpadKitV2.sol";
import {Preset} from "deepcore-launchpad/src/libraries/LaunchPresets.sol";
import {LaunchRecord} from "deepcore-registry/src/IDeepCoreLaunchRegistry.sol";

import {DeepCoreLaunchAndBuy} from "../src/DeepCoreLaunchAndBuy.sol";
import {ILaunchGuardFee} from "../src/interfaces/ILaunchGuardFee.sol";
import {LaunchAndBuyFixture} from "./LaunchAndBuyFixture.sol";
import {
    ReentrantQuoteToken,
    MidLockQuoteToken,
    FeeOnTransferQuoteToken,
    NativeRefuser,
    Forcer
} from "./mocks/Mocks.sol";

contract DeepCoreLaunchAndBuyTest is LaunchAndBuyFixture {
    /*//////////////////////////////////////////////////////////////
       THE PREMISE: the design works without touching kit or guards
    //////////////////////////////////////////////////////////////*/

    /// @notice `_validateConfig` rejects only `startTime < block.timestamp`, so "open now" is legal.
    /// A mutant that made it `<=` fails this, and with it every happy path in this file.
    function test_PREMISE_startTimeMayBeNow() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("premise"), address(quoteToken));
        assertEq(p.schedule.startDelaySeconds, 0, "fixture must use a zero delay");

        vm.prank(CREATOR);
        (LaunchResultV2 memory r,,,) = lab.launchAndBuy{value: _kitFee(p)}(p, _buy(1 ether));

        assertEq(uint256(r.startTime), block.timestamp, "startTime is now");
    }

    /// @notice `_beforeSwap` reverts only on `block.timestamp < startTime`, so a swap AT `startTime`
    /// goes through - which is the whole reason one transaction can both open and buy.
    function test_PREMISE_swapAtStartTimeIsPermitted() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("premise2"), address(quoteToken));

        vm.prank(CREATOR);
        (LaunchResultV2 memory r,, uint256 bought,) = lab.launchAndBuy{value: _kitFee(p)}(p, _buy(1 ether));

        LaunchGuardHook.Launch memory l = clHook.getLaunch(PoolId.wrap(r.poolIds[0]));
        assertTrue(l.launched, "the swap landed at startTime and set `launched`");
        assertGt(bought, 0, "and it filled");
    }

    /// @notice The kit, the guards and the lockers are reached only through their public ABI: nothing
    /// in this package is a privileged caller anywhere. The proof that matters is negative - this
    /// contract holds no role on any of them.
    function test_PREMISE_contractHoldsNoRoleAnywhere() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("roles"), address(quoteToken));
        vm.prank(CREATOR);
        (LaunchResultV2 memory r,,,) = lab.launchAndBuy{value: _kitFee(p)}(p, _buy(1 ether));

        // The launch owner on the guard is the KIT, exactly as for a direct launch.
        assertEq(clHook.launchOwner(PoolId.wrap(r.poolIds[0])), address(kit), "guard owner is the kit");
        // Nothing about the launch names this contract.
        LaunchRecordV2 memory rec = kit.getLaunch(r.token);
        assertTrue(rec.creator != address(lab) && rec.operator != address(lab), "never creator or operator");
        assertEq(kit.feesOwed(address(lab)), 0, "no fee credit owed to this contract");
    }

    /*//////////////////////////////////////////////////////////////
                              HAPPY PATHS
    //////////////////////////////////////////////////////////////*/

    function test_HAPPY_nativeQuoteCLBuy() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("native"), address(0));
        uint256 fee = _kitFee(p);
        uint256 amountIn = 3 ether;

        uint256 balBefore = CREATOR.balance;
        vm.prank(CREATOR);
        (LaunchResultV2 memory r, uint256 spent, uint256 bought, uint24 pips) =
            lab.launchAndBuy{value: fee + amountIn}(p, _buy(amountIn));

        assertEq(pips, 100_000, "FairLaunch opens at 10%");
        assertEq(spent, amountIn, "a 3 ether buy fits inside the range");
        assertGt(bought, 0);
        assertEq(IERC20(r.token).balanceOf(CREATOR), bought, "the creator holds exactly what was bought");
        assertEq(balBefore - CREATOR.balance, fee + amountIn, "paid the fee and the buy, nothing else");
        assertEq(address(lab).balance, 0, "the contract kept nothing");
    }

    function test_HAPPY_erc20QuoteCLBuy() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("erc20"), address(quoteToken));
        uint256 fee = _kitFee(p);
        uint256 amountIn = 5 ether;

        uint256 quoteBefore = quoteToken.balanceOf(CREATOR);
        vm.prank(CREATOR);
        (LaunchResultV2 memory r, uint256 spent, uint256 bought,) = lab.launchAndBuy{value: fee}(p, _buy(amountIn));

        assertEq(spent, amountIn);
        assertEq(quoteBefore - quoteToken.balanceOf(CREATOR), amountIn, "only the buy left the creator");
        assertEq(IERC20(r.token).balanceOf(CREATOR), bought);
        assertEq(quoteToken.balanceOf(address(lab)), 0, "the contract kept no quote");
    }

    function test_HAPPY_binLegBuy() public {
        LaunchParamsV2 memory p = _oneBin(address(quoteToken));
        p.legs[0] = _binLeg(address(quoteToken), 10_000, BinShape.Linear, 10);

        vm.prank(CREATOR);
        (LaunchResultV2 memory r, uint256 spent, uint256 bought, uint24 pips) =
            lab.launchAndBuy{value: _kitFee(p)}(p, _buy(1 ether));

        assertEq(pips, 100_000, "the Bin guard opens at the same 10%");
        assertGt(spent, 0);
        assertEq(IERC20(r.token).balanceOf(CREATOR), bought);
        BinLaunchGuardHook.Launch memory l = binHook.getLaunch(PoolId.wrap(r.poolIds[0]));
        assertTrue(l.launched, "the Bin pool is launched");
    }

    function test_HAPPY_multiLegBuysOnlyTheChosenLeg() public {
        LaunchParamsV2 memory p = _clAndBin(CREATOR, bytes32("multi"), address(quoteToken));
        DeepCoreLaunchAndBuy.BuyParams memory b = _buy(2 ether);
        b.legIndex = 1; // the Bin leg

        vm.prank(CREATOR);
        (LaunchResultV2 memory r,, uint256 bought,) = lab.launchAndBuy{value: _kitFee(p)}(p, b);

        assertGt(bought, 0);
        assertTrue(binHook.getLaunch(PoolId.wrap(r.poolIds[1])).launched, "the Bin leg traded");
        assertFalse(clHook.getLaunch(PoolId.wrap(r.poolIds[0])).launched, "the CL leg did not");
    }

    function test_HAPPY_recipientOverride() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("recip"), address(quoteToken));
        DeepCoreLaunchAndBuy.BuyParams memory b = _buy(1 ether);
        b.recipient = STEWARD; // an address with no other claim on this launch

        vm.prank(CREATOR);
        (LaunchResultV2 memory r,, uint256 bought,) = lab.launchAndBuy{value: _kitFee(p)}(p, b);

        assertEq(IERC20(r.token).balanceOf(STEWARD), bought, "the named recipient got them");
        assertEq(IERC20(r.token).balanceOf(CREATOR), 0, "the caller got none");
    }

    /// @notice THE PRODUCT CLAIM, measured rather than asserted: the creator's buy is the first swap,
    /// and the identical buy by a stranger in the same block - the best a sniper can do - gets less.
    function test_HAPPY_theCreatorGetsInFirst() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("first"), address(quoteToken));

        vm.prank(CREATOR);
        (LaunchResultV2 memory r,, uint256 creatorBought,) = lab.launchAndBuy{value: _kitFee(p)}(p, _buy(10 ether));

        (PoolKey memory key,,) = kit.computeLegKey(r.token, p.legs[0]);
        uint256 before = IERC20(r.token).balanceOf(ATTACKER);
        _strangerBuyCL(key, r.token, 10 ether, ATTACKER);
        uint256 sniperBought = IERC20(r.token).balanceOf(ATTACKER) - before;

        assertGt(creatorBought, sniperBought, "the first buy in the pool is the cheapest one");
    }

    /*//////////////////////////////////////////////////////////////
       QUESTION 1: the salt folds msg.sender, so the address moves
    //////////////////////////////////////////////////////////////*/

    /// @notice The factory's own warning, closed: two creators using the SAME `userSalt` through this
    /// one contract must not collide. A mutant that passes `p.userSalt` through unchanged fails here.
    function test_SALT_twoCreatorsSameUserSaltGetDifferentTokens() public {
        bytes32 salt = bytes32("shared");
        assertTrue(_tokenVia(CREATOR, salt) != _tokenVia(OTHER_CREATOR, salt), "namespaces are separate");

        LaunchParamsV2 memory p1 = _oneCL(CREATOR, salt, address(quoteToken));
        vm.prank(CREATOR);
        (LaunchResultV2 memory r1,,,) = lab.launchAndBuy{value: _kitFee(p1)}(p1, _buy(1 ether));

        LaunchParamsV2 memory p2 = _oneCL(OTHER_CREATOR, salt, address(quoteToken));
        vm.prank(OTHER_CREATOR);
        (LaunchResultV2 memory r2,,,) = lab.launchAndBuy{value: _kitFee(p2)}(p2, _buy(1 ether));

        assertTrue(r1.token != r2.token, "the same userSalt produced two different tokens");
        assertEq(r1.token, _tokenVia(CREATOR, salt));
        assertEq(r2.token, _tokenVia(OTHER_CREATOR, salt));
    }

    /// @notice `predictLaunchToken` on THIS contract is the address this path produces.
    function test_SALT_predictionMatchesWhatIsCreated() public {
        bytes32 salt = bytes32("predict");
        address predicted = _tokenVia(CREATOR, salt);
        assertEq(predicted.code.length, 0, "nothing there yet");

        LaunchParamsV2 memory p = _oneCL(CREATOR, salt, address(quoteToken));
        vm.prank(CREATOR);
        (LaunchResultV2 memory r,,,) = lab.launchAndBuy{value: _kitFee(p)}(p, _buy(1 ether));

        assertEq(r.token, predicted);
        assertGt(predicted.code.length, 0);
    }

    /// @notice The cost of routing, stated on chain: the SAME creator and the SAME `userSalt` give a
    /// DIFFERENT address on the direct path. CREATE2 binds the deployer namespace and nothing can
    /// make the two equal. This test exists so nobody re-derives that the hard way.
    function test_SALT_directKitAddressIsNotThisPathsAddress() public view {
        bytes32 salt = bytes32("vanity");
        assertTrue(kit.predictLaunchToken(CREATOR, salt) != lab.predictLaunchToken(CREATOR, salt), "different paths");
    }

    /// @notice A creator who was shown an address cannot be given a different one.
    function test_SALT_expectedTokenMismatchReverts() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("expect"), address(quoteToken));
        DeepCoreLaunchAndBuy.BuyParams memory b = _buy(1 ether);
        b.expectedToken = address(0xDEAD);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeepCoreLaunchAndBuy.LaunchTokenMismatch.selector, address(0xDEAD), _tokenVia(CREATOR, bytes32("expect"))
            )
        );
        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p)}(p, b);
    }

    function test_SALT_expectedTokenMatchPasses() public {
        bytes32 salt = bytes32("expect2");
        LaunchParamsV2 memory p = _oneCL(CREATOR, salt, address(quoteToken));
        DeepCoreLaunchAndBuy.BuyParams memory b = _buy(1 ether);
        b.expectedToken = _tokenVia(CREATOR, salt);

        vm.prank(CREATOR);
        (LaunchResultV2 memory r,,,) = lab.launchAndBuy{value: _kitFee(p)}(p, b);
        assertEq(r.token, b.expectedToken);
    }

    /*//////////////////////////////////////////////////////////////
                         IDENTITY SUBSTITUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Zero creator / operator / steward must resolve to the CALLER, not to this contract.
    /// A mutant that forwards the zeros lets the kit resolve them to its own caller - us - and the
    /// creator silently loses `reconfigureLaunch`, the locker's creator share and the registry record.
    function test_ROLES_zeroesResolveToTheCallerNotToThisContract() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("zeroes"), address(quoteToken));
        assertEq(p.creator, address(0));
        assertEq(p.launchOperator, address(0));
        assertEq(p.launchSteward, address(0));

        vm.prank(CREATOR);
        (LaunchResultV2 memory r,,,) = lab.launchAndBuy{value: _kitFee(p)}(p, _buy(1 ether));

        LaunchRecordV2 memory rec = kit.getLaunch(r.token);
        assertEq(rec.creator, CREATOR, "creator is the caller");
        assertEq(rec.operator, CREATOR, "operator is the caller");
        LaunchRecord memory lr = launchRegistry.getLaunch(r.poolIds[0]);
        assertEq(lr.steward, CREATOR, "registry steward is the caller");
    }

    function test_ROLES_explicitAddressesAreHonoured() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("explicit"), address(quoteToken));
        p.creator = ALLOCATION;
        p.launchOperator = OPERATOR;
        p.launchSteward = STEWARD;

        vm.prank(CREATOR);
        (LaunchResultV2 memory r,,,) = lab.launchAndBuy{value: _kitFee(p)}(p, _buy(1 ether));

        LaunchRecordV2 memory rec = kit.getLaunch(r.token);
        assertEq(rec.creator, ALLOCATION);
        assertEq(rec.operator, OPERATOR);
        assertEq(launchRegistry.getLaunch(r.poolIds[0]).steward, STEWARD);
    }

    /// @notice The operator rights the creator keeps are real: they are frozen, as they would be for
    /// any launch whose pool has traded. That is the guard's rule, not this contract's.
    function test_ROLES_operatorIsTheCallerAndTheLaunchIsFrozen() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("frozen"), address(quoteToken));
        vm.prank(CREATOR);
        (LaunchResultV2 memory r,,,) = lab.launchAndBuy{value: _kitFee(p)}(p, _buy(1 ether));

        PoolKey[] memory keys = new PoolKey[](1);
        (keys[0],,) = kit.computeLegKey(r.token, p.legs[0]);

        // Not the operator: refused for that reason.
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.NotLaunchOperator.selector, r.token, ATTACKER));
        vm.prank(ATTACKER);
        kit.reconfigureLaunch(r.token, keys, p.schedule, _noTax());

        // The operator: refused because the pool has traded. Exactly the M-1 freeze.
        vm.expectRevert();
        vm.prank(CREATOR);
        kit.reconfigureLaunch(r.token, keys, p.schedule, _noTax());
    }

    function test_ROLES_namingThisContractAsCreatorReverts() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("self1"), address(quoteToken));
        p.creator = address(lab);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreLaunchAndBuy.InvalidRecipient.selector, address(lab)));
        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p)}(p, _buy(1 ether));
    }

    function test_ROLES_namingThisContractAsIntegratorOrAllocationReverts() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("self2"), address(quoteToken));
        p.integrator = address(lab);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreLaunchAndBuy.InvalidRecipient.selector, address(lab)));
        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p)}(p, _buy(1 ether));

        LaunchParamsV2 memory q = _oneCL(CREATOR, bytes32("self3"), address(quoteToken));
        q.allocationRecipient = address(lab);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreLaunchAndBuy.InvalidRecipient.selector, address(lab)));
        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(q)}(q, _buy(1 ether));
    }

    /*//////////////////////////////////////////////////////////////
       QUESTION 2: the first buy pays the opening fee. Told, and bounded.
    //////////////////////////////////////////////////////////////*/

    /// @notice `previewOpeningFee` is what a UI shows; `currentFee` is what the guard charges. They
    /// must agree for every preset, or the preview is a lie.
    function test_FEE_previewMatchesTheGuardForEveryPreset() public {
        _assertPreviewMatches(Preset.FairLaunch, 0, bytes32("f1"), 100_000);
        _assertPreviewMatches(Preset.AntiSniperAggressive, 100 ether, bytes32("f2"), 500_000);
        _assertPreviewMatches(Preset.Stealth, 0, bytes32("f3"), 500_000);
        _assertPreviewMatches(Preset.NoTax, 0, bytes32("f4"), 3_000);
    }

    function _assertPreviewMatches(Preset preset, uint128 maxBuy, bytes32 salt, uint24 expected) internal {
        LaunchParamsV2 memory p = _oneCL(CREATOR, salt, address(quoteToken));
        p.schedule.preset = preset;
        p.legs[0].maxBuyPerTx = maxBuy;

        (uint24 previewed, uint256 cost) = lab.previewOpeningFee(p.schedule, 100 ether);
        assertEq(previewed, expected, "the published preset number");
        assertEq(cost, 100 ether * uint256(expected) / 1_000_000, "the quote cost of it");

        vm.prank(CREATOR);
        (,,, uint24 charged) = lab.launchAndBuy{value: _kitFee(p)}(p, _buy(1 ether));
        assertEq(charged, previewed, "preview == what the guard charged");
    }

    function test_FEE_previewHandlesACustomSchedule() public view {
        ScheduleParams memory s = ScheduleParams({
            preset: Preset.Custom,
            initialFeeBips: 250_000,
            finalFeeBips: 5_000,
            decaySeconds: 600,
            enabled: true,
            startDelaySeconds: 0
        });
        (uint24 pips, uint256 cost) = lab.previewOpeningFee(s, 40 ether);
        assertEq(pips, 250_000);
        assertEq(cost, 10 ether);

        // Disabled: the hook pins `finalFeeBips` and never decays.
        s.enabled = false;
        (pips, cost) = lab.previewOpeningFee(s, 40 ether);
        assertEq(pips, 5_000);
        assertEq(cost, 40 ether * 5_000 / 1_000_000);
    }

    /// @notice A caller who was quoted less than the guard charges is refused, not charged.
    function test_FEE_openingFeeAboveTheCallersBoundReverts() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("bound"), address(quoteToken));
        DeepCoreLaunchAndBuy.BuyParams memory b = _buy(1 ether);
        b.maxLpFeePips = 99_999; // one pip under FairLaunch

        vm.expectRevert(abi.encodeWithSelector(DeepCoreLaunchAndBuy.OpeningFeeAboveMax.selector, 100_000, 99_999));
        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p)}(p, b);
    }

    function test_FEE_boundAtExactlyTheGuardsFeePasses() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("bound2"), address(quoteToken));
        DeepCoreLaunchAndBuy.BuyParams memory b = _buy(1 ether);
        b.maxLpFeePips = 100_000;

        vm.prank(CREATOR);
        (,,, uint24 pips) = lab.launchAndBuy{value: _kitFee(p)}(p, b);
        assertEq(pips, 100_000);
    }

    /// @notice What the opening fee actually costs, measured: the same buy on a 10% FairLaunch and on
    /// a 0.30% NoTax launch, same price, same range. The gap IS the fee.
    function test_FEE_quantified_tenPercentIsTenPercent() public {
        LaunchParamsV2 memory fair = _oneCL(CREATOR, bytes32("q1"), address(quoteToken));
        vm.prank(CREATOR);
        (,, uint256 boughtFair,) = lab.launchAndBuy{value: _kitFee(fair)}(fair, _buy(1 ether));

        LaunchParamsV2 memory none = _oneCL(CREATOR, bytes32("q2"), address(quoteToken));
        none.schedule.preset = Preset.NoTax;
        vm.prank(CREATOR);
        (,, uint256 boughtNone,) = lab.launchAndBuy{value: _kitFee(none)}(none, _buy(1 ether));

        assertGt(boughtNone, boughtFair, "the taxed launch bought fewer tokens for the same money");
        // 10% vs 0.30% taken from the input. The ideal ratio is (1 - 0.10) / (1 - 0.003) = 0.9027;
        // the measured one is a shade under because the smaller taxed input also walks a shade less
        // price. Bounded to 1% relative rather than pinned, because the residual IS price impact and
        // pretending it is exactly the fee would be the kind of tidy number this repo does not print.
        uint256 ratioBps = boughtFair * 10_000 / boughtNone;
        assertApproxEqRel(ratioBps, uint256(9_000) * 10_000 / 9_970, 0.01e18, "the gap is the fee");
    }

    /// @notice The kit's protocol fee can rise by itself when a scheduled increase matures. The
    /// caller's bound is what stops that repricing a launch they already signed.
    function test_FEE_aMaturedLaunchFeeIncreaseIsRefusedByTheCallersBound() public {
        vm.prank(safe);
        kit.setLaunchFee(MAX_LAUNCH_FEE);
        vm.warp(block.timestamp + NOTICE + 1);
        assertEq(kit.launchFeeWei(), MAX_LAUNCH_FEE, "the increase materialised by itself");

        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("feeup"), address(quoteToken));
        DeepCoreLaunchAndBuy.BuyParams memory b = _buy(1 ether);
        b.maxLaunchFeeWei = INITIAL_LAUNCH_FEE; // what the caller was quoted

        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreLaunchAndBuy.LaunchFeeAboveMax.selector, MAX_LAUNCH_FEE, INITIAL_LAUNCH_FEE)
        );
        vm.prank(CREATOR);
        lab.launchAndBuy{value: MAX_LAUNCH_FEE + 1 ether}(p, b);
    }

    /// @notice The kit is paid EXACTLY the fee in force, so its excess-refund path - a raw call to
    /// `msg.sender`, which here has no `receive` - is never taken. A mutant that forwards
    /// `msg.value` makes this revert.
    function test_FEE_kitIsPaidExactlyAndItsRefundPathIsNeverTaken() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("exact"), address(quoteToken));
        uint256 owedBefore = kit.feesOwed(safe);

        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p) + 7 ether}(p, _buy(1 ether)); // 7 ether of overpayment

        assertEq(kit.feesOwed(safe) - owedBefore, INITIAL_LAUNCH_FEE, "the protocol fee, once");
        assertEq(address(lab).balance, 0);
        assertEq(address(kit).balance, INITIAL_LAUNCH_FEE, "the kit holds only its credited fee");
    }

    function test_FEE_integratorLaunchFeeIsForwarded() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("integ"), address(quoteToken));
        p.integratorLaunchFeeWei = 0.002 ether;

        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p)}(p, _buy(1 ether));

        assertEq(kit.feesOwed(INTEGRATOR), 0.002 ether, "the integrator's fee reached the kit's ledger");
    }

    /*//////////////////////////////////////////////////////////////
                               REFUSALS
    //////////////////////////////////////////////////////////////*/

    function test_REFUSE_nonZeroStartDelay() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("delay"), address(quoteToken));
        p.schedule.startDelaySeconds = 120;
        vm.expectRevert(abi.encodeWithSelector(DeepCoreLaunchAndBuy.StartDelayMustBeZero.selector, uint32(120)));
        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p)}(p, _buy(1 ether));
    }

    /// @notice FIX F-1 (acceptance, 2026-09-28). The committed source carried mutant M9 - the
    /// `StartDelayMustBeZero` check replaced by a comment - so `test_REFUSE_nonZeroStartDelay` was
    /// red at HEAD. That test only ever saw the HARMLESS half: on an enabled schedule the guard
    /// refuses the swap (`TradingNotOpen`) and the launch unwinds anyway. This is the half that did
    /// NOT unwind: a disabled schedule trades from birth whatever `startTime` says, so without the
    /// check the launch was created, bought and frozen with a `startTime` in the future.
    function test_FIX_nonZeroStartDelayIsRefusedOnADisabledSchedule() public {
        bytes32 salt = bytes32("delay-notax");
        address predicted = _tokenVia(CREATOR, salt);
        LaunchParamsV2 memory p = _oneCL(CREATOR, salt, address(quoteToken));
        p.schedule.preset = Preset.NoTax;
        p.schedule.startDelaySeconds = 1;

        uint256 quoteBefore = quoteToken.balanceOf(CREATOR);
        uint256 nativeBefore = CREATOR.balance;
        vm.expectRevert(abi.encodeWithSelector(DeepCoreLaunchAndBuy.StartDelayMustBeZero.selector, uint32(1)));
        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p)}(p, _buy(1 ether));

        assertEq(predicted.code.length, 0, "no token was created");
        assertEq(kit.getLaunch(predicted).creator, address(0), "no kit record");
        assertEq(quoteToken.balanceOf(CREATOR), quoteBefore, "no quote left the creator");
        assertEq(CREATOR.balance, nativeBefore, "no native left the creator");
    }

    /// @notice FIX F-1. The refusal is a CHECK: it lands before the quote is pulled and before the
    /// kit is called, so a caller with no allowance at all is told about the delay, not about the
    /// transfer. Same for a Custom schedule that is disabled, and for the largest delay the type holds.
    function test_FIX_startDelayIsRefusedBeforeAnythingIsPulled() public {
        address stranger = address(0x5712A);
        vm.deal(stranger, 1 ether);
        LaunchParamsV2 memory p = _oneCL(stranger, bytes32("delay-early"), address(quoteToken));
        p.schedule = ScheduleParams({
            preset: Preset.Custom,
            initialFeeBips: 3_000,
            finalFeeBips: 3_000,
            decaySeconds: 60,
            enabled: false,
            startDelaySeconds: type(uint32).max
        });

        assertEq(quoteToken.allowance(stranger, address(lab)), 0, "the premise: nothing approved");
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreLaunchAndBuy.StartDelayMustBeZero.selector, type(uint32).max)
        );
        vm.prank(stranger);
        lab.launchAndBuy{value: _kitFee(p)}(p, _buy(1 ether));
    }

    function test_REFUSE_zeroBuyAmount() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("zero"), address(quoteToken));
        vm.expectRevert(DeepCoreLaunchAndBuy.ZeroBuyAmount.selector);
        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p)}(p, _buy(0));
    }

    function test_REFUSE_buyAmountAboveInt128() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("big"), address(quoteToken));
        uint256 tooBig = uint256(uint128(type(int128).max)) + 1;
        vm.expectRevert(abi.encodeWithSelector(DeepCoreLaunchAndBuy.BuyAmountTooLarge.selector, tooBig));
        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p)}(p, _buy(tooBig));
    }

    function test_REFUSE_legIndexOutOfRange() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("leg"), address(quoteToken));
        DeepCoreLaunchAndBuy.BuyParams memory b = _buy(1 ether);
        b.legIndex = 3;
        vm.expectRevert(abi.encodeWithSelector(DeepCoreLaunchAndBuy.LegIndexOutOfRange.selector, uint8(3), uint256(1)));
        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p)}(p, b);
    }

    function test_REFUSE_nativeQuoteWithoutEnoughValue() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("short"), address(0));
        uint256 fee = _kitFee(p);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreLaunchAndBuy.InsufficientValue.selector, fee + 1 ether, fee));
        vm.prank(CREATOR);
        lab.launchAndBuy{value: fee}(p, _buy(1 ether));
    }

    function test_REFUSE_erc20QuoteWithoutEnoughValueForTheKitFee() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("short2"), address(quoteToken));
        uint256 fee = _kitFee(p);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreLaunchAndBuy.InsufficientValue.selector, fee, fee - 1));
        vm.prank(CREATOR);
        lab.launchAndBuy{value: fee - 1}(p, _buy(1 ether));
    }

    function test_REFUSE_minAmountOutNotMet() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("slip"), address(quoteToken));
        DeepCoreLaunchAndBuy.BuyParams memory b = _buy(1 ether);
        b.minAmountOut = type(uint128).max;

        vm.expectPartialRevert(DeepCoreLaunchAndBuy.InsufficientOutput.selector);
        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p)}(p, b);
    }

    /// @notice The per-transaction cap binds the CREATOR too. It has to: the guard cannot tell who is
    /// buying, and a contract that could exempt itself would be a cap with a back door in it.
    function test_REFUSE_maxBuyPerTxAppliesToTheCreatorsOwnBuy() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("cap"), address(quoteToken));
        p.schedule.preset = Preset.AntiSniperAggressive;
        p.legs[0].maxBuyPerTx = 1 ether;

        // The guard's own refusal, wrapped by core exactly once and bubbled unchanged through the
        // Vault lock and this contract. Pinned in full: "a revert" would also be satisfied by a
        // broken fixture.
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(clHook),
                ICLHooks.beforeSwap.selector,
                abi.encodeWithSelector(LaunchGuardHook.BuyExceedsMaxPerTx.selector, 2 ether, uint128(1 ether)),
                abi.encodePacked(Hooks.HookCallFailed.selector)
            )
        );
        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p)}(p, _buy(2 ether));

        // At the cap it goes through.
        vm.prank(CREATOR);
        (,, uint256 bought,) = lab.launchAndBuy{value: _kitFee(p)}(p, _buy(1 ether));
        assertGt(bought, 0);
    }

    /*//////////////////////////////////////////////////////////////
                              ATOMICITY
    //////////////////////////////////////////////////////////////*/

    /// @notice A failed buy must not leave a half-made launch. There is no try/catch, so the whole
    /// transaction unwinds: no token, no kit record, no guard claim, no registry record.
    function test_ATOMIC_aFailedBuyLeavesNoLaunchBehind() public {
        bytes32 salt = bytes32("atomic");
        address predicted = _tokenVia(CREATOR, salt);
        LaunchParamsV2 memory p = _oneCL(CREATOR, salt, address(quoteToken));
        (, bytes32 poolId,) = kit.computeLegKey(predicted, p.legs[0]);

        DeepCoreLaunchAndBuy.BuyParams memory b = _buy(1 ether);
        b.minAmountOut = type(uint128).max;

        vm.expectPartialRevert(DeepCoreLaunchAndBuy.InsufficientOutput.selector);
        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p)}(p, b);

        assertEq(predicted.code.length, 0, "no token");
        assertEq(kit.getLaunch(predicted).creator, address(0), "no kit record");
        assertFalse(kit.isLockedLaunch(poolId), "no V3 flag");
        assertEq(clHook.launchOwner(PoolId.wrap(poolId)), address(0), "no guard claim");
        // The registry has no record at all: the read itself refuses, which is the strongest form of
        // "nothing was written".
        vm.expectRevert();
        launchRegistry.getLaunch(poolId);
        assertEq(quoteToken.balanceOf(address(lab)), 0);
        assertEq(address(lab).balance, 0);
    }

    /// @notice Retrying the same salt after a failure works: nothing was consumed.
    function test_ATOMIC_theSameSaltWorksOnRetry() public {
        bytes32 salt = bytes32("retry");
        LaunchParamsV2 memory p = _oneCL(CREATOR, salt, address(quoteToken));

        DeepCoreLaunchAndBuy.BuyParams memory bad = _buy(1 ether);
        bad.minAmountOut = type(uint128).max;
        vm.expectPartialRevert(DeepCoreLaunchAndBuy.InsufficientOutput.selector);
        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p)}(p, bad);

        vm.prank(CREATOR);
        (LaunchResultV2 memory r,,,) = lab.launchAndBuy{value: _kitFee(p)}(p, _buy(1 ether));
        assertEq(r.token, _tokenVia(CREATOR, salt));
    }

    /*//////////////////////////////////////////////////////////////
                               REFUNDS
    //////////////////////////////////////////////////////////////*/

    function test_REFUND_nativeOverpaymentComesBack() public {
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("over"), address(0));
        uint256 fee = _kitFee(p);
        uint256 before = CREATOR.balance;

        vm.prank(CREATOR);
        (, uint256 spent,,) = lab.launchAndBuy{value: fee + 2 ether + 5 ether}(p, _buy(2 ether));

        assertEq(spent, 2 ether);
        assertEq(before - CREATOR.balance, fee + 2 ether, "the 5 ether of slack came straight back");
    }

    /// @notice A single-sided range can be exhausted, and the guard charges an exact-input buy on
    /// the amount NAMED. So a buy the pool could only fill in part is refused by the guard
    /// (`SwapNotFilled`), and the launch unwinds with it: no token, and every unit back where it was.
    function test_REFUSE_aBuyTheRangeCannotFillNative() public {
        bytes32 salt = bytes32("partial");
        LaunchParamsV2 memory p = _oneCL(CREATOR, salt, address(0));
        uint256 fee = _kitFee(p);
        // Enough to buy through the whole single-sided range and then some.
        uint256 huge = 1e30;
        vm.deal(CREATOR, huge + fee + 1 ether);
        uint256 before = CREATOR.balance;

        vm.expectPartialRevert(CustomRevert.WrappedError.selector);
        vm.prank(CREATOR);
        lab.launchAndBuy{value: fee + huge}(p, _buy(huge));

        assertEq(CREATOR.balance, before, "nothing left the creator");
        assertEq(_tokenVia(CREATOR, salt).code.length, 0, "no token was created");
        assertEq(address(lab).balance, 0);
    }

    function test_REFUSE_aBuyTheRangeCannotFillErc20() public {
        bytes32 salt = bytes32("partial2");
        LaunchParamsV2 memory p = _oneCL(CREATOR, salt, address(quoteToken));
        uint256 huge = 1e29;
        quoteToken.mint(CREATOR, huge);
        uint256 before = quoteToken.balanceOf(CREATOR);

        // FairLaunch opens at 10%: the pool had to take in 90% of what was named.
        vm.expectPartialRevert(CustomRevert.WrappedError.selector);
        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p)}(p, _buy(huge));

        assertEq(quoteToken.balanceOf(CREATOR), before, "nothing left the creator");
        assertEq(_tokenVia(CREATOR, salt).code.length, 0, "no token was created");
        assertEq(quoteToken.balanceOf(address(lab)), 0);
    }

    /// @notice A caller that cannot receive native is fine as long as it sends exact amounts - which
    /// is the documented way to use this from a contract.
    function test_REFUND_aCallerWithNoReceiveMaySendExactAmounts() public {
        NativeRefuser refuser = new NativeRefuser();
        vm.deal(address(refuser), 100 ether);
        quoteToken.mint(address(refuser), 1e24);
        vm.prank(address(refuser));
        quoteToken.approve(address(lab), type(uint256).max);

        LaunchParamsV2 memory p = _oneCL(address(refuser), bytes32("norecv"), address(quoteToken));
        p.creator = CREATOR; // the refuser must not be a locker creator either; irrelevant to the point
        uint256 fee = _kitFee(p);

        bytes memory data =
            abi.encodeWithSelector(DeepCoreLaunchAndBuy.launchAndBuy.selector, p, _buy(1 ether));
        refuser.call{value: fee}(address(lab), fee, data);

        assertEq(address(lab).balance, 0);
    }

    function test_REFUND_aCallerWithNoReceiveThatOverpaysIsRefused() public {
        NativeRefuser refuser = new NativeRefuser();
        vm.deal(address(refuser), 100 ether);
        quoteToken.mint(address(refuser), 1e24);
        vm.prank(address(refuser));
        quoteToken.approve(address(lab), type(uint256).max);

        LaunchParamsV2 memory p = _oneCL(address(refuser), bytes32("norecv2"), address(quoteToken));
        p.creator = CREATOR;
        uint256 fee = _kitFee(p);

        bytes memory data =
            abi.encodeWithSelector(DeepCoreLaunchAndBuy.launchAndBuy.selector, p, _buy(1 ether));
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreLaunchAndBuy.NativeTransferFailed.selector, address(refuser), uint256(1))
        );
        refuser.call{value: fee + 1}(address(lab), fee + 1, data);
    }

    /*//////////////////////////////////////////////////////////////
                         ACCESS AND REENTRANCY
    //////////////////////////////////////////////////////////////*/

    function test_ACCESS_lockAcquiredRejectsEverybodyButTheVault() public {
        vm.expectRevert(abi.encodeWithSelector(DeepCoreLaunchAndBuy.NotVault.selector, ATTACKER));
        vm.prank(ATTACKER);
        lab.lockAcquired("");

        vm.expectRevert(abi.encodeWithSelector(DeepCoreLaunchAndBuy.NotVault.selector, address(this)));
        lab.lockAcquired("");
    }

    /// @notice Even the Vault cannot drive `lockAcquired` unless this contract is the locker - which,
    /// since `Vault.lock` calls back only on `msg.sender`, it can only be by our own doing.
    function test_ACCESS_lockAcquiredRejectsTheVaultWhenWeAreNotTheLocker() public {
        vm.expectRevert(abi.encodeWithSelector(DeepCoreLaunchAndBuy.NotLocker.selector, address(0)));
        vm.prank(address(vault));
        lab.lockAcquired("");
    }

    /// @notice The only untrusted contract in the flow is the quote token. It cannot reenter.
    function test_REENTRANCY_aHostileQuoteTokenCannotReenterLaunchAndBuy() public {
        ReentrantQuoteToken evil = new ReentrantQuoteToken();
        evil.mint(CREATOR, 1e30);
        vm.prank(CREATOR);
        evil.approve(address(lab), type(uint256).max);

        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("re1"), address(evil));
        DeepCoreLaunchAndBuy.BuyParams memory b = _buy(1 ether);
        evil.armLaunch(p, b);
        evil.arm(lab, ReentrantQuoteToken.Mode.LaunchAndBuy);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p)}(p, b);
    }

    function test_REENTRANCY_aHostileQuoteTokenCannotSweepMidFlight() public {
        ReentrantQuoteToken evil = new ReentrantQuoteToken();
        evil.mint(CREATOR, 1e30);
        vm.prank(CREATOR);
        evil.approve(address(lab), type(uint256).max);

        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("re2"), address(evil));
        evil.arm(lab, ReentrantQuoteToken.Mode.SweepERC20);

        // The GUARD's refusal, not `NothingToSweep`: at the pull the contract holds nothing, so
        // only the selector tells a working guard from a missing one.
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p)}(p, _buy(1 ether));
    }

    function test_REENTRANCY_aHostileQuoteTokenCannotCallLockAcquired() public {
        ReentrantQuoteToken evil = new ReentrantQuoteToken();
        evil.mint(CREATOR, 1e30);
        vm.prank(CREATOR);
        evil.approve(address(lab), type(uint256).max);

        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("re3"), address(evil));
        evil.arm(lab, ReentrantQuoteToken.Mode.LockAcquired);

        vm.expectRevert(abi.encodeWithSelector(DeepCoreLaunchAndBuy.NotVault.selector, address(evil)));
        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p)}(p, _buy(1 ether));
    }

    /// @notice No `receive`, no `fallback`: a plain send cannot reach this contract.
    function test_ACCESS_plainNativeSendIsRefused() public {
        (bool ok,) = address(lab).call{value: 1 ether}("");
        assertFalse(ok, "nothing to receive it");
        assertEq(address(lab).balance, 0);
    }

    /*//////////////////////////////////////////////////////////////
                         SWEEPS AND BACKDOORS
    //////////////////////////////////////////////////////////////*/

    /// @notice Native can still be forced in. It leaves, and only to the immutable recipient.
    function test_SWEEP_forcedNativeLeavesToTheRecipientOnly() public {
        new Forcer{value: 3 ether}(payable(address(lab)));
        assertEq(address(lab).balance, 3 ether, "forced in");

        uint256 before = SWEEP_SAFE.balance;
        vm.prank(ATTACKER); // permissionless on purpose
        uint256 amount = lab.sweepNative();

        assertEq(amount, 3 ether);
        assertEq(SWEEP_SAFE.balance - before, 3 ether, "and only there");
        assertEq(address(lab).balance, 0);
        assertEq(ATTACKER.balance, 10_000 ether, "the caller got nothing");
    }

    function test_SWEEP_misdirectedErc20LeavesToTheRecipientOnly() public {
        vm.prank(ATTACKER);
        quoteToken.transfer(address(lab), 42 ether);

        vm.prank(ATTACKER);
        uint256 amount = lab.sweepERC20(address(quoteToken));

        assertEq(amount, 42 ether);
        assertEq(quoteToken.balanceOf(SWEEP_SAFE), 42 ether);
        assertEq(quoteToken.balanceOf(address(lab)), 0);
    }

    function test_SWEEP_revertsWhenThereIsNothing() public {
        vm.expectRevert(DeepCoreLaunchAndBuy.NothingToSweep.selector);
        lab.sweepNative();
        vm.expectRevert(DeepCoreLaunchAndBuy.NothingToSweep.selector);
        lab.sweepERC20(address(quoteToken));
    }

    /// @notice There is no owner, no admin and no setter: every address is immutable and every one of
    /// them except the sweep recipient was READ OFF THE KIT rather than supplied.
    function test_BACKDOOR_thereIsNoPrivilegedFunctionAtAll() public view {
        (bool ok,) = address(lab).staticcall(abi.encodeWithSignature("owner()"));
        assertFalse(ok, "no owner()");
        (ok,) = address(lab).staticcall(abi.encodeWithSignature("pause()"));
        assertFalse(ok, "no pause()");
        (ok,) = address(lab).staticcall(abi.encodeWithSignature("transferOwnership(address)"));
        assertFalse(ok, "no ownership at all");

        assertEq(address(lab.KIT()), address(kit));
        assertEq(address(lab.VAULT()), address(vault));
        assertEq(address(lab.CL_POOL_MANAGER()), address(clPM));
        assertEq(address(lab.BIN_POOL_MANAGER()), address(binPM));
        assertEq(lab.SWEEP_RECIPIENT(), SWEEP_SAFE);
    }

    /*//////////////////////////////////////////////////////////////
                        CONSTRUCTION AND SELECTORS
    //////////////////////////////////////////////////////////////*/

    function test_CTOR_rejectsZeroAndCodelessArguments() public {
        vm.expectRevert(DeepCoreLaunchAndBuy.ZeroAddress.selector);
        new DeepCoreLaunchAndBuy(ILaunchpadKitV2(address(0)), SWEEP_SAFE);

        vm.expectRevert(DeepCoreLaunchAndBuy.ZeroAddress.selector);
        new DeepCoreLaunchAndBuy(ILaunchpadKitV2(address(kit)), address(0));

        vm.expectRevert(abi.encodeWithSelector(DeepCoreLaunchAndBuy.NoCode.selector, address(0xBEEF)));
        new DeepCoreLaunchAndBuy(ILaunchpadKitV2(address(0xBEEF)), SWEEP_SAFE);
    }

    /// @notice `ILaunchGuardFee.currentFee(bytes32)` must be the same function as each guard's
    /// `currentFee(PoolId)`. `PoolId` is a value type over `bytes32`, so it is - and this proves it
    /// rather than trusting the encoding rule.
    function test_SELECTOR_currentFeeMatchesBothGuards() public {
        LaunchParamsV2 memory p = _clAndBin(CREATOR, bytes32("sel"), address(quoteToken));
        vm.prank(CREATOR);
        (LaunchResultV2 memory r,,,) = lab.launchAndBuy{value: _kitFee(p)}(p, _buy(1 ether));

        assertEq(
            ILaunchGuardFee(address(clHook)).currentFee(r.poolIds[0]),
            clHook.currentFee(PoolId.wrap(r.poolIds[0])),
            "CL guard"
        );
        assertEq(
            ILaunchGuardFee(address(binHook)).currentFee(r.poolIds[1]),
            binHook.currentFee(PoolId.wrap(r.poolIds[1])),
            "Bin guard"
        );
    }

    /*//////////////////////////////////////////////////////////////
       ADDED BY THE ACCEPTANCE BAR, 2026-09-28 (docs/launch-and-buy-acceptance.md)
    //////////////////////////////////////////////////////////////*/

    function _midLock() internal returns (MidLockQuoteToken t) {
        t = new MidLockQuoteToken();
        t.mint(CREATOR, 1e30);
        vm.prank(CREATOR);
        t.approve(address(lab), type(uint256).max);
    }

    /// @notice The moment that matters: inside the Vault lock, while this contract HOLDS the quote
    /// budget. A sweep there would send the creator's money to the sweep recipient.
    function test_REENTRANCY_midLockSweepOfTheBudgetIsRefused() public {
        MidLockQuoteToken t = _midLock();
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("mid1"), address(t));
        t.arm(address(lab), MidLockQuoteToken.Mode.SweepERC20, false);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p)}(p, _buy(7 ether));
    }

    /// @notice Same instant, the native side: the caller's overpayment is resting here until the
    /// refund at the end of the call.
    function test_REENTRANCY_midLockSweepOfTheNativeOverpaymentIsRefused() public {
        MidLockQuoteToken t = _midLock();
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("mid2"), address(t));
        t.arm(address(lab), MidLockQuoteToken.Mode.SweepNative, false);

        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p) + 2 ether}(p, _buy(7 ether));
    }

    /// @notice While this contract IS the Vault's locker, only the Vault may call `lockAcquired`.
    function test_REENTRANCY_midLockLockAcquiredIsRefused() public {
        MidLockQuoteToken t = _midLock();
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("mid3"), address(t));
        t.arm(address(lab), MidLockQuoteToken.Mode.LockAcquired, false);

        vm.expectRevert(abi.encodeWithSelector(DeepCoreLaunchAndBuy.NotVault.selector, address(t)));
        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p)}(p, _buy(7 ether));
    }

    /// @notice A hostile token that swallows the refusal and carries on. The launch must complete
    /// exactly as if nothing had been tried, and the evidence that something WAS tried is read back
    /// - a mock that never fired would pass every other assertion here.
    function test_REENTRANCY_aSwallowedMidLockAttackLeavesTheLaunchIntact() public {
        MidLockQuoteToken t = _midLock();
        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("mid4"), address(t));
        t.arm(address(lab), MidLockQuoteToken.Mode.SweepERC20, true);

        uint256 nativeBefore = CREATOR.balance;
        uint256 quoteBefore = t.balanceOf(CREATOR);
        vm.prank(CREATOR);
        (LaunchResultV2 memory r, uint256 spent, uint256 bought,) =
            lab.launchAndBuy{value: _kitFee(p) + 1 ether}(p, _buy(7 ether));

        assertEq(t.fired(), 1, "the mock fired");
        assertFalse(t.lastOk(), "and was refused");
        assertEq(bytes4(t.lastRevert()), ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "by the guard");
        assertEq(t.targetBalanceAtAttack(), 7 ether, "while the contract held the whole budget");

        assertEq(spent, 7 ether);
        assertEq(IERC20(r.token).balanceOf(CREATOR), bought);
        assertEq(quoteBefore - t.balanceOf(CREATOR), spent, "only the fill left the creator");
        assertEq(nativeBefore - CREATOR.balance, _kitFee(p), "the overpayment came back");
        assertEq(t.balanceOf(SWEEP_SAFE), 0, "nothing reached the sweep recipient");
        assertEq(t.balanceOf(address(lab)), 0);
        assertEq(address(lab).balance, 0);
    }

    /// @notice A fee-on-transfer quote is unsupported. It must fail CLOSED: the pull is measured, the
    /// settlement arrives short, and the Vault refuses to close the lock.
    function test_TOKEN_feeOnTransferQuoteFailsClosed() public {
        FeeOnTransferQuoteToken t = new FeeOnTransferQuoteToken();
        t.mint(CREATOR, 1e30);
        vm.prank(CREATOR);
        t.approve(address(lab), type(uint256).max);

        bytes32 salt = bytes32("fot");
        address predicted = _tokenVia(CREATOR, salt);
        LaunchParamsV2 memory p = _oneCL(CREATOR, salt, address(t));
        p.schedule.preset = Preset.NoTax;
        uint256 quoteBefore = t.balanceOf(CREATOR);

        vm.expectRevert(IVault.CurrencyNotSettled.selector);
        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p)}(p, _buy(1 ether));

        assertEq(predicted.code.length, 0, "no launch was left behind");
        assertEq(t.balanceOf(CREATOR), quoteBefore, "and the creator kept every unit");
        assertEq(t.balanceOf(address(lab)), 0);
    }

    /// @notice Value resting here that belongs to nobody is neither spent on a caller's behalf nor
    /// handed to them as a refund. The refund is `msg.value` arithmetic, never the balance.
    function test_SWEEP_aRestingBalanceIsNeitherSpentNorRefunded() public {
        new Forcer{value: 2 ether}(payable(address(lab)));
        vm.prank(ATTACKER);
        quoteToken.transfer(address(lab), 9 ether);

        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("stray"), address(quoteToken));
        uint256 nativeBefore = CREATOR.balance;
        uint256 quoteBefore = quoteToken.balanceOf(CREATOR);

        vm.prank(CREATOR);
        (, uint256 spent,,) = lab.launchAndBuy{value: _kitFee(p) + 0.3 ether}(p, _buy(1 ether));

        assertEq(nativeBefore - CREATOR.balance, _kitFee(p), "the caller got back their own 0.3, not the stray 2");
        assertEq(quoteBefore - quoteToken.balanceOf(CREATOR), spent, "and paid exactly the fill");
        assertEq(address(lab).balance, 2 ether, "the stray native is still here");
        assertEq(quoteToken.balanceOf(address(lab)), 9 ether, "the stray quote is still here");

        assertEq(lab.sweepNative(), 2 ether);
        assertEq(lab.sweepERC20(address(quoteToken)), 9 ether);
        assertEq(SWEEP_SAFE.balance, 2 ether);
        assertEq(quoteToken.balanceOf(SWEEP_SAFE), 9 ether);
    }

    /// @notice A recipient that refuses native cannot make the money vanish: the sweep reverts and
    /// the balance stays where it was.
    function test_SWEEP_aRefusingRecipientLeavesTheBalanceInPlace() public {
        NativeRefuser refusing = new NativeRefuser();
        DeepCoreLaunchAndBuy other = new DeepCoreLaunchAndBuy(ILaunchpadKitV2(address(kit)), address(refusing));
        new Forcer{value: 2 ether}(payable(address(other)));

        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreLaunchAndBuy.NativeTransferFailed.selector, address(refusing), 2 ether)
        );
        other.sweepNative();
        assertEq(address(other).balance, 2 ether);
    }

    /// @notice The kit refuses any Bin opening above 10%, so the 50% presets do not exist on a Bin
    /// leg - while `previewOpeningFee`, which is pure and does not know the leg, still answers 50%.
    /// A UI must not offer those presets on a Bin leg. Recorded, not changed.
    function test_FEE_fiftyPercentPresetsAreRefusedOnABinLegByTheKit() public {
        LaunchParamsV2 memory p = _oneBin(address(quoteToken));
        p.schedule.preset = Preset.Stealth;

        (uint24 pips,) = lab.previewOpeningFee(p.schedule, 1 ether);
        assertEq(pips, 500_000, "the preview does not know the leg is Bin");

        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.PresetUnavailableOnBin.selector, Preset.Stealth));
        vm.prank(CREATOR);
        lab.launchAndBuy{value: _kitFee(p)}(p, _buy(1 ether));
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @notice Whatever is thrown at it, the contract keeps nothing and the caller is never charged
    /// more than the kit fee plus what the pool actually consumed.
    function testFuzz_theContractNeverKeepsAnything(uint96 amountIn, uint96 overpay) public {
        amountIn = uint96(bound(amountIn, 1e12, 5_000 ether));
        overpay = uint96(bound(overpay, 0, 10 ether));

        LaunchParamsV2 memory p = _oneCL(CREATOR, bytes32("fuzz"), address(0));
        uint256 fee = _kitFee(p);
        vm.deal(CREATOR, uint256(amountIn) + uint256(overpay) + fee + 1 ether);
        uint256 before = CREATOR.balance;

        vm.prank(CREATOR);
        (, uint256 spent,,) = lab.launchAndBuy{value: fee + amountIn + overpay}(p, _buy(amountIn));

        assertLe(spent, amountIn, "never more than was offered");
        assertEq(before - CREATOR.balance, fee + spent, "charged the fee and the fill, nothing else");
        assertEq(address(lab).balance, 0, "kept nothing");
    }

    function testFuzz_predictionIsInjectiveInTheSalt(bytes32 a, bytes32 b) public view {
        vm.assume(a != b);
        assertTrue(lab.predictLaunchToken(CREATOR, a) != lab.predictLaunchToken(CREATOR, b));
        assertTrue(lab.predictLaunchToken(CREATOR, a) != lab.predictLaunchToken(ATTACKER, a));
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _noTax() internal pure returns (TaxParams memory t) {}
}
