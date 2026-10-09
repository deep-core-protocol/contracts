// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {DeepCoreProtocolFeeControllerV2} from "../src/DeepCoreProtocolFeeControllerV2.sol";

import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {ProtocolFeeLibrary} from "infinity-core/src/libraries/ProtocolFeeLibrary.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";

/// @dev Stands in for a pool manager. Records the collect call and answers `protocolFeesAccrued`.
contract MockProtocolFees {
    using PoolIdLibrary for PoolKey;

    mapping(Currency => uint256) public protocolFeesAccrued;

    address public lastRecipient;
    Currency public lastCurrency;
    uint256 public lastAmount;
    uint256 public collectCalls;
    address public lastCaller;

    function setAccrued(Currency currency, uint256 amount) external {
        protocolFeesAccrued[currency] = amount;
    }

    mapping(PoolId => uint24) public poolProtocolFee;
    uint256 public setProtocolFeeCalls;

    function setProtocolFee(PoolKey memory key, uint24 newProtocolFee) external {
        lastCaller = msg.sender;
        poolProtocolFee[PoolIdLibrary.toId(key)] = newProtocolFee;
        setProtocolFeeCalls++;
    }

    function collectProtocolFees(address recipient, Currency currency, uint256 amount)
        external
        returns (uint256 amountCollected)
    {
        lastCaller = msg.sender;
        lastRecipient = recipient;
        lastCurrency = currency;
        amountCollected = amount == 0 ? protocolFeesAccrued[currency] : amount;
        lastAmount = amountCollected;
        protocolFeesAccrued[currency] -= amountCollected;
        collectCalls++;
    }
}

contract DeepCoreProtocolFeeControllerV2Test is Test {
    using PoolIdLibrary for PoolKey;
    using ProtocolFeeLibrary for uint24;

    DeepCoreProtocolFeeControllerV2 internal controller;
    MockProtocolFees internal manager;

    address internal governance = address(0x6011);
    address internal guardian = address(0x69A2D);
    Currency internal usdg = Currency.wrap(address(0x5f65));

    uint256 internal constant ONE = 1e6;

    function setUp() public {
        controller = new DeepCoreProtocolFeeControllerV2(governance, guardian);
        manager = new MockProtocolFees();
    }

    function _key(uint24 fee) internal pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(0x3333)),
            fee: fee,
            parameters: bytes32(uint256(0x3c0000))
        });
    }

    /* ---------------------------------------------------------------------
       THE NUMBER. If this table changes, the protocol's revenue changed and
       somebody should have meant it.
       --------------------------------------------------------------------- */

    function test_SplitRatio_DefaultsTo25Percent() public view {
        assertEq(controller.protocolFeeSplitRatio(), 250_000);
        assertEq(controller.DEFAULT_SPLIT_RATIO(), 250_000);
    }

    function test_TierTable_MatchesThePublishedNumbers() public view {
        // lpFee => protocol pips, at the launch split of 25%.
        assertEq(controller.feeForLpFee(100), 33, "0.01% tier");
        assertEq(controller.feeForLpFee(500), 166, "0.05% tier");
        assertEq(controller.feeForLpFee(2500), 832, "0.25% tier");
        assertEq(controller.feeForLpFee(3000), 999, "0.30% tier");
        assertEq(controller.feeForLpFee(10000), 3322, "1.00% tier");
    }

    function test_TheCommonCaseIsUnderATenthOfAPercent() public view {
        // The 0.30% pool is the one that matters, and 999 pips is 0.0999%.
        uint16 p = controller.feeForLpFee(3000);
        assertLt(p, 1000, "must stay under a flat 0.1%");

        // And the trader's all-in cost stays under 0.4%.
        uint256 total = uint256(p) + 3000 - (uint256(p) * 3000) / ONE;
        assertLt(total, 4000, "all-in cost must stay under 0.4%");
    }

    /// The protocol's share of the TOTAL is what "25%" actually promises.
    function test_ShareOfTotalIsTwentyFivePercent_AcrossEveryTier() public view {
        uint24[5] memory tiers = [uint24(100), 500, 2500, 3000, 10000];
        for (uint256 i = 0; i < tiers.length; i++) {
            uint256 p = controller.feeForLpFee(tiers[i]);
            uint256 total = p + tiers[i] - (p * tiers[i]) / ONE;
            uint256 shareBps = (p * 10_000) / total;
            // Integer truncation costs a little at the smallest tier; 24.8%+ everywhere.
            assertGe(shareBps, 2480, "share too low");
            assertLe(shareBps, 2500, "share too high");
        }
    }

    /// @dev Pancake hits core's cap at ~0.9% LP fee and their share decays after it. Ours does
    /// not, through the 1% tier — that is a property worth not losing silently.
    function test_NoCapCliffThroughTheOnePercentTier() public view {
        assertLt(controller.feeForLpFee(10000), controller.MAX_PROTOCOL_FEE(), "1% tier must not cap");
    }

    /// @dev Proves we implement the SAME arithmetic as infinity-core's controller: set their
    /// ratio, get their published numbers.
    function test_AtPancakesRatio_WeReproducePancakesFees() public {
        vm.prank(governance);
        controller.setProtocolFeeSplitRatio(330_000);

        assertEq(controller.feeForLpFee(100), 49);
        assertEq(controller.feeForLpFee(500), 246);
        assertEq(controller.feeForLpFee(2500), 1229);
        assertEq(controller.feeForLpFee(3000), 1475);
        // Theirs caps here; ours would too at their ratio.
        assertEq(controller.feeForLpFee(10000), controller.MAX_PROTOCOL_FEE());
    }

    function test_WeUndercutPancakeAtEveryTier() public {
        uint24[4] memory tiers = [uint24(100), 500, 2500, 3000];
        uint16[4] memory ours;
        for (uint256 i = 0; i < tiers.length; i++) ours[i] = controller.feeForLpFee(tiers[i]);

        vm.prank(governance);
        controller.setProtocolFeeSplitRatio(330_000);
        for (uint256 i = 0; i < tiers.length; i++) {
            assertLt(ours[i], controller.feeForLpFee(tiers[i]), "must be cheaper than Pancake");
        }
    }

    /* ---------------------------------------------------------------------
       THE HOT PATH MUST NEVER REVERT. A revert here bricks pool creation.
       --------------------------------------------------------------------- */

    function testFuzz_ProtocolFeeForPool_NeverReverts(uint24 lpFee, uint256 ratio) public {
        ratio = bound(ratio, 0, ONE);
        vm.prank(governance);
        controller.setProtocolFeeSplitRatio(ratio);

        // Any fee value at all, including malformed and dynamic-flagged ones.
        uint24 packed = this.callProtocolFeeForPool(_key(lpFee));
        // And whatever comes back must be a value core will accept.
        assertLe(packed & 0xFFF, controller.MAX_PROTOCOL_FEE());
        assertLe(packed >> 12, controller.MAX_PROTOCOL_FEE());
    }

    /// @dev External so a revert surfaces as a test failure rather than being swallowed.
    function callProtocolFeeForPool(PoolKey memory key) external view returns (uint24) {
        return controller.protocolFeeForPool(key);
    }

    function test_ZeroLpFeePoolDoesNotDivideByZero() public view {
        assertEq(controller.feeForLpFee(0), 0);
    }

    function test_RatioOfZeroMeansNoFee() public {
        vm.prank(governance);
        controller.setProtocolFeeSplitRatio(0);
        assertEq(controller.feeForLpFee(3000), 0);
        assertEq(controller.protocolFeeForPool(_key(3000)), 0);
    }

    function test_RatioOfOneHundredPercentClampsToTheCoreCap() public {
        vm.prank(governance);
        controller.setProtocolFeeSplitRatio(ONE);
        assertEq(controller.feeForLpFee(3000), controller.MAX_PROTOCOL_FEE());
    }

    function test_RatioAboveOneHundredPercentIsRefused() public {
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV2.InvalidSplitRatio.selector, ONE + 1));
        controller.setProtocolFeeSplitRatio(ONE + 1);
    }

    /* ---------------------------------------------------------------------
       PRECEDENCE
       --------------------------------------------------------------------- */

    function test_Precedence_KillSwitchBeatsEverything() public {
        vm.startPrank(governance);
        controller.setPoolFee(_key(3000).toId(), true, 4000, 4000);
        controller.setFeesDisabled(true);
        vm.stopPrank();
        assertEq(controller.protocolFeeForPool(_key(3000)), 0);
    }

    function test_Precedence_PoolBeatsTier() public {
        vm.startPrank(governance);
        controller.setTierFee(3000, true, 100, 100);
        controller.setPoolFee(_key(3000).toId(), true, 200, 200);
        vm.stopPrank();
        assertEq(controller.protocolFeeForPool(_key(3000)), uint24(200) | (uint24(200) << 12));
    }

    function test_Precedence_TierBeatsSplit() public {
        vm.prank(governance);
        controller.setTierFee(3000, true, 100, 100);
        assertEq(controller.protocolFeeForPool(_key(3000)), uint24(100) | (uint24(100) << 12));
    }

    function test_Precedence_SplitIsTheBaseCase() public view {
        assertEq(controller.protocolFeeForPool(_key(3000)), uint24(999) | (uint24(999) << 12));
    }

    /// A tier nobody enumerated resolves proportionately instead of falling through to a flat
    /// default. This is the specific V1 failure the split model removes.
    function test_AnUnenumeratedTierStillGetsAProportionateFee() public view {
        uint16 odd = controller.feeForLpFee(777);
        assertGt(odd, 0);
        uint256 total = uint256(odd) + 777 - (uint256(odd) * 777) / ONE;
        assertGe((uint256(odd) * 10_000) / total, 2400);
    }

    /**
     * EVERY LAUNCHPAD POOL IS DYNAMIC-FEE. `LaunchpadKit.sol:373` sets
     * `fee: LPFeeLibrary.DYNAMIC_FEE_FLAG` and `LaunchGuardHook` reverts
     * `PoolMustUseDynamicFee` on anything else. A zero default here would exempt the entire
     * launchpad from the protocol fee — permanently for each pool, since core stamps the fee at
     * `initialize`. This test exists because an earlier draft of this contract did exactly that.
     */
    function test_DynamicPoolsPayByDefault_BecauseEveryLaunchIsOne() public view {
        PoolKey memory key = _key(LPFeeLibrary.DYNAMIC_FEE_FLAG);
        uint24 packed = controller.protocolFeeForPool(key);

        assertTrue(packed != 0, "a dynamic pool must not be free by omission");
        assertEq(packed & 0xFFF, controller.DYNAMIC_FEE_PIPS());
        assertEq(packed >> 12, controller.DYNAMIC_FEE_PIPS());
    }

    /// The default is the 0.30% tier's fee, because 0.30% is what every launch preset decays to.
    function test_DynamicDefaultEqualsTheThirtyBipTier() public view {
        assertEq(controller.DYNAMIC_FEE_PIPS(), controller.feeForLpFee(3000));
        assertEq(controller.DYNAMIC_FEE_PIPS(), 999);
    }

    function test_DynamicFeeStillOverridable() public {
        PoolKey memory key = _key(LPFeeLibrary.DYNAMIC_FEE_FLAG);
        vm.prank(governance);
        controller.setDynamicFee(true, 500, 500);
        assertEq(controller.protocolFeeForPool(key), uint24(500) | (uint24(500) << 12));
    }

    /// Governance may still choose zero — but only deliberately, never by omission.
    function test_DynamicFeeCanBeTurnedOffOnPurpose() public {
        PoolKey memory key = _key(LPFeeLibrary.DYNAMIC_FEE_FLAG);
        vm.prank(governance);
        controller.setDynamicFee(false, 0, 0);
        assertEq(controller.protocolFeeForPool(key), 0);
    }

    /* ---------------------------------------------------------------------
       COLLECTION — the reason V2 exists
       --------------------------------------------------------------------- */

    function test_Collect_ForwardsToTheManagerAndPaysTheRecipient() public {
        manager.setAccrued(usdg, 5_000_000);

        vm.prank(governance);
        uint256 got = controller.collect(address(manager), usdg, 0, governance);

        assertEq(got, 5_000_000, "sweeps the whole balance when amount is zero");
        assertEq(manager.lastCaller(), address(controller), "the manager must see the controller");
        assertEq(manager.lastRecipient(), governance);
        assertEq(manager.protocolFeesAccrued(usdg), 0);
    }

    function test_Collect_PartialAmount() public {
        manager.setAccrued(usdg, 1000);
        vm.prank(governance);
        controller.collect(address(manager), usdg, 400, governance);
        assertEq(manager.protocolFeesAccrued(usdg), 600);
    }

    function test_Collect_OnlyOwner() public {
        manager.setAccrued(usdg, 1000);
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        controller.collect(address(manager), usdg, 0, address(0xBAD));
    }

    /// The guardian may only ever make the protocol take LESS. Collection is not that.
    function test_Collect_GuardianCannot() public {
        manager.setAccrued(usdg, 1000);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        controller.collect(address(manager), usdg, 0, guardian);
    }

    function test_Collect_RefusesToBurnTheRevenue() public {
        vm.prank(governance);
        vm.expectRevert(DeepCoreProtocolFeeControllerV2.ZeroRecipient.selector);
        controller.collect(address(manager), usdg, 0, address(0));
    }

    function test_Accrued_IsAPublicRead() public {
        manager.setAccrued(usdg, 77);
        assertEq(controller.accrued(address(manager), usdg), 77);
    }

    /* ---------------------------------------------------------------------
       SWEEP — permissionless, because the destination is not an argument.
       --------------------------------------------------------------------- */

    function test_Sweep_IsPermissionless() public {
        manager.setAccrued(usdg, 4242);

        // A complete stranger, with no role of any kind.
        vm.prank(address(0xA11CE));
        uint256 got = controller.sweep(address(manager), usdg);

        assertEq(got, 4242);
        assertEq(manager.lastRecipient(), governance, "must pay the treasury, not the caller");
        assertEq(manager.protocolFeesAccrued(usdg), 0);
    }

    /// The security property, stated as a test: a hostile caller cannot redirect anything,
    /// because there is no recipient argument to redirect.
    function test_Sweep_CannotBeRedirected() public {
        manager.setAccrued(usdg, 1000);
        address thief = address(0xBAD);

        vm.prank(thief);
        controller.sweep(address(manager), usdg);

        assertEq(manager.lastRecipient(), controller.treasury());
        assertTrue(manager.lastRecipient() != thief);
    }

    /// Reverts rather than burning gas on nothing — the settleBeneficiaries trap, avoided.
    function test_Sweep_RevertsWhenThereIsNothingToCollect() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                DeepCoreProtocolFeeControllerV2.NothingToCollect.selector, address(manager), usdg
            )
        );
        controller.sweep(address(manager), usdg);
        assertEq(manager.collectCalls(), 0, "must not touch the manager at all");
    }

    function test_Treasury_DefaultsToTheOwner() public view {
        assertEq(controller.treasury(), governance);
    }

    function test_Treasury_OwnerOnlyAndNeverZero() public {
        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        controller.setTreasury(address(0xBAD));

        vm.prank(governance);
        vm.expectRevert(DeepCoreProtocolFeeControllerV2.ZeroRecipient.selector);
        controller.setTreasury(address(0));

        vm.prank(governance);
        controller.setTreasury(address(0xC0FFEE));
        assertEq(controller.treasury(), address(0xC0FFEE));
    }

    function test_Sweep_FollowsTheTreasuryWhenItMoves() public {
        vm.prank(governance);
        controller.setTreasury(address(0xC0FFEE));

        manager.setAccrued(usdg, 500);
        vm.prank(address(0xA11CE));
        controller.sweep(address(manager), usdg);
        assertEq(manager.lastRecipient(), address(0xC0FFEE));
    }

    /* ---------------------------------------------------------------------
       REPRICING AN EXISTING POOL — core stamps the fee at initialize and never
       re-reads the controller, so this is the ONLY route to a live pool.
       --------------------------------------------------------------------- */

    function test_SetPoolProtocolFee_ReachesAnExistingPool() public {
        PoolKey memory key = _key(3000);
        uint24 packed = controller.packFee(999, 999);

        vm.prank(governance);
        controller.setPoolProtocolFee(address(manager), key, packed);

        assertEq(manager.poolProtocolFee(key.toId()), packed);
        assertEq(manager.lastCaller(), address(controller), "core admits only the controller");
    }

    /// The bulk-fix path: a pool created while the fee was zero, brought up to policy.
    function test_SyncPoolToPolicy_FixesAPoolLeftBehind() public {
        PoolKey memory key = _key(3000);
        assertEq(manager.poolProtocolFee(key.toId()), 0, "starts unpriced");

        vm.prank(governance);
        uint24 applied = controller.syncPoolToPolicy(address(manager), key);

        assertEq(applied, uint24(999) | (uint24(999) << 12));
        assertEq(manager.poolProtocolFee(key.toId()), applied);
    }

    function test_SyncPoolToPolicy_AppliesTheDynamicRuleToLaunchPools() public {
        PoolKey memory key = _key(LPFeeLibrary.DYNAMIC_FEE_FLAG);
        vm.prank(governance);
        uint24 applied = controller.syncPoolToPolicy(address(manager), key);
        assertEq(applied & 0xFFF, controller.DYNAMIC_FEE_PIPS());
    }

    function test_Repricing_IsOwnerOnly() public {
        PoolKey memory key = _key(3000);
        vm.startPrank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        controller.setPoolProtocolFee(address(manager), key, 0);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBAD)));
        controller.syncPoolToPolicy(address(manager), key);
        vm.stopPrank();
    }

    /// Guardian may reduce, never reprice — repricing can raise.
    function test_Repricing_GuardianCannot() public {
        PoolKey memory key = _key(3000);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        controller.syncPoolToPolicy(address(manager), key);
    }

    function test_PackFee_RefusesAboveTheCap() public {
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreProtocolFeeControllerV2.FeeExceedsMaximum.selector, 4001, 4000)
        );
        controller.packFee(4001, 100);
    }

    function test_PackFee_MatchesTheHotPathLayout() public view {
        assertEq(controller.packFee(999, 999), controller.protocolFeeForPool(_key(3000)));
    }

    /* ---------------------------------------------------------------------
       OWNERSHIP
       --------------------------------------------------------------------- */

    /// An unowned controller cannot collect, so every later fee would be unreachable — the exact
    /// defect V2 was written to repair.
    function test_RenounceOwnershipIsDisabled() public {
        vm.prank(governance);
        vm.expectRevert(DeepCoreProtocolFeeControllerV2.RenounceDisabled.selector);
        controller.renounceOwnership();
    }

    /// L-1 (2026-09-18): a misdirected ERC-20 leaves through the owner, and only the owner.
    function test_RescueERC20_OwnerOnly_WholeBalance() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY", 18);
        vm.prank(governance);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreProtocolFeeControllerV2.NothingToRescue.selector, address(stray)));
        controller.rescueERC20(address(stray), guardian);

        stray.mint(address(controller), 4e18);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        controller.rescueERC20(address(stray), guardian);
        vm.prank(governance);
        vm.expectRevert(DeepCoreProtocolFeeControllerV2.RescueToZero.selector);
        controller.rescueERC20(address(stray), address(0));

        vm.prank(governance);
        vm.expectEmit(true, true, false, true, address(controller));
        emit DeepCoreProtocolFeeControllerV2.ERC20Rescued(address(stray), address(0xBEEF), 4e18);
        controller.rescueERC20(address(stray), address(0xBEEF));
        assertEq(stray.balanceOf(address(0xBEEF)), 4e18);
        assertEq(stray.balanceOf(address(controller)), 0);
    }

    function test_GuardianMayDisableFeesButNotReEnableThem() public {
        vm.prank(guardian);
        controller.emergencyDisableFees();
        assertTrue(controller.feesDisabled());

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        controller.setFeesDisabled(false);

        vm.prank(governance);
        controller.setFeesDisabled(false);
        assertFalse(controller.feesDisabled());
    }

    function test_SettersRejectAFeeAboveTheCoreCap() public {
        vm.startPrank(governance);
        vm.expectRevert(
            abi.encodeWithSelector(DeepCoreProtocolFeeControllerV2.FeeExceedsMaximum.selector, 4001, 4000)
        );
        controller.setTierFee(3000, true, 4001, 100);
        vm.stopPrank();
    }
}
