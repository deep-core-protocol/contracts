// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

import {TokenFixture} from "infinity-core/test/helpers/TokenFixture.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

import {BaseCLHook} from "deepcore-hooks/src/base/BaseCLHook.sol";
import {RevShareHook} from "../src/RevShareHook.sol";
import {BlacklistERC20} from "./mocks/Mocks.sol";

/// @dev Records the `sender` core hands to `afterSwap`, so the test suite can pin the fact the
/// whole design rests on: it is the vault locker, never the trader.
contract SenderRecordingHook is RevShareHook {
    address public lastAfterSwapSender;

    constructor(ICLPoolManager pm, address owner_, address guardian_, uint40 delaySeconds)
        RevShareHook(pm, owner_, guardian_, delaySeconds, 8)
    {}

    function _afterSwap(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) internal override returns (bytes4, int128) {
        lastAfterSwapSender = sender;
        return super._afterSwap(sender, key, params, delta, hookData);
    }
}

contract RevShareHookTest is Test, Deployers, TokenFixture {
    using LPFeeLibrary for uint24;

    Vault vault;
    CLPoolManager poolManager;
    RevShareHook hook;
    CLPoolManagerRouter router;

    PoolKey key;
    PoolId poolId;

    /// @dev A hookless pool with identical currencies, fee, spacing and liquidity. Swapping the
    /// same amount through it yields the GROSS output, which is what the revenue share is a
    /// percentage of - so fee arithmetic can be asserted exactly instead of approximately.
    PoolKey controlKey;

    address constant GOVERNANCE = address(0x600E);
    address constant GUARDIAN = address(0x6A47);
    address constant TREASURY = address(0x7EEA);
    address constant CHARITY = address(0xC4A1);
    address constant DISTRIBUTOR = address(0xD157);
    address constant ALICE = address(0xA11CE);

    uint24 constant LP_FEE = 3000; // 0.30%, static
    int24 constant TICK_SPACING = 60;
    uint24 constant FEE_PIPS = 10_000; // 1% of the unspecified amount
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

    function _roster(address a, uint96 wa) internal pure returns (RevShareHook.Beneficiary[] memory r) {
        r = new RevShareHook.Beneficiary[](1);
        r[0] = RevShareHook.Beneficiary({recipient: a, weight: wa});
    }

    function _roster(address a, uint96 wa, address b, uint96 wb)
        internal
        pure
        returns (RevShareHook.Beneficiary[] memory r)
    {
        r = new RevShareHook.Beneficiary[](2);
        r[0] = RevShareHook.Beneficiary({recipient: a, weight: wa});
        r[1] = RevShareHook.Beneficiary({recipient: b, weight: wb});
    }

    /// @dev Core wraps a reverting hook in an ERC-7751 `WrappedError`. Rebuild the envelope so the
    /// tests assert on the hook's own error rather than on a generic failure. The `details` field
    /// is `Hooks.HookCallFailed()`, which is what `Hooks.callHook` passes to
    /// `CustomRevert.bubbleUpAndRevertWith` - not empty bytes.
    function _wrapped(bytes4 selector, bytes memory inner) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(hook),
            selector,
            inner,
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /*//////////////////////////////////////////////////////////////
        THE SOLVENCY INVARIANT

        Two statements, checked after every state-changing test action.

        (1) The vault is not short. Every ERC20 the vault holds is accounted for by exactly two
            claimants: the pool manager's app reserve, and outstanding ERC-6909 claims. If the
            hook could ever settle without paying, this equality would break in the vault's
            favour first - a drain shows up here before it shows up as a stolen token.

        (2) The hook is not short. Everything it has promised (`totalOwed`) is covered by what it
            can actually deliver (tokens held plus redeemable claims). A hook that credits more
            than it took would break this.
    //////////////////////////////////////////////////////////////*/

    function _assertSolvent() internal view {
        _assertSolventFor(currency0);
        _assertSolventFor(currency1);
    }

    function _assertSolventFor(Currency c) internal view {
        uint256 vaultBalance = IERC20(Currency.unwrap(c)).balanceOf(address(vault));
        uint256 accounted = vault.reservesOfApp(address(poolManager), c) + vault.balanceOf(address(hook), c)
            + vault.balanceOf(address(router), c) + vault.balanceOf(address(this), c);
        assertEq(vaultBalance, accounted, "vault holds tokens nobody has a claim on, or is short");

        assertGe(hook.backing(c), hook.totalOwed(c), "hook owes more than it can pay");
    }

    /*//////////////////////////////////////////////////////////////
                          PERMISSIONS AND WIRING
    //////////////////////////////////////////////////////////////*/

    function test_bitmap_isBeforeInitializePlusAfterSwapWithDelta() public view {
        uint16 bitmap = hook.getHooksRegistrationBitmap();
        assertEq(bitmap, uint16(1) | uint16(1 << 7) | uint16(1 << 11));
        // bit 11 (afterSwapReturnsDelta) requires bit 7 (afterSwap); assert the dependency holds.
        assertTrue(bitmap & (1 << 11) == 0 || bitmap & (1 << 7) != 0);
        // and that neither reserved bit is set
        assertEq(bitmap & 0xC000, 0);
    }

    function test_callbacks_onlyPoolManager() public {
        vm.expectRevert(BaseCLHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_RATIO_1_1);

        vm.expectRevert(BaseCLHook.NotPoolManager.selector);
        hook.afterSwap(
            address(this),
            key,
            ICLPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            BalanceDelta.wrap(0),
            ZERO_BYTES
        );
    }

    function test_unimplementedCallbacks_revert() public {
        // Declared-but-unimplemented permissions must fail loudly; these are not declared at all,
        // so the base class's reverting defaults are what an attacker would reach.
        vm.prank(address(poolManager));
        vm.expectRevert(BaseCLHook.HookNotImplemented.selector);
        hook.beforeSwap(
            address(this),
            key,
            ICLPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            ZERO_BYTES
        );
    }

    function test_beforeInitialize_rejectsDynamicFeePool() public {
        PoolKey memory dyn = _key(hook);
        dyn.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;

        vm.expectRevert(RevShareHook.PoolMustUseStaticFee.selector);
        hook.configure(dyn, _params(FEE_PIPS, 10_000, 0, 0, address(0)));

        vm.expectRevert(
            _wrapped(ICLHooks.beforeInitialize.selector, abi.encodeWithSelector(RevShareHook.PoolMustUseStaticFee.selector))
        );
        poolManager.initialize(dyn, SQRT_RATIO_1_1);
    }

    function test_beforeInitialize_rejectsUnconfiguredPool() public {
        PoolKey memory fresh = _key(hook);
        fresh.fee = 500;
        fresh.parameters = CLPoolParametersHelper.setTickSpacing(
            bytes32(uint256(hook.getHooksRegistrationBitmap())), int24(10)
        );

        vm.expectRevert(
            _wrapped(
                ICLHooks.beforeInitialize.selector,
                abi.encodeWithSelector(RevShareHook.PoolNotConfigured.selector, fresh.toId())
            )
        );
        poolManager.initialize(fresh, SQRT_RATIO_1_1);
    }

    function test_lockAcquired_notCallableDirectly() public {
        vm.expectRevert(RevShareHook.UnexpectedLockCallback.selector);
        hook.lockAcquired(abi.encode(currency0, uint256(1)));

        // Even impersonating the vault fails, because the hook only ever expects the callback
        // inside its own `redeem`.
        vm.prank(address(vault));
        vm.expectRevert(RevShareHook.UnexpectedLockCallback.selector);
        hook.lockAcquired(abi.encode(currency0, uint256(1)));
    }

    function test_receive_rejectsStrayNative() public {
        vm.deal(ALICE, 1 ether);
        vm.prank(ALICE);
        (bool ok,) = address(hook).call{value: 1 ether}("");
        assertFalse(ok);
    }

    /// @dev The constraint that shapes the whole design. If this ever fails, every per-wallet idea
    /// that was rejected on its account becomes worth revisiting - and every one that was shipped
    /// on the assumption becomes suspect.
    function test_sender_isTheLockerNotTheTrader() public {
        SenderRecordingHook recorder = new SenderRecordingHook(poolManager, GOVERNANCE, GUARDIAN, CONFIG_DELAY);
        PoolKey memory k = _key(recorder);
        k.fee = 500;
        k.parameters =
            CLPoolParametersHelper.setTickSpacing(bytes32(uint256(recorder.getHooksRegistrationBitmap())), int24(10));

        // Claim LP-only, set the roster, then take the beneficiary share. See `setUp`.
        recorder.configure(k, _params(FEE_PIPS, 10_000, 0, 0, address(0)));
        recorder.setBeneficiaries(k, _roster(TREASURY, 1));
        recorder.configure(k, _params(FEE_PIPS, 0, 10_000, 0, address(0)));
        poolManager.initialize(k, SQRT_RATIO_1_1);
        _addLiquidity(k);

        MockERC20(Currency.unwrap(currency0)).transfer(ALICE, 10 ether);
        vm.startPrank(ALICE);
        IERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        _swap(k, SWAP_AMOUNT, true);
        vm.stopPrank();

        assertEq(recorder.lastAfterSwapSender(), address(router), "sender must be the locker");
        assertTrue(recorder.lastAfterSwapSender() != ALICE, "sender must NOT be the trader");
    }

    /*//////////////////////////////////////////////////////////////
                             CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function test_configure_firstCallerClaimsPool() public {
        assertEq(hook.poolOwner(poolId), address(this));

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.NotPoolOwner.selector, poolId, ALICE));
        hook.configure(key, _params(0, 10_000, 0, 0, address(0)));
    }

    function test_configure_rejectsBadSplitAndFee() public {
        PoolKey memory fresh = _key(hook);
        fresh.fee = 500;
        fresh.parameters =
            CLPoolParametersHelper.setTickSpacing(bytes32(uint256(hook.getHooksRegistrationBitmap())), int24(10));

        vm.expectRevert(abi.encodeWithSelector(RevShareHook.FeeTooHigh.selector, uint24(100_001)));
        hook.configure(fresh, _params(100_001, 10_000, 0, 0, address(0)));

        vm.expectRevert(abi.encodeWithSelector(RevShareHook.SplitMustSumToDenominator.selector, uint256(9_999)));
        hook.configure(fresh, _params(1000, 9_999, 0, 0, address(0)));

        vm.expectRevert(RevShareHook.DistributorRequired.selector);
        hook.configure(fresh, _params(1000, 0, 0, 10_000, address(0)));
    }

    function test_configure_immediateBeforeInitializeThenDelayedAfter() public {
        PoolKey memory fresh = _key(hook);
        fresh.fee = 500;
        fresh.parameters =
            CLPoolParametersHelper.setTickSpacing(bytes32(uint256(hook.getHooksRegistrationBitmap())), int24(10));
        PoolId freshId = fresh.toId();

        hook.configure(fresh, _params(1000, 10_000, 0, 0, address(0)));
        // Still uninitialised: reconfiguration is free, nobody has traded.
        hook.configure(fresh, _params(2000, 10_000, 0, 0, address(0)));
        assertEq(hook.getConfig(freshId).feePips, 2000);

        poolManager.initialize(fresh, SQRT_RATIO_1_1);

        vm.expectRevert(abi.encodeWithSelector(RevShareHook.PoolAlreadyConfigured.selector, freshId));
        hook.configure(fresh, _params(3000, 10_000, 0, 0, address(0)));
    }

    function test_proposeConfig_cannotRaiseFeeWithoutTheDelay() public {
        hook.proposeConfig(key, _params(50_000, 0, 10_000, 0, address(0)));
        assertEq(hook.getConfig(poolId).feePips, FEE_PIPS, "live config must not move on propose");

        uint40 due = hook.getPendingConfig(poolId).effectiveAt;
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.PendingConfigNotDue.selector, poolId, due));
        hook.applyPendingConfig(key);

        vm.warp(block.timestamp + hook.CONFIG_DELAY_SECONDS());
        // Permissionless: the delay is the protection, not the caller.
        vm.prank(ALICE);
        hook.applyPendingConfig(key);
        assertEq(hook.getConfig(poolId).feePips, 50_000);

        vm.expectRevert(abi.encodeWithSelector(RevShareHook.NoPendingConfig.selector, poolId));
        hook.applyPendingConfig(key);
    }

    function test_reduceFee_isImmediateAndCannotRaise() public {
        hook.reduceFee(key, 100);
        assertEq(hook.getConfig(poolId).feePips, 100);

        vm.expectRevert(abi.encodeWithSelector(RevShareHook.FeeNotReduced.selector, uint24(100), uint24(200)));
        hook.reduceFee(key, 200);

        vm.expectRevert(abi.encodeWithSelector(RevShareHook.FeeNotReduced.selector, uint24(100), uint24(100)));
        hook.reduceFee(key, 100);
    }

    function test_disable_stopsTheCutImmediately() public {
        hook.setBeneficiaries(key, _roster(TREASURY, 1));
        hook.disable(key);

        _swap(key, SWAP_AMOUNT, true);
        assertEq(hook.pendingBeneficiary(poolId, currency1), 0);
        _assertSolvent();
    }

    function test_freezeConfig_isPermanentAndDiscardsProposals() public {
        hook.proposeConfig(key, _params(50_000, 0, 10_000, 0, address(0)));
        hook.freezeConfig(key);

        assertEq(hook.getPendingConfig(poolId).effectiveAt, 0, "freeze must discard the proposal");

        vm.warp(block.timestamp + hook.CONFIG_DELAY_SECONDS());
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.NoPendingConfig.selector, poolId));
        hook.applyPendingConfig(key);

        vm.expectRevert(abi.encodeWithSelector(RevShareHook.ConfigFrozen.selector, poolId));
        hook.reduceFee(key, 1);
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.ConfigFrozen.selector, poolId));
        hook.proposeConfig(key, _params(1, 10_000, 0, 0, address(0)));
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.ConfigFrozen.selector, poolId));
        hook.setBeneficiaries(key, _roster(ALICE, 1));
    }

    function test_poolOwnership_isTwoStep() public {
        hook.transferPoolOwnership(key, ALICE);
        assertEq(hook.poolOwner(poolId), address(this), "ownership must not move on propose");

        vm.prank(TREASURY);
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.NotPoolOwner.selector, poolId, TREASURY));
        hook.acceptPoolOwnership(key);

        vm.prank(ALICE);
        hook.acceptPoolOwnership(key);
        assertEq(hook.poolOwner(poolId), ALICE);

        vm.expectRevert(abi.encodeWithSelector(RevShareHook.NotPoolOwner.selector, poolId, address(this)));
        hook.reduceFee(key, 1);
    }

    function test_globalPause_guardianCanOnlyPause() public {
        hook.setBeneficiaries(key, _roster(TREASURY, 1));

        vm.prank(GUARDIAN);
        hook.setPaused(true);
        _swap(key, SWAP_AMOUNT, true);
        assertEq(hook.pendingBeneficiary(poolId, currency1), 0, "paused hook must take nothing");

        vm.prank(GUARDIAN);
        vm.expectRevert(RevShareHook.NotGuardianOrOwner.selector);
        hook.setPaused(false);

        vm.prank(ALICE);
        vm.expectRevert(RevShareHook.NotGuardianOrOwner.selector);
        hook.setPaused(true);

        vm.prank(GOVERNANCE);
        hook.setPaused(false);
        _swap(key, SWAP_AMOUNT, true);
        assertGt(hook.pendingBeneficiary(poolId, currency1), 0);
        _assertSolvent();
    }

    /*//////////////////////////////////////////////////////////////
                             FEE ARITHMETIC
    //////////////////////////////////////////////////////////////*/

    /// @dev Exact against a hookless control pool: the cut is exactly `feePips` of the OUTPUT the
    /// same swap would have produced without the hook, and the trader receives the rest.
    function test_exactInput_cutIsAPercentageOfGrossOutput() public {
        hook.setBeneficiaries(key, _roster(TREASURY, 1));

        BalanceDelta control = _swap(controlKey, SWAP_AMOUNT, true);
        uint256 grossOut = uint256(int256(control.amount1()));

        BalanceDelta live = _swap(key, SWAP_AMOUNT, true);
        uint256 netOut = uint256(int256(live.amount1()));

        uint256 expectedCut = (grossOut * FEE_PIPS) / 1_000_000;
        assertEq(hook.pendingBeneficiary(poolId, currency1), expectedCut, "accrual must equal the stated percentage");
        assertEq(grossOut - netOut, expectedCut, "trader must lose exactly the cut, not a wei more");
        assertEq(uint256(-int256(live.amount0())), uint256(-int256(control.amount0())), "input side untouched");
        _assertSolvent();
    }

    /// @dev On an exact-OUTPUT swap the unspecified currency is the INPUT, so the cut is charged
    /// on what the trader pays rather than what they receive. Both are legitimate; the point is
    /// that the code handles the flip and does not silently charge the wrong side.
    function test_exactOutput_cutIsChargedOnTheInputSide() public {
        hook.setBeneficiaries(key, _roster(TREASURY, 1));

        BalanceDelta control = _swap(controlKey, 1 ether, true);
        uint256 grossIn = uint256(-int256(control.amount0()));

        BalanceDelta live = _swap(key, 1 ether, true);
        uint256 netIn = uint256(-int256(live.amount0()));

        uint256 expectedCut = (grossIn * FEE_PIPS) / 1_000_000;
        assertEq(hook.pendingBeneficiary(poolId, currency0), expectedCut, "cut accrues in the INPUT currency");
        assertEq(netIn - grossIn, expectedCut, "trader pays exactly the cut extra");
        assertEq(uint256(int256(live.amount1())), uint256(int256(control.amount1())), "output side untouched");
        _assertSolvent();
    }

    function test_oneForZero_accruesInCurrency0() public {
        hook.setBeneficiaries(key, _roster(TREASURY, 1));
        _swap(key, SWAP_AMOUNT, false);

        assertGt(hook.pendingBeneficiary(poolId, currency0), 0);
        assertEq(hook.pendingBeneficiary(poolId, currency1), 0);
        _assertSolvent();
    }

    function test_zeroFee_takesNothing() public {
        hook.reduceFee(key, 0);
        hook.setBeneficiaries(key, _roster(TREASURY, 1));

        BalanceDelta control = _swap(controlKey, SWAP_AMOUNT, true);
        BalanceDelta live = _swap(key, SWAP_AMOUNT, true);

        assertEq(live.amount1(), control.amount1(), "a zero fee must be indistinguishable from no hook");
        assertEq(hook.totalOwed(currency1), 0);
        _assertSolvent();
    }

    function test_dustSwap_roundsToZeroAndTakesNothing() public {
        hook.setBeneficiaries(key, _roster(TREASURY, 1));
        // 1% of an output of a few wei floors to zero. It must not revert, and must not take 1 wei
        // it has not earned.
        _swap(key, -50, true);
        assertEq(hook.totalOwed(currency1), 0);
        _assertSolvent();
    }

    /*//////////////////////////////////////////////////////////////
                         ROUTE 1 - DONATE TO LPs
    //////////////////////////////////////////////////////////////*/

    function test_route1_donationReachesLiquidityProviders() public {
        hook.proposeConfig(key, _params(FEE_PIPS, 10_000, 0, 0, address(0)));
        vm.warp(block.timestamp + hook.CONFIG_DELAY_SECONDS());
        hook.applyPendingConfig(key);

        BalanceDelta control = _swap(controlKey, SWAP_AMOUNT, true);
        uint256 grossOut = uint256(int256(control.amount1()));
        uint256 expectedDonation = (grossOut * FEE_PIPS) / 1_000_000;

        _swap(key, SWAP_AMOUNT, true);

        // Nothing is retained: the whole cut went straight to in-range liquidity.
        assertEq(hook.totalOwed(currency1), 0, "route 1 must retain nothing");
        assertEq(vault.balanceOf(address(hook), currency1), 0, "route 1 must mint no claims");

        // Withdrawing the position now returns the donated fees on top of the swap fees. Compare
        // against the control pool's position, which earned swap fees only.
        (BalanceDelta live,) = router.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: -100_000 ether,
                salt: 0
            }),
            ZERO_BYTES
        );
        (BalanceDelta ctrl,) = router.modifyPosition(
            controlKey,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: -600,
                tickUpper: 600,
                liquidityDelta: -100_000 ether,
                salt: 0
            }),
            ZERO_BYTES
        );

        uint256 liveOut1 = uint256(int256(live.amount1()));
        uint256 ctrlOut1 = uint256(int256(ctrl.amount1()));
        assertGt(liveOut1, ctrlOut1, "LPs must be better off by the donation");
        // Allow one wei of rounding through `feeGrowthGlobal`'s Q128 fixed point.
        assertApproxEqAbs(liveOut1 - ctrlOut1, expectedDonation, 1, "donation must be the configured share");
        _assertSolvent();
    }

    /*//////////////////////////////////////////////////////////////
                    ROUTE 2 - WEIGHTED BENEFICIARIES
    //////////////////////////////////////////////////////////////*/

    function test_route2_accrueSettleClaim() public {
        hook.setBeneficiaries(key, _roster(TREASURY, 3, CHARITY, 1));
        _swap(key, SWAP_AMOUNT, true);

        uint256 pot = hook.pendingBeneficiary(poolId, currency1);
        assertGt(pot, 0);
        // Nothing is claimable until somebody settles: the swap path writes one integer, no more.
        assertEq(hook.claimable(TREASURY, currency1), 0);

        // Permissionless.
        vm.prank(ALICE);
        hook.settleBeneficiaries(key, currency1);

        assertEq(hook.claimable(TREASURY, currency1), (pot * 3) / 4);
        assertEq(hook.claimable(CHARITY, currency1), pot / 4);
        assertEq(
            hook.claimable(TREASURY, currency1) + hook.claimable(CHARITY, currency1)
                + hook.pendingBeneficiary(poolId, currency1),
            pot,
            "settlement must conserve value"
        );

        uint256 owed = hook.claimable(TREASURY, currency1);
        vm.prank(TREASURY);
        hook.claim(currency1, TREASURY);

        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(TREASURY), owed);
        assertEq(hook.claimable(TREASURY, currency1), 0);
        _assertSolvent();
    }

    function test_route2_claimRedeemsVaultClaimsOnDemand() public {
        hook.setBeneficiaries(key, _roster(TREASURY, 1));
        _swap(key, SWAP_AMOUNT, true);
        hook.settleBeneficiaries(key, currency1);

        // The hook holds ERC-6909 claims, not tokens, until somebody needs real tokens.
        assertGt(vault.balanceOf(address(hook), currency1), 0);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(hook)), 0);

        vm.prank(TREASURY);
        hook.claim(currency1, TREASURY);

        assertEq(vault.balanceOf(address(hook), currency1), 0, "claims must be redeemed, not stranded");
        _assertSolvent();
    }

    function test_route2_claimToADifferentAddress() public {
        hook.setBeneficiaries(key, _roster(TREASURY, 1));
        _swap(key, SWAP_AMOUNT, true);
        hook.settleBeneficiaries(key, currency1);

        uint256 owed = hook.claimable(TREASURY, currency1);
        vm.prank(TREASURY);
        hook.claim(currency1, ALICE);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(ALICE), owed);

        vm.prank(TREASURY);
        vm.expectRevert(RevShareHook.NothingToClaim.selector);
        hook.claim(currency1, ALICE);

        vm.prank(TREASURY);
        vm.expectRevert(RevShareHook.InvalidRecipient.selector);
        hook.claim(currency0, address(0));
    }

    /// Audit B: `to == address(hook)` would forfeit the caller's balance to `skim`.
    function test_FIX_claimToTheHookItselfIsRefused() public {
        hook.setBeneficiaries(key, _roster(TREASURY, 1));
        _swap(key, SWAP_AMOUNT, true);
        hook.settleBeneficiaries(key, currency1);
        uint256 owed = hook.claimable(TREASURY, currency1);
        assertGt(owed, 0);
        vm.prank(TREASURY);
        vm.expectRevert(RevShareHook.InvalidRecipient.selector);
        hook.claim(currency1, address(hook));
        assertEq(hook.claimable(TREASURY, currency1), owed, "nothing was forfeited");
    }

    function test_route2_nonBeneficiaryCannotClaim() public {
        hook.setBeneficiaries(key, _roster(TREASURY, 1));
        _swap(key, SWAP_AMOUNT, true);
        hook.settleBeneficiaries(key, currency1);

        vm.prank(ALICE);
        vm.expectRevert(RevShareHook.NothingToClaim.selector);
        hook.claim(currency1, ALICE);
    }

    function test_route2_rosterChangeSettlesTheOldRosterFirst() public {
        hook.setBeneficiaries(key, _roster(TREASURY, 1));
        _swap(key, SWAP_AMOUNT, true);
        uint256 pot = hook.pendingBeneficiary(poolId, currency1);
        assertGt(pot, 0);

        // Swapping the roster must not hand the old roster's earnings to the new one.
        hook.setBeneficiaries(key, _roster(CHARITY, 1));
        assertEq(hook.claimable(TREASURY, currency1), pot, "old roster keeps what it earned");
        assertEq(hook.claimable(CHARITY, currency1), 0, "new roster starts empty");
        _assertSolvent();
    }

    /*//////////////////////////////////////////////////////////////
       THE BENEFICIARY INVARIANT: A SHARE ALWAYS HAS SOMEBODY TO PAY

       The deployed hook accepted `beneficiaryBps = 10_000` with an empty roster,
       accrued into `pendingBeneficiary` forever, returned QUIETLY from
       `settleBeneficiaries` rather than reverting, and let `freezeConfig` remove
       the only repair. Three guards now make that state unreachable; each test
       below fails against the deployed code.
    //////////////////////////////////////////////////////////////*/

    /// @dev Guard 1 of 3, in `_validateParams`. The twin of `DistributorRequired`, whose absence
    /// was the whole bug: route 3 fails loudly with no distributor, route 2 used to accrue into a
    /// pot with nobody on the other end.
    function test_FIX_configureRejectsABeneficiaryShareWithNoRoster() public {
        PoolKey memory fresh = _key(hook);
        fresh.fee = 500;
        fresh.parameters =
            CLPoolParametersHelper.setTickSpacing(bytes32(uint256(hook.getHooksRegistrationBitmap())), int24(10));
        PoolId freshId = fresh.toId();

        vm.expectRevert(abi.encodeWithSelector(RevShareHook.BeneficiariesRequired.selector, freshId));
        hook.configure(fresh, _params(FEE_PIPS, 0, 10_000, 0, address(0)));

        // And the documented three-step flow is the way through it.
        hook.configure(fresh, _params(FEE_PIPS, 10_000, 0, 0, address(0)));
        hook.setBeneficiaries(fresh, _roster(TREASURY, 1));
        hook.configure(fresh, _params(FEE_PIPS, 0, 10_000, 0, address(0)));
        assertEq(hook.getConfig(freshId).beneficiaryBps, 10_000);
    }

    /// @dev Guard 2 of 3, in `setBeneficiaries`. `InvalidBeneficiaries` always documented itself
    /// as "Roster is empty, too long, or contains an invalid entry"; the "empty" half was never
    /// implemented. Emptying a roster is still allowed once the share is zero.
    function test_FIX_setBeneficiariesRejectsAnEmptyRosterWhileTheShareIsLive() public {
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.BeneficiariesRequired.selector, poolId));
        hook.setBeneficiaries(key, new RevShareHook.Beneficiary[](0));

        // Take the share to zero first and the roster may go.
        hook.proposeConfig(key, _params(FEE_PIPS, 10_000, 0, 0, address(0)));
        vm.warp(block.timestamp + hook.CONFIG_DELAY_SECONDS());
        hook.applyPendingConfig(key);
        hook.setBeneficiaries(key, new RevShareHook.Beneficiary[](0));
        assertEq(hook.totalWeight(poolId), 0);
    }

    /// @dev Guard 3 of 3, on the one irreversible call a pool owner has, and it is DELIBERATELY
    /// unreachable: guards 1 and 2 already make "live share, empty roster" impossible to write, so
    /// no sequence of public calls can arrive at `freezeConfig` in that state. This test walks the
    /// three doors and shows each one shut, which is the property worth pinning - the guard itself
    /// is a backstop against a future edit reopening one of the other two.
    function test_FIX_noSequenceReachesAFrozenPoolWithAnUnpayableShare() public {
        PoolKey memory fresh = _key(hook);
        fresh.fee = 500;
        fresh.parameters =
            CLPoolParametersHelper.setTickSpacing(bytes32(uint256(hook.getHooksRegistrationBitmap())), int24(10));
        PoolId freshId = fresh.toId();

        // Door 1: claim the pool straight into a beneficiary share. Refused.
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.BeneficiariesRequired.selector, freshId));
        hook.configure(fresh, _params(FEE_PIPS, 0, 10_000, 0, address(0)));

        hook.configure(fresh, _params(FEE_PIPS, 10_000, 0, 0, address(0)));
        hook.setBeneficiaries(fresh, _roster(TREASURY, 1));
        hook.configure(fresh, _params(FEE_PIPS, 0, 10_000, 0, address(0)));

        // Door 2: empty the roster out from under a live share. Refused.
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.BeneficiariesRequired.selector, freshId));
        hook.setBeneficiaries(fresh, new RevShareHook.Beneficiary[](0));

        // Door 3: with the share zeroed the roster may go - and then the share cannot come back.
        hook.configure(fresh, _params(FEE_PIPS, 10_000, 0, 0, address(0)));
        hook.setBeneficiaries(fresh, new RevShareHook.Beneficiary[](0));
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.BeneficiariesRequired.selector, freshId));
        hook.configure(fresh, _params(FEE_PIPS, 0, 10_000, 0, address(0)));

        // So whatever is frozen is payable by construction.
        hook.freezeConfig(fresh);
        assertEq(hook.getConfig(freshId).beneficiaryBps, 0);
        assertTrue(hook.getConfig(freshId).frozen);
    }

    /// @dev A pool that DOES have a roster freezes exactly as before. The guard must not have
    /// turned `freezeConfig` into something a well-configured pool cannot use.
    function test_FIX_freezeConfigStillWorksWithARoster() public {
        assertGt(hook.totalWeight(poolId), 0);
        hook.freezeConfig(key);
        assertTrue(hook.getConfig(poolId).frozen);
    }

    /// @dev What the old `test_route2_emptyRosterHoldsThePotRatherThanLosingIt` asserted, now
    /// inverted by the fix and worth pinning in its new form. `setBeneficiaries` settles the
    /// OUTGOING roster before writing the new one, so the pot cannot be left waiting on nobody -
    /// it is paid to the roster that earned it, and only rounding dust survives the change. The
    /// early return in `settleBeneficiaries` therefore guards dust, not a fortune.
    function test_route2_emptyingARosterPaysTheOutgoingOneFirst() public {
        _swap(key, SWAP_AMOUNT, true);
        uint256 pot = hook.pendingBeneficiary(poolId, currency1);
        assertGt(pot, 0);
        assertEq(hook.claimable(TREASURY, currency1), 0, "nothing settled yet");

        // Zero the share so the roster is allowed to go, then empty it.
        hook.proposeConfig(key, _params(FEE_PIPS, 10_000, 0, 0, address(0)));
        vm.warp(block.timestamp + hook.CONFIG_DELAY_SECONDS());
        hook.applyPendingConfig(key);
        hook.setBeneficiaries(key, new RevShareHook.Beneficiary[](0));

        assertEq(hook.claimable(TREASURY, currency1), pot, "the outgoing roster was paid on the way out");
        assertEq(hook.pendingBeneficiary(poolId, currency1), 0, "nothing left stranded behind it");
        assertEq(hook.totalWeight(poolId), 0);

        vm.prank(TREASURY);
        assertEq(hook.claim(currency1, TREASURY), pot);
        _assertSolvent();
    }

    function test_route2_rosterValidation() public {
        vm.expectRevert(RevShareHook.InvalidBeneficiaries.selector);
        hook.setBeneficiaries(key, _roster(address(0), 1));

        vm.expectRevert(RevShareHook.InvalidBeneficiaries.selector);
        hook.setBeneficiaries(key, _roster(TREASURY, 0));

        RevShareHook.Beneficiary[] memory tooMany = new RevShareHook.Beneficiary[](9);
        for (uint256 i = 0; i < 9; ++i) {
            tooMany[i] = RevShareHook.Beneficiary({recipient: address(uint160(i + 1)), weight: 1});
        }
        vm.expectRevert(RevShareHook.InvalidBeneficiaries.selector);
        hook.setBeneficiaries(key, tooMany);

        vm.expectRevert(RevShareHook.InvalidBeneficiaries.selector);
        hook.setBeneficiaries(key, _roster(TREASURY, uint96(1e18), CHARITY, 1));
    }

    function test_route2_settlementRoundingLosesNothing() public {
        // Three co-prime weights guarantee a non-zero floor remainder.
        RevShareHook.Beneficiary[] memory roster = new RevShareHook.Beneficiary[](3);
        roster[0] = RevShareHook.Beneficiary({recipient: TREASURY, weight: 1});
        roster[1] = RevShareHook.Beneficiary({recipient: CHARITY, weight: 1});
        roster[2] = RevShareHook.Beneficiary({recipient: ALICE, weight: 1});
        hook.setBeneficiaries(key, roster);

        _swap(key, SWAP_AMOUNT, true);
        uint256 pot = hook.pendingBeneficiary(poolId, currency1);
        hook.settleBeneficiaries(key, currency1);

        uint256 total = hook.claimable(TREASURY, currency1) + hook.claimable(CHARITY, currency1)
            + hook.claimable(ALICE, currency1) + hook.pendingBeneficiary(poolId, currency1);
        assertEq(total, pot, "the remainder must stay in the pot, not evaporate");
        assertLt(hook.pendingBeneficiary(poolId, currency1), 3, "the remainder is at most one wei per beneficiary");
        _assertSolvent();
    }

    /*//////////////////////////////////////////////////////////////
                       ROUTE 3 - EPOCH DISTRIBUTOR
    //////////////////////////////////////////////////////////////*/

    function test_route3_onlyTheDistributorCanPull() public {
        hook.proposeConfig(key, _params(FEE_PIPS, 0, 0, 10_000, DISTRIBUTOR));
        vm.warp(block.timestamp + hook.CONFIG_DELAY_SECONDS());
        hook.applyPendingConfig(key);

        _swap(key, SWAP_AMOUNT, true);
        uint256 pot = hook.pendingDistributorShare(poolId, currency1);
        assertGt(pot, 0);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.NotDistributor.selector, poolId, ALICE));
        hook.pullDistributorShare(key, currency1);

        vm.prank(DISTRIBUTOR);
        uint256 pulled = hook.pullDistributorShare(key, currency1);
        assertEq(pulled, pot);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(DISTRIBUTOR), pot);
        assertEq(hook.pendingDistributorShare(poolId, currency1), 0);

        // A second pull is a no-op, not a revert: an epoch closer should not have to pre-check.
        vm.prank(DISTRIBUTOR);
        assertEq(hook.pullDistributorShare(key, currency1), 0);
        _assertSolvent();
    }

    /*//////////////////////////////////////////////////////////////
       LOW, fixed: A DISTRIBUTOR REPOINT NO LONGER HANDS OVER THE OLD POT
    //////////////////////////////////////////////////////////////*/

    /// @dev Route 3 to `DISTRIBUTOR`, swap so a pot accrues, then repoint to `ALICE` through the
    /// ordinary propose -> wait -> apply path. Returns the pot that accrued under `DISTRIBUTOR`.
    function _accrueThenRepointTo(address next) internal returns (uint256 pot) {
        hook.proposeConfig(key, _params(FEE_PIPS, 0, 0, 10_000, DISTRIBUTOR));
        vm.warp(block.timestamp + hook.CONFIG_DELAY_SECONDS());
        hook.applyPendingConfig(key);
        _swap(key, SWAP_AMOUNT, true);
        pot = hook.pendingDistributorShare(poolId, currency1);
        assertGt(pot, 0);

        hook.proposeConfig(key, _params(FEE_PIPS, 0, 0, 10_000, next));
        vm.warp(block.timestamp + hook.CONFIG_DELAY_SECONDS());
        hook.applyPendingConfig(key);
    }

    /// @dev FAILS AGAINST THE PRE-FIX HOOK: there, `ALICE` pulled `pot` - value that accrued for
    /// the old distributor's holders - because `pullDistributorShare` paid whoever was current.
    function test_FIX_repointDoesNotHandTheOldPotToTheNewDistributor() public {
        uint256 pot = _accrueThenRepointTo(ALICE);

        assertEq(hook.pendingDistributorShare(poolId, currency1), 0, "the live pot starts empty for the new distributor");
        assertEq(hook.retiredDistributorPot(poolId, DISTRIBUTOR, currency1), pot, "escrowed for the old one");

        vm.prank(ALICE);
        assertEq(hook.pullDistributorShare(key, currency1), 0, "the new distributor gets none of it");

        vm.prank(DISTRIBUTOR);
        assertEq(hook.pullDistributorShare(key, currency1), pot, "the old distributor still collects its own");
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(DISTRIBUTOR), pot);
        assertEq(hook.retiredDistributorPot(poolId, DISTRIBUTOR, currency1), 0);
        _assertSolvent();
    }

    /// @dev A two-currency `closeEpoch` pulls both currencies; the retired distributor must get 0,
    /// not a revert, for a currency with no escrow. A stranger still reverts.
    function test_FIX_retiredDistributorPullsZeroNotRevert_strangerStillReverts() public {
        _accrueThenRepointTo(ALICE);
        vm.prank(DISTRIBUTOR);
        assertEq(hook.pullDistributorShare(key, currency0), 0);

        vm.prank(address(0xBAD));
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.NotDistributor.selector, poolId, address(0xBAD)));
        hook.pullDistributorShare(key, currency1);
    }

    /// @dev Fees after the repoint belong to the new distributor, and a later swap cannot grief the
    /// repoint (the escrow design is why a swap between close and apply blocks nothing).
    function test_FIX_postRepointFeesGoToTheNewDistributor() public {
        uint256 oldPot = _accrueThenRepointTo(ALICE);
        _swap(key, SWAP_AMOUNT, true);
        uint256 newPot = hook.pendingDistributorShare(poolId, currency1);
        assertGt(newPot, 0);

        vm.prank(ALICE);
        assertEq(hook.pullDistributorShare(key, currency1), newPot);
        vm.prank(DISTRIBUTOR);
        assertEq(hook.pullDistributorShare(key, currency1), oldPot);
        _assertSolvent();
    }

    /// @dev A -> B -> A: the returning distributor collects its escrow and the live pot together.
    function test_FIX_repointBackCollectsEscrowAndLivePot() public {
        uint256 first = _accrueThenRepointTo(ALICE);
        hook.proposeConfig(key, _params(FEE_PIPS, 0, 0, 10_000, DISTRIBUTOR));
        vm.warp(block.timestamp + hook.CONFIG_DELAY_SECONDS());
        hook.applyPendingConfig(key);
        _swap(key, SWAP_AMOUNT, true);
        uint256 live = hook.pendingDistributorShare(poolId, currency1);

        vm.prank(DISTRIBUTOR);
        assertEq(hook.pullDistributorShare(key, currency1), first + live);
        _assertSolvent();
    }

    /*//////////////////////////////////////////////////////////////
                            THREE-WAY SPLIT
    //////////////////////////////////////////////////////////////*/

    function test_threeWaySplit_conservesTheCut() public {
        hook.proposeConfig(key, _params(FEE_PIPS, 5_000, 3_000, 2_000, DISTRIBUTOR));
        vm.warp(block.timestamp + hook.CONFIG_DELAY_SECONDS());
        hook.applyPendingConfig(key);
        hook.setBeneficiaries(key, _roster(TREASURY, 1));

        BalanceDelta control = _swap(controlKey, SWAP_AMOUNT, true);
        uint256 grossOut = uint256(int256(control.amount1()));

        BalanceDelta live = _swap(key, SWAP_AMOUNT, true);
        uint256 netOut = uint256(int256(live.amount1()));

        uint256 taken = grossOut - netOut;
        uint256 ben = hook.pendingBeneficiary(poolId, currency1);
        uint256 dist = hook.pendingDistributorShare(poolId, currency1);

        assertEq(ben, (grossOut * FEE_PIPS * 3_000) / (1_000_000 * 10_000));
        assertEq(dist, (grossOut * FEE_PIPS * 2_000) / (1_000_000 * 10_000));
        uint256 lp = (grossOut * FEE_PIPS * 5_000) / (1_000_000 * 10_000);
        assertEq(taken, lp + ben + dist, "the trader loses exactly what the three sinks receive");
        assertEq(hook.totalOwed(currency1), ben + dist, "only the retained portion is owed");
        _assertSolvent();
    }

    /*//////////////////////////////////////////////////////////////
                   HOSTILE RECIPIENTS CANNOT TOUCH SWAPS
    //////////////////////////////////////////////////////////////*/

    /// @dev The reason every route is pull-based. A beneficiary that cannot be paid strands its
    /// own balance and nothing else: swaps keep working and other beneficiaries keep claiming.
    function test_hostileBeneficiary_cannotBlockSwapsOrOtherClaims() public {
        // Build a pool whose currency1 refuses transfers to CHARITY.
        BlacklistERC20 hostile = new BlacklistERC20();
        hostile.mint(address(this), 1_000_000 ether);
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        other.mint(address(this), 1_000_000 ether);

        (Currency c0, Currency c1) = address(hostile) < address(other)
            ? (Currency.wrap(address(hostile)), Currency.wrap(address(other)))
            : (Currency.wrap(address(other)), Currency.wrap(address(hostile)));

        PoolKey memory k = PoolKey({
            currency0: c0,
            currency1: c1,
            hooks: hook,
            poolManager: poolManager,
            fee: LP_FEE,
            parameters: CLPoolParametersHelper.setTickSpacing(
                bytes32(uint256(hook.getHooksRegistrationBitmap())), TICK_SPACING
            )
        });

        hook.configure(k, _params(FEE_PIPS, 10_000, 0, 0, address(0)));
        hook.setBeneficiaries(k, _roster(CHARITY, 1, TREASURY, 1));
        hook.configure(k, _params(FEE_PIPS, 0, 10_000, 0, address(0)));
        poolManager.initialize(k, SQRT_RATIO_1_1);

        IERC20(address(hostile)).approve(address(router), type(uint256).max);
        IERC20(address(other)).approve(address(router), type(uint256).max);
        _addLiquidity(k);

        hostile.setBlocked(CHARITY);

        // Swaps in both directions still work with a beneficiary that cannot be paid.
        _swap(k, SWAP_AMOUNT, true);
        _swap(k, SWAP_AMOUNT, false);

        hook.settleBeneficiaries(k, c0);
        hook.settleBeneficiaries(k, c1);

        Currency hostileCurrency = Currency.wrap(address(hostile));
        assertGt(hook.claimable(CHARITY, hostileCurrency), 0);

        // Only the blacklisted recipient is affected.
        vm.prank(CHARITY);
        vm.expectRevert();
        hook.claim(hostileCurrency, CHARITY);

        vm.prank(TREASURY);
        hook.claim(hostileCurrency, TREASURY);
        assertGt(hostile.balanceOf(TREASURY), 0);

        // And the blacklisted recipient can still route around it.
        vm.prank(CHARITY);
        hook.claim(hostileCurrency, ALICE);
        assertGt(hostile.balanceOf(ALICE), 0);
    }

    /*//////////////////////////////////////////////////////////////
                        THE DRAIN TEST, EXPLICITLY

        `Vault._settle` computes `paid = balanceOfSelf() - reservesBefore`, so anything that lets
        a party settle without paying drains the difference. These check the two ways this hook
        could have created one: an unbacked credit, and a vault balance that stops matching the
        claims on it.
    //////////////////////////////////////////////////////////////*/

    function test_drain_hookNeverCreditsMoreThanItTook() public {
        hook.proposeConfig(key, _params(hook.MAX_FEE_PIPS(), 3_400, 3_300, 3_300, DISTRIBUTOR));
        vm.warp(block.timestamp + hook.CONFIG_DELAY_SECONDS());
        hook.applyPendingConfig(key);
        hook.setBeneficiaries(key, _roster(TREASURY, 2, CHARITY, 1));

        for (uint256 i = 0; i < 10; ++i) {
            _swap(key, SWAP_AMOUNT, i % 2 == 0);
            _assertSolvent();
        }

        hook.settleBeneficiaries(key, currency0);
        hook.settleBeneficiaries(key, currency1);
        _assertSolvent();

        vm.prank(TREASURY);
        hook.claim(currency0, TREASURY);
        vm.prank(TREASURY);
        hook.claim(currency1, TREASURY);
        vm.prank(CHARITY);
        hook.claim(currency0, CHARITY);
        vm.prank(CHARITY);
        hook.claim(currency1, CHARITY);
        vm.prank(DISTRIBUTOR);
        hook.pullDistributorShare(key, currency0);
        vm.prank(DISTRIBUTOR);
        hook.pullDistributorShare(key, currency1);

        _assertSolvent();

        // Everything that was taken has now left, except the roster's flooring remainder. A
        // weighted split of a pot that is not a multiple of `totalWeight` leaves under one wei per
        // unit of weight behind, which `settleBeneficiaries` deliberately parks in
        // `pendingBeneficiary` for the next settlement rather than crediting to anyone.
        //
        // That remainder is the strict form of the property this test is named for: the hook holds
        // EXACTLY what it still owes and not a wei more, so nothing was ever credited that the hook
        // had not first taken as a hook delta. `assertEq(backing, owed)` is the two-sided version -
        // `_assertSolvent` only checks `backing >= owed`.
        for (uint256 i = 0; i < 2; ++i) {
            Currency c = i == 0 ? currency0 : currency1;
            uint256 remainder = hook.pendingBeneficiary(poolId, c);
            assertLt(remainder, hook.totalWeight(poolId), "split remainder must be bounded by the roster weight");
            assertEq(hook.totalOwed(c), remainder, "nothing is owed beyond the un-splittable remainder");
            assertEq(hook.backing(c), remainder, "and the hook holds exactly that, no more and no less");
            assertEq(vault.balanceOf(address(hook), c), 0, "the claims were all redeemed on the way out");
        }

        // Nor is the remainder stranded: it joins the next pot instead of accumulating.
        _swap(key, SWAP_AMOUNT, true);
        hook.settleBeneficiaries(key, currency1);
        assertLt(
            hook.pendingBeneficiary(poolId, currency1),
            hook.totalWeight(poolId),
            "the remainder is carried into the next settlement, never accumulated"
        );
        _assertSolvent();
    }

    function test_drain_redeemIsIdempotentAndCannotOverDraw() public {
        hook.setBeneficiaries(key, _roster(TREASURY, 1));
        _swap(key, SWAP_AMOUNT, true);

        uint256 claims = vault.balanceOf(address(hook), currency1);
        assertGt(claims, 0);

        hook.redeem(currency1);
        assertEq(vault.balanceOf(address(hook), currency1), 0);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(hook)), claims);

        // A second redeem finds nothing and must not manufacture a delta.
        assertEq(hook.redeem(currency1), 0);
        _assertSolvent();
    }

    /// @dev Fuzzes swap size and direction over a long run, asserting the two solvency statements
    /// after every step. This is the property that a settlement bug would break.
    function testFuzz_drain_solventUnderArbitrarySwapSequences(uint96[8] calldata amounts, uint8 directions) public {
        hook.proposeConfig(key, _params(hook.MAX_FEE_PIPS(), 3_400, 3_300, 3_300, DISTRIBUTOR));
        vm.warp(block.timestamp + hook.CONFIG_DELAY_SECONDS());
        hook.applyPendingConfig(key);
        hook.setBeneficiaries(key, _roster(TREASURY, 7, CHARITY, 3));

        for (uint256 i = 0; i < 8; ++i) {
            uint256 amount = uint256(amounts[i]) % 5 ether;
            if (amount < 1000) continue; // below this the pool itself rejects the swap as dust
            _swap(key, -int256(amount), (directions >> i) & 1 == 1);
            _assertSolvent();
        }

        hook.settleBeneficiaries(key, currency0);
        hook.settleBeneficiaries(key, currency1);
        _assertSolvent();

        if (hook.claimable(TREASURY, currency0) > 0) {
            vm.prank(TREASURY);
            hook.claim(currency0, TREASURY);
        }
        if (hook.claimable(CHARITY, currency1) > 0) {
            vm.prank(CHARITY);
            hook.claim(currency1, CHARITY);
        }
        _assertSolvent();
    }

    /*//////////////////////////////////////////////////////////////
      keyOf — a PoolId is a hash, so the key has to be stored.
    //////////////////////////////////////////////////////////////*/

    /// The stored key must be the REAL key, provable by re-deriving the id from it.
    function test_keyOf_roundTripsToTheSamePoolId() public view {
        PoolKey memory stored = hook.keyOf(poolId);
        assertEq(PoolId.unwrap(stored.toId()), PoolId.unwrap(poolId), "keyOf must rebuild the id");
        assertEq(address(stored.hooks), address(hook));
        assertEq(Currency.unwrap(stored.currency0), Currency.unwrap(currency0));
        assertEq(Currency.unwrap(stored.currency1), Currency.unwrap(currency1));
        assertEq(stored.fee, key.fee);
        assertEq(stored.parameters, key.parameters);
    }

    /// A pool this hook has never governed returns the zero key, and `hasKey` says so.
    /// Callers must be able to tell "no record" from "a record full of zeros".
    function test_keyOf_unknownPoolReadsAsZeroAndHasKeyIsFalse() public view {
        PoolId unknown = PoolId.wrap(bytes32(uint256(0xDEAD)));
        assertFalse(hook.hasKey(unknown));
        PoolKey memory empty = hook.keyOf(unknown);
        assertEq(address(empty.hooks), address(0));
    }

    function test_hasKey_trueForAConfiguredPool() public view {
        assertTrue(hook.hasKey(poolId));
    }

    /// The point of the whole thing: a caller holding ONLY an id can now build the
    /// calldata for a write. Previously this was impossible without an external source.
    function test_keyOf_isEnoughToDriveAWrite() public {
        _swap(key, SWAP_AMOUNT, true);

        PoolKey memory rebuilt = hook.keyOf(poolId);
        // settleBeneficiaries takes a PoolKey and nothing else the caller must know.
        hook.settleBeneficiaries(rebuilt, currency1);
    }

    /*//////////////////////////////////////////////////////////////
      totalTaken — pending balances fall to zero; a lifetime total must not.
    //////////////////////////////////////////////////////////////*/

    function test_totalTaken_startsAtZero() public view {
        assertEq(hook.totalTaken(poolId, currency0), 0);
        assertEq(hook.totalTaken(poolId, currency1), 0);
    }

    /// The number that could previously only be had by summing logs.
    function test_totalTaken_accumulatesAcrossSwaps() public {
        _swap(key, SWAP_AMOUNT, true);
        uint256 afterOne = hook.totalTaken(poolId, currency1);
        assertGt(afterOne, 0, "a fee-taking swap must register");

        _swap(key, SWAP_AMOUNT, true);
        assertGt(hook.totalTaken(poolId, currency1), afterOne, "it must accumulate, not overwrite");
    }

    /// The distinction that justifies the extra SSTORE: settling ZEROES the pending
    /// balance, and the lifetime total must survive that untouched.
    function test_totalTaken_survivesSettlement() public {
        // A roster is required for settlement to do anything at all: with no
        // beneficiaries `settleBeneficiaries` returns early and the pot waits,
        // rather than being distributed to nobody and lost.
        hook.setBeneficiaries(key, _roster(TREASURY, 1));

        _swap(key, SWAP_AMOUNT, true);
        uint256 lifetime = hook.totalTaken(poolId, currency1);
        assertGt(lifetime, 0);

        hook.settleBeneficiaries(key, currency1);

        assertEq(hook.pendingBeneficiary(poolId, currency1), 0, "settling clears the balance");
        assertEq(hook.totalTaken(poolId, currency1), lifetime, "but not the lifetime total");
    }

    /// It counts what the POOL took, which includes what went straight back to LPs.
    /// A total that omitted the LP donation would understate the pool's revenue.
    function test_totalTaken_countsAllThreeRoutes() public {
        _swap(key, SWAP_AMOUNT, true);
        uint256 total = hook.totalTaken(poolId, currency1);
        uint256 pendingB = hook.pendingBeneficiary(poolId, currency1);
        uint256 pendingD = hook.pendingDistributorShare(poolId, currency1);
        assertGe(total, pendingB + pendingD, "total must be at least the retained parts");
    }


    /*//////////////////////////////////////////////////////////////
       CONSTRUCTOR BOUNDS - the three arguments that used to be constants

       Each of these was a `constant` whose value was correct for a 12s chain and
       wrong for the chain the hook shipped on. The tests below are about the
       BOUNDS, not the values: a deployment picks the value, the contract refuses
       to let the pick be meaningless.
    //////////////////////////////////////////////////////////////*/

    /// @dev The retired hooks took a block count (and, on `0xfC00`, a block time). This one takes
    /// seconds and has no block-time argument to reject, so the bound is the whole test.
    function test_ctor_delayIsSecondsInsideTheBounds() public {
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.ConfigDelayTooShort.selector, 0, 12 hours));
        new RevShareHook(poolManager, GOVERNANCE, GUARDIAN, 0, 8);

        RevShareHook atFloor = new RevShareHook(poolManager, GOVERNANCE, GUARDIAN, uint40(12 hours), 8);
        assertEq(uint256(atFloor.CONFIG_DELAY_SECONDS()), 12 hours);
    }

    /// @dev A delay so long that the pool owner can never answer market conditions is its own
    /// failure, and there is no admin anywhere that can shorten it after the fact.
    function test_ctor_rejectsADelayBeyondTheCeiling() public {
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.ConfigDelayTooLong.selector, 14 days + 1, 14 days));
        new RevShareHook(poolManager, GOVERNANCE, GUARDIAN, uint40(14 days + 1), 8);
    }

    function test_ctor_boundsMaxBeneficiaries() public {
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.InvalidMaxBeneficiaries.selector, 0, 32));
        new RevShareHook(poolManager, GOVERNANCE, GUARDIAN, CONFIG_DELAY, 0);

        vm.expectRevert(abi.encodeWithSelector(RevShareHook.InvalidMaxBeneficiaries.selector, 33, 32));
        new RevShareHook(poolManager, GOVERNANCE, GUARDIAN, CONFIG_DELAY, 33);

        RevShareHook wide = new RevShareHook(poolManager, GOVERNANCE, GUARDIAN, CONFIG_DELAY, 32);
        assertEq(wide.MAX_BENEFICIARIES(), 32);
        assertEq(wide.MAX_BENEFICIARIES_CEILING(), 32);
    }

    /// @dev The roster cap is enforced at the deployment's own value, not at the old literal 8.
    /// `settleBeneficiaries` is permissionless and off the swap path, so this bounds gas, never a
    /// trade - which is exactly why it is safe to make it a knob at all.
    function test_ctor_theRosterCapIsTheDeployedValue() public {
        assertEq(hook.MAX_BENEFICIARIES(), 8);

        RevShareHook.Beneficiary[] memory nine = new RevShareHook.Beneficiary[](9);
        for (uint256 i = 0; i < 9; ++i) {
            nine[i] = RevShareHook.Beneficiary({recipient: address(uint160(0x1000 + i)), weight: 1});
        }
        vm.expectRevert(RevShareHook.InvalidBeneficiaries.selector);
        hook.setBeneficiaries(key, nine);

        RevShareHook.Beneficiary[] memory eight = new RevShareHook.Beneficiary[](8);
        for (uint256 i = 0; i < 8; ++i) {
            eight[i] = RevShareHook.Beneficiary({recipient: address(uint160(0x1000 + i)), weight: 1});
        }
        hook.setBeneficiaries(key, eight);
        assertEq(hook.getBeneficiaries(poolId).length, 8);

        // And settlement over the full roster still runs, which is the only thing the cap protects.
        _swap(key, SWAP_AMOUNT, true);
        hook.settleBeneficiaries(key, currency1);
        assertGt(hook.claimable(address(uint160(0x1007)), currency1), 0);
    }

    /// @dev `proposeConfig` twice must leave ONE proposal, with a fresh window. A second proposal
    /// silently stacking behind the first would be the expiry defeated.
    function test_proposeConfig_replacesRatherThanStacks() public {
        hook.proposeConfig(key, _params(50_000, 0, 10_000, 0, address(0)));
        RevShareHook.PendingConfig memory first = hook.getPendingConfig(poolId);

        vm.warp(block.timestamp + 10);
        hook.proposeConfig(key, _params(60_000, 0, 10_000, 0, address(0)));
        RevShareHook.PendingConfig memory second = hook.getPendingConfig(poolId);

        assertEq(second.effectiveAt, first.effectiveAt + 10, "the clock restarted");
        assertEq(second.params.feePips, 60_000, "and only the newer one survives");

        vm.warp(second.effectiveAt);
        hook.applyPendingConfig(key);
        assertEq(hook.getConfig(poolId).feePips, 60_000);
        assertEq(hook.getPendingConfig(poolId).effectiveAt, 0, "consumed");
    }

    /*//////////////////////////////////////////////////////////////
              L-1 (2026-09-18): SURPLUS HAS A PATH OUT, OWED VALUE NEVER
    //////////////////////////////////////////////////////////////*/

    /// A stray ERC-20 sent straight to the hook is the only thing `skim` can move: it leaves exactly
    /// that, `totalOwed` is untouched and the beneficiary's claim still pays in full afterwards.
    function test_FIX_skim_movesOnlyTheSurplus_ownerOnly() public {
        _swap(key, SWAP_AMOUNT, true);
        uint256 owed = hook.totalOwed(currency1);
        assertGt(owed, 0);
        assertEq(hook.backing(currency1), owed, "no surplus after an honest swap");

        // Nothing above the obligations: refused, whatever the caller.
        vm.prank(GOVERNANCE);
        vm.expectRevert(abi.encodeWithSelector(RevShareHook.NothingToSkim.selector, currency1));
        hook.skim(currency1, ALICE);

        uint256 stray = 3 ether;
        MockERC20(Currency.unwrap(currency1)).transfer(address(hook), stray);
        assertEq(hook.backing(currency1) - hook.totalOwed(currency1), stray);

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, ALICE));
        hook.skim(currency1, ALICE);
        vm.prank(GOVERNANCE);
        vm.expectRevert(RevShareHook.InvalidRecipient.selector);
        hook.skim(currency1, address(0));

        vm.prank(GOVERNANCE);
        vm.expectEmit(true, true, false, true, address(hook));
        emit RevShareHook.Skimmed(currency1, ALICE, stray);
        assertEq(hook.skim(currency1, ALICE), stray);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(ALICE), stray);
        assertEq(hook.totalOwed(currency1), owed, "obligations untouched");
        assertEq(hook.backing(currency1), owed, "surplus gone, owed value still backed");
        _assertSolvent();

        // The beneficiary is paid in full from what remains.
        hook.settleBeneficiaries(key, currency1);
        uint256 before = IERC20(Currency.unwrap(currency1)).balanceOf(TREASURY);
        vm.prank(TREASURY);
        hook.claim(currency1, TREASURY);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(TREASURY) - before, owed);
        assertEq(hook.totalOwed(currency1), 0);
    }

    /// @dev Lock callback for the claims test below: pays `amount` of `currency` into the vault
    /// and mints the test contract the matching ERC-6909 claim.
    function lockAcquired(bytes calldata data) external returns (bytes memory) {
        (Currency c, uint256 amount) = abi.decode(data, (Currency, uint256));
        vault.sync(c);
        MockERC20(Currency.unwrap(c)).transfer(address(vault), amount);
        vault.settle();
        vault.mint(address(this), c, amount);
        return "";
    }

    /// Surplus held as vault claims (an ERC-6909 transfer to the hook) is redeemed and paid too.
    function test_FIX_skim_redeemsSurplusHeldAsVaultClaims() public {
        _swap(key, SWAP_AMOUNT, true);
        uint256 owed = hook.totalOwed(currency1);
        // Mint the test contract vault claims, then hand them to the hook the way a stranger could.
        uint256 stray = 1 ether;
        vault.lock(abi.encode(currency1, stray));
        vault.transfer(address(hook), currency1, stray);
        assertEq(hook.backing(currency1) - hook.totalOwed(currency1), stray);

        vm.prank(GOVERNANCE);
        assertEq(hook.skim(currency1, ALICE), stray);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(ALICE), stray, "paid as real tokens");
        assertEq(hook.totalOwed(currency1), owed);
        assertGe(hook.backing(currency1), owed);
        _assertSolvent();
    }
}
