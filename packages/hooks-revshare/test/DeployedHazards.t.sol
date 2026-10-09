// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

import {TokenFixture} from "infinity-core/test/helpers/TokenFixture.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

import {RevShareHook} from "../src/RevShareHook.sol";

/**
 * ####### HAZARDS OF AN EARLIER REVSHAREHOOK, AND THE FIXES THAT ANSWER THEM #######
 *
 * An earlier version of `RevShareHook` (in the codebase DeepCore was forked from) carried five
 * hazards. This file used to pin that behaviour; the fixes have landed in this source tree, so the
 * tests were inverted rather than deleted: each `test_FIXED_*` below asserts the new behaviour and
 * states, in its own comment, what the earlier version did instead. They are regression guards:
 * one starting to FAIL means a hazard has come back.
 *
 *   B1  renounceOwnership()          -> FIXED. Overridden to revert.
 *   B3  empty roster + freezeConfig  -> FIXED. Three guards, none reachable around.
 *   B4  freezeConfig is irreversible -> STILL TRUE, and correct. Unchanged below.
 *   B5  a matured proposal is eternal-> FIXED. Expiry, plus clearing on reduce/disable.
 *   3b  delay sized for the wrong clock -> FIXED. Seconds of block.timestamp. `test_FIXED_B3b_*`.
 *
 * Everything here runs against a fresh local deployment. DeepCore has no deployed RevShareHook.
 */
contract DeployedHazardsTest is Test, Deployers, TokenFixture {
    Vault vault;
    CLPoolManager poolManager;
    RevShareHook hook;
    CLPoolManagerRouter router;

    PoolKey key;
    PoolKey controlKey;
    PoolId poolId;

    address constant GOVERNANCE = address(0x600E);
    address constant GUARDIAN = address(0x6A47);
    address constant TREASURY = address(0x7EEA);
    address constant ALICE = address(0xA11CE);

    uint24 constant LP_FEE = 3000;
    int24 constant TICK_SPACING = 60;
    uint24 constant FEE_PIPS = 10_000; // 1%
    int256 constant SWAP_AMOUNT = -1 ether;


    /// @dev The floor, in seconds of `block.timestamp`. No block time is declared anywhere.
    uint40 constant CONFIG_DELAY = 12 hours;

    function setUp() public {
        (vault, poolManager) = createFreshManager();
        hook = new RevShareHook(poolManager, GOVERNANCE, GUARDIAN, CONFIG_DELAY, 8);
        router = new CLPoolManagerRouter(vault, poolManager);

        initializeTokens();
        mint(1_000_000 ether);

        key = _key(hook);
        poolId = key.toId();
        controlKey = _key(IHooks(address(0)));

        // The whole cut to route 2, and NO roster. This is the configuration B3 is about, and
        // `_validateParams` accepts it without a murmur.
        /* THREE STEPS, and the order is the fix landing rather than ceremony.
           `_validateParams` now rejects a non-zero `beneficiaryBps` while
           `totalWeight` is zero - the twin of `DistributorRequired`, whose
           absence let a pool accrue 100% of its cut into a pot with nobody on
           the other end and then `freezeConfig` the repair away. `configure`
           is what establishes ownership, and `setBeneficiaries` needs an owner,
           so the claim happens LP-only first. All three are pre-initialisation,
           so nothing has traded. */
        hook.configure(key, _params(FEE_PIPS, 10_000, 0, 0, address(0)));
        hook.setBeneficiaries(key, _roster(TREASURY, 1));
        hook.configure(key, _params(FEE_PIPS, 0, 10_000, 0, address(0)));
        poolManager.initialize(key, SQRT_RATIO_1_1);
        poolManager.initialize(controlKey, SQRT_RATIO_1_1);

        IERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        _addLiquidity(key);
        _addLiquidity(controlKey);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _key(IHooks h) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: h,
            poolManager: poolManager,
            fee: LP_FEE,
            parameters: CLPoolParametersHelper.setTickSpacing(
                bytes32(uint256(address(h) == address(0) ? 0 : h.getHooksRegistrationBitmap())), TICK_SPACING
            )
        });
    }

    function _params(uint24 feePips, uint16 lpBps, uint16 benBps, uint16 distBps, address distributor)
        internal
        pure
        returns (RevShareHook.ConfigParams memory)
    {
        return RevShareHook.ConfigParams({
            feePips: feePips,
            lpDonateBps: lpBps,
            beneficiaryBps: benBps,
            distributorBps: distBps,
            distributor: distributor,
            enabled: true
        });
    }

    function _addLiquidity(PoolKey memory k) internal {
        router.modifyPosition(
            k,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: 100_000 ether,
                salt: 0
            }),
            ZERO_BYTES
        );
    }

    function _swap(PoolKey memory k, int256 amountSpecified, bool zeroForOne) internal returns (BalanceDelta) {
        return router.swap(
            k,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ZERO_BYTES
        );
    }

    function _roster(address a, uint96 w) internal pure returns (RevShareHook.Beneficiary[] memory r) {
        r = new RevShareHook.Beneficiary[](1);
        r[0] = RevShareHook.Beneficiary({recipient: a, weight: w});
    }

    /*//////////////////////////////////////////////////////////////
       B1 - renounceOwnership() - FIXED, was live on the earlier hook
    //////////////////////////////////////////////////////////////*/

    /// @dev THE EARLIER HOOK: stock OZ `Ownable.renounceOwnership` is reachable, and what it
    /// costs is asymmetric. The guardian may only PAUSE; only the owner may unpause or move the
    /// guardian. So renouncing while paused freezes the hook off permanently, and renouncing while
    /// unpaused throws away the kill switch. Neither is a reduction in privilege.
    ///
    /// THIS HOOK: overridden to revert for everybody, `MerkleEpochDistributor` being the
    /// reference. `transferOwnership` - two-step, so it cannot land somewhere unreachable - is the
    /// bounded form of the same intent and is untouched.
    function test_FIXED_B1_renounceOwnershipReverts() public {
        vm.prank(GOVERNANCE);
        vm.expectRevert(RevShareHook.RenounceDisabled.selector);
        hook.renounceOwnership();

        assertEq(hook.owner(), GOVERNANCE, "ownership is exactly where it was");
    }

    /// @dev The specific outcome the override prevents: a hook paused forever with nobody able to
    /// unpause it. On the earlier hook the second half of this test would succeed.
    function test_FIXED_B1_thePauseSwitchSurvivesAnAttemptedRenounce() public {
        vm.prank(GUARDIAN);
        hook.setPaused(true);

        vm.prank(GOVERNANCE);
        vm.expectRevert(RevShareHook.RenounceDisabled.selector);
        hook.renounceOwnership();

        // The owner is still there, so the incident is still recoverable.
        vm.prank(GOVERNANCE);
        hook.setPaused(false);
        assertFalse(hook.paused());

        _swap(key, SWAP_AMOUNT, true);
        assertGt(hook.pendingBeneficiary(poolId, currency1), 0, "the hook takes its cut again");
    }

    /// @dev The bound on the original damage, kept because it is what stops the finding being
    /// overstated: even a successful renounce never stranded accrued value. `claim`,
    /// `settleBeneficiaries`, `redeem` and `pullDistributorShare` are permissionless.
    function test_FIXED_B1_accruedValueWasNeverAtRiskEitherWay() public {
        _swap(key, SWAP_AMOUNT, true);

        hook.settleBeneficiaries(key, currency1);
        uint256 owed = hook.claimable(TREASURY, currency1);
        assertGt(owed, 0);
        vm.prank(TREASURY);
        assertEq(hook.claim(currency1, TREASURY), owed);
    }

    /*//////////////////////////////////////////////////////////////
       B3 - beneficiaryBps > 0 WITH AN EMPTY ROSTER - FIXED
    //////////////////////////////////////////////////////////////*/

    /// @dev THE EARLIER HOOK: `_validateParams` enforced the distributor invariant
    /// (`distributorBps != 0` needs a distributor) and NOT its beneficiary twin, and
    /// `setBeneficiaries` accepted a zero-length roster despite `InvalidBeneficiaries` being
    /// documented as "Roster is empty, too long, or contains an invalid entry". With
    /// `_totalWeight == 0`, `settleBeneficiaries` returned early rather than reverting, so the pot
    /// accrued silently and no keeper log looked wrong. `freezeConfig` then removed the repair.
    ///
    /// THIS HOOK: the configuration that starts that story cannot be written. `setUp` above is the
    /// proof in miniature - it now takes three calls to reach the same pool, because the one-call
    /// version is the bug.
    function test_FIXED_B3_aBeneficiaryShareWithNoRosterIsUnwritable() public {
        PoolKey memory fresh = _key(hook);
        fresh.fee = 500;
        fresh.parameters =
            CLPoolParametersHelper.setTickSpacing(bytes32(uint256(hook.getHooksRegistrationBitmap())), int24(10));

        vm.expectRevert(abi.encodeWithSelector(RevShareHook.BeneficiariesRequired.selector, fresh.toId()));
        hook.configure(fresh, _params(FEE_PIPS, 0, 10_000, 0, address(0)));
    }

    /// @dev And the roster cannot be taken away afterwards either, which is the half that turned a
    /// misconfiguration into a permanent one. On the earlier hook this call succeeds silently.
    function test_FIXED_B3_theRosterCannotBeEmptiedUnderALiveShare() public {
        assertEq(hook.getConfig(poolId).beneficiaryBps, 10_000);
        assertGt(hook.totalWeight(poolId), 0);

        vm.expectRevert(abi.encodeWithSelector(RevShareHook.BeneficiariesRequired.selector, poolId));
        hook.setBeneficiaries(key, new RevShareHook.Beneficiary[](0));
    }

    /// @dev The end of the original story, asserted as unreachable. The pot always has a roster
    /// behind it, so a freeze can never seal value away from everybody.
    function test_FIXED_B3_whateverIsFrozenIsPayable() public {
        _swap(key, SWAP_AMOUNT, true);
        hook.freezeConfig(key);

        hook.settleBeneficiaries(key, currency1);
        uint256 owed = hook.claimable(TREASURY, currency1);
        assertGt(owed, 0, "a frozen pool's pot is still payable");
        vm.prank(TREASURY);
        assertEq(hook.claim(currency1, TREASURY), owed);
    }

    /*//////////////////////////////////////////////////////////////
       3b - THE DELAY WAS SIZED FOR THE WRONG CLOCK - FIXED BY LEAVING BLOCKS
    //////////////////////////////////////////////////////////////*/

    /// @dev THE EARLIER HOOKS. One had `CONFIG_DELAY_BLOCKS = 3600` (a constant), which on an Arbitrum
    /// Nitro chain - where `block.number` is Ethereum's ~12 s block - is ~12 hours. Another took
    /// `432 000` blocks with `blockTimeCentis = 10`, the RPC's 0.1 s L2 block time, and so had a ~60-DAY
    /// delay and a ~360-day proposal TTL. Both were block-denominated, and both depended on somebody
    /// declaring the right clock.
    ///
    /// THIS HOOK: seconds of `block.timestamp`, and no block-time argument exists to get wrong.
    function test_FIXED_B3b_theDelayIsTwelveHoursOfTimestamp() public view {
        assertEq(hook.CLOCK_MODE(), "mode=timestamp");
        assertEq(uint256(hook.CONFIG_DELAY_SECONDS()), 12 hours);
        assertEq(hook.MIN_CONFIG_DELAY_SECONDS(), 12 hours);
        assertEq(hook.MAX_CONFIG_DELAY_SECONDS(), 14 days);
    }

    /// @dev THE REGRESSION GUARD THAT FAILS AGAINST EVERY BLOCK-NUMBERED HOOK: a hundred million
    /// blocks with no time passing must not mature a fee raise, and twelve hours with no block
    /// rolled must.
    function test_FIXED_B3b_onlyTimeMaturesAProposal() public {
        hook.proposeConfig(key, _params(hook.MAX_FEE_PIPS(), 0, 10_000, 0, address(0)));
        uint40 due = hook.getPendingConfig(poolId).effectiveAt;
        assertEq(uint256(due), block.timestamp + 12 hours);

        vm.roll(block.number + 100_000_000);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.PendingConfigNotDue.selector, poolId, due));
        hook.applyPendingConfig(key);

        uint256 blockBefore = block.number;
        vm.warp(due);
        assertEq(block.number, blockBefore);
        vm.prank(ALICE);
        hook.applyPendingConfig(key);
        assertEq(hook.getConfig(poolId).feePips, hook.MAX_FEE_PIPS());
    }

    /// @dev The floor is not negotiable by a deployment, and neither is the ceiling. MUTATION-CHECKED:
    /// deleting the `< MIN_CONFIG_DELAY_SECONDS` branch makes the first expectation fail.
    function test_FIXED_B3b_aSubFloorOrAbsurdDelayCannotBeDeployed() public {
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.ConfigDelayTooShort.selector, 12 hours - 1, 12 hours));
        new RevShareHook(poolManager, GOVERNANCE, GUARDIAN, uint40(12 hours - 1), 8);

        // 3 600 - the retired hook's number - read as seconds would be one hour. Refused.
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.ConfigDelayTooShort.selector, 3600, 12 hours));
        new RevShareHook(poolManager, GOVERNANCE, GUARDIAN, 3600, 8);

        vm.expectRevert(abi.encodeWithSelector(RevShareHook.ConfigDelayTooLong.selector, 14 days + 1, 14 days));
        new RevShareHook(poolManager, GOVERNANCE, GUARDIAN, uint40(14 days + 1), 8);

        RevShareHook longer = new RevShareHook(poolManager, GOVERNANCE, GUARDIAN, uint40(14 days), 8);
        assertEq(uint256(longer.CONFIG_DELAY_SECONDS()), 14 days, "a tenant may choose a longer notice");
    }

    function testFuzz_FIXED_B3b_acceptedIffInsideTheBounds(uint40 delaySeconds) public {
        if (delaySeconds < 12 hours) {
            vm.expectRevert(abi.encodeWithSelector(RevShareHook.ConfigDelayTooShort.selector, delaySeconds, 12 hours));
            new RevShareHook(poolManager, GOVERNANCE, GUARDIAN, delaySeconds, 8);
        } else if (delaySeconds > 14 days) {
            vm.expectRevert(abi.encodeWithSelector(RevShareHook.ConfigDelayTooLong.selector, delaySeconds, 14 days));
            new RevShareHook(poolManager, GOVERNANCE, GUARDIAN, delaySeconds, 8);
        } else {
            RevShareHook h = new RevShareHook(poolManager, GOVERNANCE, GUARDIAN, delaySeconds, 8);
            assertEq(h.CONFIG_DELAY_SECONDS(), delaySeconds);
        }
    }

    /// @dev The Nitro clock bound, with numbers: the sequencer may run at most one hour ahead, so
    /// the worst forward skew removes 1/12 of a 12 h notice. A proposal made at t cannot be applied
    /// before t + 11 h of REAL time even if the sequencer jumps the clock an hour in one block.
    function test_FIXED_B3b_aOneHourForwardSkewLeavesElevenHoursOfNotice() public {
        hook.proposeConfig(key, _params(hook.MAX_FEE_PIPS(), 0, 10_000, 0, address(0)));
        // Read back rather than cached in a local: under via-IR a local copy of
        // `block.timestamp` can be re-evaluated after `vm.warp`.
        uint40 due = hook.getPendingConfig(poolId).effectiveAt;
        uint256 proposedAt = uint256(due) - 12 hours;
        // Real time proposedAt + 11h - 1s, sequencer clock one hour ahead of it.
        vm.warp(proposedAt + 11 hours - 1 + 1 hours);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.PendingConfigNotDue.selector, poolId, due));
        hook.applyPendingConfig(key);
        // And one more second of the skewed clock is exactly twelve hours: due.
        vm.warp(uint256(due));
        vm.prank(ALICE);
        hook.applyPendingConfig(key);
    }

    /*//////////////////////////////////////////////////////////////
       B4 - freezeConfig IS IRREVERSIBLE AND CHEAPER THAN RAISING A FEE
    //////////////////////////////////////////////////////////////*/

    /// @dev Immediate and one-way, while a fee RAISE costs `CONFIG_DELAY_SECONDS`. That asymmetry
    /// is deliberate under this contract's own rule - delay belongs on escalation, never on
    /// reduction, and a freeze only ever reduces the owner's power. It is recorded here because
    /// the CONSEQUENCE is irreversible while the friction is a single click, and because it is the
    /// call that turns B3 from a mistake into a permanent one. A UI must confirm it like a burn.
    function test_HAZARD_B4_freezeIsInstantWhileRaisingAFeeWaits() public {
        hook.proposeConfig(key, _params(50_000, 0, 10_000, 0, address(0)));
        vm.expectRevert(
            abi.encodeWithSelector(
                RevShareHook.PendingConfigNotDue.selector, poolId, uint40(block.timestamp) + hook.CONFIG_DELAY_SECONDS()
            )
        );
        hook.applyPendingConfig(key);

        // No delay, no second step, no undo.
        hook.freezeConfig(key);
        assertTrue(hook.getConfig(poolId).frozen);

        vm.expectRevert(abi.encodeWithSelector(RevShareHook.ConfigFrozen.selector, poolId));
        hook.proposeConfig(key, _params(0, 0, 10_000, 0, address(0)));
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.ConfigFrozen.selector, poolId));
        hook.reduceFee(key, 1);
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.ConfigFrozen.selector, poolId));
        hook.disable(key);
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.ConfigFrozen.selector, poolId));
        hook.transferPoolOwnership(key, ALICE);
    }

    /*//////////////////////////////////////////////////////////////
       B5 - A MATURED PROPOSAL NEVER EXPIRED, AND disable() LEFT IT ARMED - FIXED
    //////////////////////////////////////////////////////////////*/

    /// @dev THE EARLIER HOOK: `reduceFee` and `disable` wrote `_configs` and never touched
    /// `_pending`, and a matured proposal had no expiry. So the last `ConfigUpdated` a pool emitted
    /// could read `feePips: 0, enabled: false` - "revenue share turned off" to any indexer or UI -
    /// while a 10%/enabled proposal sat armed, applicable by ANYBODY, at any time, including in
    /// the block immediately in front of a large swap.
    ///
    /// THIS HOOK: a public reduction means what it says. Both calls clear the proposal and emit
    /// `ConfigProposalCancelled`, so there is no armed state hiding behind an "off" pool.
    function test_FIXED_B5_disableClearsAMaturedProposal() public {
        hook.proposeConfig(key, _params(hook.MAX_FEE_PIPS(), 0, 10_000, 0, address(0)));
        vm.warp(block.timestamp + hook.CONFIG_DELAY_SECONDS());
        assertGt(hook.getPendingConfig(poolId).effectiveAt, 0, "armed and due");

        vm.expectEmit(true, false, false, false, address(hook));
        emit RevShareHook.ConfigProposalCancelled(poolId);
        hook.disable(key);

        assertEq(hook.getPendingConfig(poolId).effectiveAt, 0, "disable retracted it");

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.NoPendingConfig.selector, poolId));
        hook.applyPendingConfig(key);
    }

    /// @dev The same for `reduceFee`, which is the one a UI is more likely to render as "the fee
    /// went down" and therefore the one more likely to mislead.
    function test_FIXED_B5_reduceFeeClearsAMaturedProposal() public {
        hook.proposeConfig(key, _params(hook.MAX_FEE_PIPS(), 0, 10_000, 0, address(0)));
        vm.warp(block.timestamp + hook.CONFIG_DELAY_SECONDS());

        hook.reduceFee(key, 0);
        assertEq(hook.getPendingConfig(poolId).effectiveAt, 0);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.NoPendingConfig.selector, poolId));
        hook.applyPendingConfig(key);

        _swap(key, SWAP_AMOUNT, true);
        assertEq(hook.pendingBeneficiary(poolId, currency1), 0, "off is off, and stays off");
    }

    /// @dev The other half: even an untouched proposal now dies of old age. A pool owner who wants
    /// to hold a raise indefinitely has to keep re-proposing, and each re-proposal restarts the
    /// full delay in public.
    function test_FIXED_B5_aMaturedProposalExpires() public {
        hook.proposeConfig(key, _params(hook.MAX_FEE_PIPS(), 0, 10_000, 0, address(0)));
        RevShareHook.PendingConfig memory pending = hook.getPendingConfig(poolId);
        assertGt(pending.expiresAt, pending.effectiveAt, "a window, not a deadline");

        // Inside the window it applies.
        vm.warp(pending.effectiveAt);
        vm.prank(ALICE);
        hook.applyPendingConfig(key);
        assertEq(hook.getConfig(poolId).feePips, hook.MAX_FEE_PIPS());

        // Propose again and let this one rot.
        hook.reduceFee(key, 1);
        hook.proposeConfig(key, _params(hook.MAX_FEE_PIPS(), 0, 10_000, 0, address(0)));
        RevShareHook.PendingConfig memory second = hook.getPendingConfig(poolId);
        vm.warp(uint256(second.expiresAt) + 1);

        vm.prank(ALICE);
        vm.expectRevert(
            abi.encodeWithSelector(RevShareHook.PendingConfigExpired.selector, poolId, second.expiresAt)
        );
        hook.applyPendingConfig(key);
        assertEq(hook.getConfig(poolId).feePips, 1, "the ambush never fired");
    }

    /// @dev The window is three days of `block.timestamp`, on every chain, with nothing declared.
    function test_FIXED_B5_theProposalWindowIsThreeDays() public {
        assertEq(uint256(hook.CONFIG_PROPOSAL_TTL_SECONDS()), 3 days);
        hook.proposeConfig(key, _params(hook.MAX_FEE_PIPS(), 0, 10_000, 0, address(0)));
        RevShareHook.PendingConfig memory p = hook.getPendingConfig(poolId);
        assertEq(uint256(p.expiresAt) - p.effectiveAt, 3 days);
    }

    /// @dev TTL BOUNDARY, both sides, MUTATION-CHECKED: turning `>` into `>=` fails the first
    /// apply; deleting the expiry check fails the second.
    function test_FIXED_B5_expiresAtIsTheLastApplicableSecond() public {
        hook.proposeConfig(key, _params(hook.MAX_FEE_PIPS(), 0, 10_000, 0, address(0)));
        RevShareHook.PendingConfig memory p = hook.getPendingConfig(poolId);

        uint256 snap = vm.snapshotState();
        vm.warp(p.expiresAt);
        vm.prank(ALICE);
        hook.applyPendingConfig(key);
        assertEq(hook.getConfig(poolId).feePips, hook.MAX_FEE_PIPS(), "applies at expiresAt");
        vm.revertToState(snap);

        vm.warp(uint256(p.expiresAt) + 1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.PendingConfigExpired.selector, poolId, p.expiresAt));
        hook.applyPendingConfig(key);
    }

    /// @dev Rolling blocks cannot expire a proposal either - the TTL is time, not blocks.
    function test_FIXED_B5_blocksAloneNeverExpireAProposal() public {
        hook.proposeConfig(key, _params(hook.MAX_FEE_PIPS(), 0, 10_000, 0, address(0)));
        RevShareHook.PendingConfig memory p = hook.getPendingConfig(poolId);
        vm.warp(p.effectiveAt);
        vm.roll(block.number + 1_000_000_000);
        vm.prank(ALICE);
        hook.applyPendingConfig(key);
        assertEq(hook.getConfig(poolId).feePips, hook.MAX_FEE_PIPS());
    }

    /// @dev THE HONEST MITIGATION on the earlier hook, kept because it is what bounds the finding
    /// there and it is still worth knowing. The cut lands on the unspecified currency and
    /// `CLHooks.afterSwap` does `delta = delta - hookDelta`, so the amount the SWAPPER receives is
    /// already net of it - the exact quantity a router compares against `amountOutMinimum`
    /// (`CLRouterBase._swapExactInputSingle` -> `IInfinityRouter.TooLittleReceived`). A trader with
    /// any sane slippage bound reverts rather than being charged, because `MAX_FEE_PIPS` is 10%
    /// and slippage tolerances are not.
    ///
    /// It bounds NOTHING for a caller that takes its own vault lock, or sets the minimum to zero,
    /// which is why the expiry above is the real fix and this is only the floor under it.
    function test_theAmbushIsVisibleInTheCallerDeltaARouterBoundsOn() public {
        // Gross output for the same swap through an identical hookless pool.
        BalanceDelta control = _swap(controlKey, SWAP_AMOUNT, true);
        uint256 gross = uint256(int256(control.amount1()));

        hook.proposeConfig(key, _params(hook.MAX_FEE_PIPS(), 0, 10_000, 0, address(0)));
        vm.warp(block.timestamp + hook.CONFIG_DELAY_SECONDS());
        vm.prank(ALICE);
        hook.applyPendingConfig(key);

        BalanceDelta hooked = _swap(key, SWAP_AMOUNT, true);
        uint256 net = uint256(int256(hooked.amount1()));

        // The full 10% is inside the number a router checks, not hidden beside it.
        assertEq(gross - net, (gross * hook.MAX_FEE_PIPS()) / hook.PIPS_DENOMINATOR());
        assertLt(net, (gross * 99) / 100, "far outside any ordinary slippage tolerance");
    }
}
