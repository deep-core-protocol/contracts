// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

import {DeepCoreDynamicFeeHook} from "../../src/dex/DeepCoreDynamicFeeHook.sol";

/// @dev Two swaps inside ONE external call, so transient storage spans both (forge clears it
/// between a test's separate top-level calls, which is why a plain test cannot see a stale cut).
contract TwoSwaps {
    CLPoolManagerRouter internal immutable router;

    constructor(CLPoolManagerRouter router_, Currency c0, Currency c1) {
        router = router_;
        IERC20(Currency.unwrap(c0)).approve(address(router_), type(uint256).max);
        IERC20(Currency.unwrap(c1)).approve(address(router_), type(uint256).max);
    }

    function run(PoolKey calldata a, PoolKey calldata b) external {
        _swap(a);
        _swap(b);
    }

    function _swap(PoolKey calldata k) private {
        router.swap(
            k,
            ICLPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1}),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
    }
}

contract DeepCoreDynamicFeeHookTest is Test, Deployers {
    using CurrencyLibrary for Currency;

    address internal constant SAFE = address(0x5AFE);
    address internal constant RECIPIENT = address(0xFEE5);
    address internal constant CREATOR = address(0xC0FFEE);
    address internal constant TUNER = address(0x7E7E);
    address internal constant STRANGER = address(0xBAD);

    uint24 internal constant FEE_CAP = 50_000; // 5%
    uint16 internal constant SHARE = 1_500; // 15% of each swap's fee
    uint16 internal constant MAX_SHARE = 3_000;
    uint32 internal constant NOTICE = 7 days;
    uint24 internal constant MAX_MOVE = 500;
    uint256 internal constant T0 = 1_800_000_000;

    Vault internal vault;
    CLPoolManager internal manager;
    CLPoolManagerRouter internal router;
    DeepCoreDynamicFeeHook internal hook;
    Currency internal c0;
    Currency internal c1;
    PoolKey internal key;
    PoolId internal id;

    function setUp() public {
        vm.warp(T0);
        (vault, manager) = createFreshManager();
        hook = new DeepCoreDynamicFeeHook(manager, IVault(address(vault)), SAFE, RECIPIENT, FEE_CAP, SHARE, MAX_SHARE, NOTICE, NOTICE, MAX_MOVE);
        router = new CLPoolManagerRouter(vault, manager);
        (c0, c1) = deployCurrencies(2 ** 250);
        IERC20(Currency.unwrap(c0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(c1)).approve(address(router), type(uint256).max);
        (key, id) = _open(_cfg(), 60);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _cfg() internal pure returns (DeepCoreDynamicFeeHook.FeeConfig memory c) {
        c.baseFee = 3_000;
        c.volSlope = 10;
        c.sameSecondSlope = 50;
        c.minBaseFee = 500;
        c.maxBaseFee = 10_000;
        c.maxVolSlope = 40;
        c.maxSameSecondSlope = 100;
        c.maxFee = 30_000;
        c.volCap = 2_000;
        c.decaySeconds = 1_800;
        c.deadband = 5;
        c.maxBaseFeeStep = 500;
        c.maxSlopeStep = 5;
        c.minTuneInterval = 3_600;
        c.tuner = address(0);
    }

    function _key(int24 spacing) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: c0,
            currency1: c1,
            hooks: IHooks(address(hook)),
            poolManager: manager,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: CLPoolParametersHelper.setTickSpacing(bytes32(uint256(hook.getHooksRegistrationBitmap())), spacing)
        });
    }

    function _open(DeepCoreDynamicFeeHook.FeeConfig memory c, int24 spacing) internal returns (PoolKey memory k, PoolId pid) {
        k = _key(spacing);
        pid = k.toId();
        vm.prank(CREATOR);
        hook.configure(k, c, MAX_SHARE);
        manager.initialize(k, SQRT_RATIO_1_1);
        router.modifyPosition(
            k,
            ICLPoolManager.ModifyLiquidityParams({tickLower: -6_000, tickUpper: 6_000, liquidityDelta: 1_000_000 ether, salt: 0}),
            ZERO_BYTES
        );
    }

    function _swap(PoolKey memory k, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return router.swap(
            k,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ZERO_BYTES
        );
    }

    /// @dev The `fee` field of core's Swap event for the last swap.
    function _swapFee(Vm.Log[] memory logs) internal pure returns (uint24 fee) {
        bytes32 sig = keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24,uint16)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == sig) (,,,,, fee,) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24, uint16));
        }
    }

    function _tick() internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(id);
    }

    function _cutSlot() internal pure returns (bytes32) {
        return bytes32(uint256(keccak256("deepcore.dynamicfee.pendingCut")) - 1);
    }

    /*//////////////////////////////////////////////////////////////
                               DEPLOYMENT
    //////////////////////////////////////////////////////////////*/

    function test_bitmap_is_0x08C3() public view {
        assertEq(hook.getHooksRegistrationBitmap(), 0x08C3);
    }

    function test_deploy_refusesAVaultThatIsNotTheManagers() public {
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDynamicFeeHook.InvalidDeployment.selector, 1));
        new DeepCoreDynamicFeeHook(manager, IVault(address(0x1234)), SAFE, RECIPIENT, FEE_CAP, SHARE, MAX_SHARE, NOTICE, NOTICE, MAX_MOVE);
    }

    function test_deploy_refusesBadImmutables() public {
        IVault v = IVault(address(vault));
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDynamicFeeHook.InvalidDeployment.selector, 2));
        new DeepCoreDynamicFeeHook(manager, v, SAFE, RECIPIENT, 100_001, SHARE, MAX_SHARE, NOTICE, NOTICE, MAX_MOVE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDynamicFeeHook.InvalidDeployment.selector, 3));
        new DeepCoreDynamicFeeHook(manager, v, SAFE, RECIPIENT, FEE_CAP, SHARE, 5_001, NOTICE, NOTICE, MAX_MOVE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDynamicFeeHook.InvalidDeployment.selector, 3));
        new DeepCoreDynamicFeeHook(manager, v, SAFE, RECIPIENT, FEE_CAP, MAX_SHARE + 1, MAX_SHARE, NOTICE, NOTICE, MAX_MOVE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDynamicFeeHook.InvalidDeployment.selector, 4));
        new DeepCoreDynamicFeeHook(manager, v, SAFE, RECIPIENT, FEE_CAP, SHARE, MAX_SHARE, 1 hours, NOTICE, MAX_MOVE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDynamicFeeHook.InvalidDeployment.selector, 5));
        new DeepCoreDynamicFeeHook(manager, v, SAFE, RECIPIENT, FEE_CAP, SHARE, MAX_SHARE, NOTICE, NOTICE, 2_001);
        vm.expectRevert(DeepCoreDynamicFeeHook.ZeroAddress.selector);
        new DeepCoreDynamicFeeHook(manager, v, SAFE, address(0), FEE_CAP, SHARE, MAX_SHARE, NOTICE, NOTICE, MAX_MOVE);
    }

    /*//////////////////////////////////////////////////////////////
                             CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function test_configure_recordsOwnerShareAndConfig() public view {
        DeepCoreDynamicFeeHook.PoolAdmin memory a = hook.getAdmin(id);
        assertEq(a.owner, CREATOR);
        assertEq(a.protocolShareBps, SHARE);
        assertTrue(a.configured);
        assertEq(hook.getConfig(id).baseFee, 3_000);
        (,,, uint24 lpFee) = manager.getSlot0(id);
        assertEq(lpFee, 3_000, "the stored fee is the base fee, never zero");
    }

    function test_configure_refusesAStaticFeeKey() public {
        PoolKey memory k = _key(10);
        k.fee = 3_000;
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDynamicFeeHook.PoolMustUseDynamicFee.selector, uint24(3_000)));
        hook.configure(k, _cfg(), MAX_SHARE);
    }

    function test_configure_refusesAnotherHookOrManager() public {
        PoolKey memory k = _key(10);
        k.hooks = IHooks(address(0x1));
        vm.expectRevert(DeepCoreDynamicFeeHook.HookMismatch.selector);
        hook.configure(k, _cfg(), MAX_SHARE);
        k = _key(10);
        k.poolManager = ICLPoolManager(address(0x2));
        vm.expectRevert(DeepCoreDynamicFeeHook.PoolManagerMismatch.selector);
        hook.configure(k, _cfg(), MAX_SHARE);
    }

    function test_configure_refusesAConfiguredOrInitializedPool() public {
        vm.expectRevert(DeepCoreDynamicFeeHook.PoolAlreadyInitialized.selector);
        hook.configure(key, _cfg(), MAX_SHARE);
        PoolKey memory k = _key(10);
        hook.configure(k, _cfg(), MAX_SHARE);
        vm.expectRevert(DeepCoreDynamicFeeHook.PoolAlreadyConfigured.selector);
        vm.prank(STRANGER);
        hook.configure(k, _cfg(), MAX_SHARE);
    }

    function test_configure_refusesEachInvalidField() public {
        PoolKey memory k = _key(10);
        DeepCoreDynamicFeeHook.FeeConfig memory c;
        uint8[8] memory reasons = [uint8(7), 1, 2, 2, 3, 3, 4, 5];
        for (uint256 i; i < 8; ++i) {
            c = _cfg();
            if (i == 0) c.minBaseFee = c.maxBaseFee + 1;
            if (i == 1) c.baseFee = c.maxBaseFee + 1;
            if (i == 2) c.volSlope = c.maxVolSlope + 1;
            if (i == 3) c.sameSecondSlope = c.maxSameSecondSlope + 1;
            if (i == 4) c.maxFee = FEE_CAP + 1;
            if (i == 5) c.maxBaseFee = c.maxFee + 1;
            if (i == 6) c.decaySeconds = 599;
            if (i == 7) c.minTuneInterval = 3_599;
            vm.expectRevert(abi.encodeWithSelector(DeepCoreDynamicFeeHook.InvalidConfig.selector, reasons[i]));
            hook.configure(k, c, MAX_SHARE);
        }
        c = _cfg();
        c.tuner = address(hook);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDynamicFeeHook.InvalidConfig.selector, 6));
        hook.configure(k, c, MAX_SHARE);
    }

    function test_configure_refusesAShareAboveWhatTheCreatorAccepts() public {
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDynamicFeeHook.ProtocolShareAboveAccepted.selector, SHARE, uint16(1_000)));
        hook.configure(_key(10), _cfg(), 1_000);
    }

    function test_initialize_refusesAnUnconfiguredPool() public {
        vm.expectRevert(); // core wraps the hook's PoolNotConfigured
        manager.initialize(_key(10), SQRT_RATIO_1_1);
    }

    /*//////////////////////////////////////////////////////////////
                           SWAP AND PROTOCOL CUT
    //////////////////////////////////////////////////////////////*/

    function test_swap_exactIn_lpGetsTheirPart_protocolGetsItsPartOfTheOutput() public {
        vm.warp(T0 + 10);
        (uint24 total, uint24 lpPips, uint24 protocolPips) = _expectedParts(true);
        assertEq(total, 3_000, "quiet pool: the base fee");
        assertEq(protocolPips, 450); // 15% of 3,000
        assertEq(lpPips, 2_550);

        uint256 before1 = c1.balanceOf(address(this));
        vm.recordLogs();
        BalanceDelta d = _swap(key, true, -1 ether);
        assertEq(_swapFee(vm.getRecordedLogs()), lpPips, "core charged the LP part as the pool's fee");

        uint256 received = c1.balanceOf(address(this)) - before1;
        assertEq(uint256(int256(d.amount1())), received);
        // The pool's output before the cut is received + cut, and cut = floor(poolOut * pips / 1e6).
        uint256 cut = hook.protocolTaken(c1);
        assertGt(cut, 0);
        assertEq(cut, ((received + cut) * protocolPips) / 1e6, "cut = protocol pips of the unspecified amount");
        assertEq(vault.balanceOf(address(hook), c1), cut, "held as vault claims");
        assertEq(uint256(vm.load(address(hook), _cutSlot())), 0, "the pending cut is always cleared");
    }

    function test_swap_exactOut_theCutIsOnTheInput() public {
        vm.warp(T0 + 10);
        uint256 before0 = c0.balanceOf(address(this));
        BalanceDelta d = _swap(key, true, 1 ether); // exact output of currency1
        uint256 paid = before0 - c0.balanceOf(address(this));
        assertEq(uint256(-int256(d.amount0())), paid);
        uint256 cut = hook.protocolTaken(c0);
        assertGt(cut, 0);
        assertEq(hook.protocolTaken(c1), 0);
        assertEq(cut, ((paid - cut) * 450) / 1e6, "cut on the input the pool asked for");
    }

    function test_swap_withAZeroShare_takesNothing() public {
        vm.prank(SAFE);
        hook.setProtocolShare(0);
        (PoolKey memory k,) = _open(_cfg(), 10);
        vm.warp(T0 + 10);
        vm.recordLogs();
        _swap(k, true, -1 ether);
        assertEq(_swapFee(vm.getRecordedLogs()), 3_000, "the whole fee is the LPs'");
        assertEq(hook.protocolTaken(c1), 0);
    }

    /*//////////////////////////////////////////////////////////////
                                THE FEE
    //////////////////////////////////////////////////////////////*/

    function _expectedParts(bool zeroForOne) internal view returns (uint24 total, uint24 lpPips, uint24 protocolPips) {
        (,,, total, lpPips, protocolPips) = hook.feeParts(id, zeroForOne);
    }

    function test_fee_volatilityRaisesItAndDecaysByTheClockAlone() public {
        vm.warp(T0 + 10);
        _swap(key, true, -200_000 ether); // a big move in second 10
        int24 moved = _tick();
        assertLt(moved, -5);
        vm.warp(T0 + 11); // the next second counts the move
        (uint24 total,,) = _expectedParts(true);
        uint256 move = uint256(int256(-moved));
        if (move > MAX_MOVE) move = MAX_MOVE;
        assertEq(total, 3_000 + 10 * move, "base + volSlope * counted move");

        _swap(key, false, -1 ether); // the first swap of second 11 records it
        (uint32 vol,) = hook.volatility(id);
        assertEq(vol, move);
        vm.warp(T0 + 11 + 900); // half the decay period
        (vol,) = hook.volatility(id);
        assertEq(vol, move / 2);
        vm.warp(T0 + 11 + 1_800);
        (total,,) = _expectedParts(true);
        assertEq(total, 3_000, "back to the base fee after decaySeconds");
    }

    function test_fee_dustSwapsEverySecondDoNotSlowTheDecay() public {
        vm.warp(T0 + 10);
        _swap(key, true, -200_000 ether);
        vm.warp(T0 + 11);
        _swap(key, false, -1 wei); // records the move
        (uint32 v0, uint40 t0) = hook.volatility(id);
        for (uint256 i = 1; i <= 50; ++i) {
            vm.warp(T0 + 11 + i * 10);
            _swap(key, i % 2 == 0, -1 wei);
        }
        (uint32 v1, uint40 t1) = hook.volatility(id);
        assertEq(t1, t0, "dust never re-counts or resets the timer");
        assertEq(v1, uint32((uint256(v0) * (1_800 - 500)) / 1_800), "decayed exactly by the clock");
    }

    function test_fee_theReversingLegPaysTheSurcharge_theMoverDoesNot() public {
        vm.warp(T0 + 10);
        _swap(key, false, -1 wei); // anchors second 10
        (uint24 moverFee,,) = _expectedParts(false);
        assertEq(moverFee, 3_000, "the first mover pays no surcharge");
        _swap(key, false, -2_000 ether); // front-run: price up, small enough to stay under the clamp
        int24 d = _tick();
        assertGt(d, 0);
        (uint24 sameDir,,) = _expectedParts(false);
        assertEq(sameDir, 3_000, "a trade in the same direction pays none");
        (uint24 reversing,,) = _expectedParts(true);
        assertLt(3_000 + 50 * uint256(int256(d)), 30_000, "the move is small enough to test the formula, not the clamp");
        assertEq(reversing, 3_000 + 50 * uint24(uint256(int256(d))), "the back leg pays sameSecondSlope x reversed ticks");
        vm.recordLogs();
        _swap(key, true, -2_000 ether);
        (,, uint24 protocolPips) = (uint24(0), uint24(0), uint24((uint256(reversing) * SHARE) / 10_000));
        assertEq(_swapFee(vm.getRecordedLogs()), reversing - protocolPips);
    }

    /// @dev A drift inside the dead band adds no volatility; drift that later passes it is counted
    /// WHOLE, from the reference, not just the last step (slow drift is not lost).
    function test_fee_deadBand_smallDriftIgnored_thenCountedWhole() public {
        bool sawInside;
        bool sawCounted;
        for (uint256 i = 1; i <= 12 && !sawCounted; ++i) {
            vm.warp(T0 + i);
            int24 pre = _tick(); // what this second's first swap measures from the reference (birth tick 0)
            _swap(key, true, -100 ether); // about 2 ticks down each second
            (uint32 vol,) = hook.volatility(id);
            uint256 move = uint256(int256(pre < 0 ? -pre : pre));
            if (move <= 5) {
                assertEq(vol, 0, "a net move inside the dead band is not volatility");
                sawInside = move > 0 || sawInside;
            } else {
                assertEq(vol, move, "the whole accumulated drift is counted once it passes the band");
                assertEq(hook.getState(id).volRefTick, pre, "and the reference moves only now");
                sawCounted = true;
            }
        }
        assertTrue(sawInside && sawCounted, "the drift crossed the band inside the loop");
    }

    /// @dev Default profile: transient storage lasts the whole transaction, and a test function is
    /// one transaction. If a cut were left behind, the next pool's swap in the same transaction would
    /// read another pool's tag and revert. Catches a cut that is never cleared on BOTH backends.
    function test_pendingCut_isClearedWithinOneTransaction() public {
        vm.warp(T0 + 10);
        _swap(key, true, -1 ether); // takes a cut on pool A
        vm.prank(SAFE);
        hook.setProtocolShare(0);
        (PoolKey memory kB, PoolId idB) = _open(_cfg(), 10); // a zero-share pool
        assertEq(hook.getAdmin(idB).protocolShareBps, 0);
        _swap(kB, true, -1 ether); // same transaction: must not see pool A's cut
        _swap(key, false, -1 ether); // and pool A again
        assertEq(uint256(vm.load(address(hook), _cutSlot())), 0);
    }

    /// @dev The same property with both swaps in ONE external call: on the Cancun backend the cut is
    /// transient and outlives the call only if it is never cleared, which this makes visible.
    function test_pendingCut_isClearedBetweenSwapsOfOneCall() public {
        vm.prank(SAFE);
        hook.setProtocolShare(0);
        (PoolKey memory kB, PoolId idB) = _open(_cfg(), 10); // zero-share pool
        assertEq(hook.getAdmin(idB).protocolShareBps, 0);
        TwoSwaps two = new TwoSwaps(router, c0, c1);
        MockERC20(Currency.unwrap(c0)).transfer(address(two), 10 ether);
        vm.warp(T0 + 10);
        two.run(key, kB); // pool A (15% share) then pool B (none), one transaction, one call
        assertGt(hook.protocolTaken(c1), 0);
    }

    /// @dev The share a pool was configured with is the one its swaps pay, whatever the Safe sets later.
    function test_share_aConfiguredPoolKeepsPayingItsFrozenShare() public {
        vm.prank(SAFE);
        hook.setProtocolShare(0); // at once, for new pools
        vm.warp(T0 + 10);
        (,, uint24 protocolPips) = _expectedParts(true);
        assertEq(protocolPips, 450, "still 15% of 3,000 on the existing pool");
        uint256 before1 = c1.balanceOf(address(this));
        _swap(key, true, -1 ether);
        uint256 received = c1.balanceOf(address(this)) - before1;
        uint256 cut = hook.protocolTaken(c1);
        assertGt(cut, 0);
        assertEq(cut, ((received + cut) * 450) / 1e6);
    }

    function test_fee_isClampedToMaxFee() public {
        DeepCoreDynamicFeeHook.FeeConfig memory c = _cfg();
        c.maxFee = 4_000;
        c.maxBaseFee = 4_000;
        (PoolKey memory k, PoolId pid) = _open(c, 10);
        vm.warp(T0 + 10);
        _swap(k, true, -300_000 ether);
        vm.warp(T0 + 11);
        (,,, uint24 total,,) = hook.feeParts(pid, true);
        assertEq(total, 4_000);
    }

    function testFuzz_feeNeverAboveMaxFee_swapsNeverRevert(uint256 seed) public {
        for (uint256 i; i < 12; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            vm.warp(block.timestamp + (seed % 7));
            bool zfo = seed & 1 == 0;
            int256 amt = -int256(1 ether + (seed >> 8) % 20_000 ether);
            // stay inside the liquidity: at the range edge core itself refuses the price limit
            int24 t = _tick();
            if (t < -4_000) zfo = false;
            if (t > 4_000) zfo = true;
            _swap(key, zfo, amt);
            (,,, uint24 total,,) = hook.feeParts(id, !zfo);
            assertLe(total, 30_000);
            (uint32 vol,) = hook.volatility(id);
            assertLe(vol, 2_000);
            assertEq(uint256(vm.load(address(hook), _cutSlot())), 0);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                THE TUNER
    //////////////////////////////////////////////////////////////*/

    function _withTuner() internal {
        vm.prank(CREATOR);
        hook.proposeTuner(id, TUNER);
        vm.warp(block.timestamp + NOTICE);
        vm.prank(TUNER);
        hook.acceptTuner(id);
    }

    function test_tuner_mustWaitTheNotice() public {
        vm.prank(CREATOR);
        hook.proposeTuner(id, TUNER);
        vm.prank(TUNER);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDynamicFeeHook.TunerNoticeNotElapsed.selector, uint40(block.timestamp + NOTICE)));
        hook.acceptTuner(id);
        vm.prank(STRANGER);
        vm.expectRevert(DeepCoreDynamicFeeHook.NotPoolOwner.selector);
        hook.proposeTuner(id, STRANGER);
    }

    function test_tune_insideBoundsStepAndInterval() public {
        _withTuner();
        vm.prank(STRANGER);
        vm.expectRevert(DeepCoreDynamicFeeHook.NotTuner.selector);
        hook.tune(key, 3_500, 10, 50);

        vm.startPrank(TUNER);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDynamicFeeHook.StepTooLarge.selector, uint8(1), uint24(3_000), uint24(3_501), uint24(500)));
        hook.tune(key, 3_501, 10, 50);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDynamicFeeHook.OutOfBounds.selector, uint8(2), uint24(41)));
        hook.tune(key, 3_000, 41, 50);
        hook.tune(key, 3_500, 15, 55);
        (,,, uint24 lpFee) = manager.getSlot0(id);
        assertEq(lpFee, 3_500, "tune writes the stored fee");
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDynamicFeeHook.TuneTooSoon.selector, uint40(block.timestamp + 3_600)));
        hook.tune(key, 3_600, 15, 55);
        vm.warp(block.timestamp + 3_600);
        hook.tune(key, 4_000, 20, 60);
        vm.stopPrank();
        assertEq(hook.getConfig(id).baseFee, 4_000);
    }

    function test_tuner_revokedAtOnceByOwnerOrItself_andFreezeEndsEverything() public {
        _withTuner();
        vm.prank(TUNER);
        hook.revokeTuner(id);
        assertEq(hook.getAdmin(id).tuner, address(0));
        _withTuner();
        vm.prank(CREATOR);
        hook.freeze(id);
        assertEq(hook.getAdmin(id).tuner, address(0), "freeze removes the tuner");
        vm.startPrank(CREATOR);
        vm.expectRevert(DeepCoreDynamicFeeHook.PoolFrozen.selector);
        hook.proposeTuner(id, TUNER);
        vm.expectRevert(DeepCoreDynamicFeeHook.PoolFrozen.selector);
        hook.transferPoolOwnership(id, STRANGER);
        vm.stopPrank();
        vm.prank(TUNER);
        vm.expectRevert(DeepCoreDynamicFeeHook.NotTuner.selector);
        hook.tune(key, 3_000, 10, 50);
    }

    function test_poolOwnership_isTwoStep() public {
        vm.prank(CREATOR);
        hook.transferPoolOwnership(id, STRANGER);
        assertEq(hook.getAdmin(id).owner, CREATOR);
        vm.prank(address(0xAAAA));
        vm.expectRevert(DeepCoreDynamicFeeHook.NotPendingPoolOwner.selector);
        hook.acceptPoolOwnership(id);
        vm.prank(STRANGER);
        hook.acceptPoolOwnership(id);
        assertEq(hook.getAdmin(id).owner, STRANGER);
    }

    /*//////////////////////////////////////////////////////////////
                         THE PROTOCOL SHARE (SAFE)
    //////////////////////////////////////////////////////////////*/

    function test_share_decreaseAtOnce_increaseAfterNotice_neverRetroactive() public {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, STRANGER));
        hook.setProtocolShare(0);

        vm.startPrank(SAFE);
        hook.setProtocolShare(1_000);
        assertEq(hook.protocolShareBps(), 1_000, "a decrease applies at once");
        hook.setProtocolShare(2_500);
        assertEq(hook.protocolShareBps(), 1_000, "an increase waits");
        (uint16 next, uint40 at) = hook.pendingProtocolShare();
        assertEq(next, 2_500);
        assertEq(at, uint40(block.timestamp + NOTICE));
        vm.expectRevert(abi.encodeWithSelector(DeepCoreDynamicFeeHook.ProtocolShareAboveCap.selector, uint16(3_001), MAX_SHARE));
        hook.setProtocolShare(3_001);
        vm.stopPrank();

        vm.warp(block.timestamp + NOTICE);
        assertEq(hook.protocolShareBps(), 2_500, "in force after the notice");
        assertEq(hook.getAdmin(id).protocolShareBps, SHARE, "a configured pool keeps its share for ever");

        vm.startPrank(SAFE);
        hook.setProtocolShare(2_900);
        hook.cancelPendingProtocolShare();
        assertEq(hook.protocolShareBps(), 2_500);
        vm.expectRevert(DeepCoreDynamicFeeHook.NoPendingProtocolShare.selector);
        hook.cancelPendingProtocolShare();
        vm.expectRevert(DeepCoreDynamicFeeHook.RenounceDisabled.selector);
        hook.renounceOwnership();
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                 FUNDS
    //////////////////////////////////////////////////////////////*/

    function test_flush_paysEverythingToTheRecipient_permissionless() public {
        vm.warp(T0 + 10);
        _swap(key, true, -10 ether);
        uint256 cut = hook.protocolTaken(c1);
        // plus a token sent by mistake
        MockERC20(Currency.unwrap(c1)).transfer(address(hook), 7);

        vm.prank(STRANGER);
        uint256 paid = hook.flushProtocolFees(c1);
        assertEq(paid, cut + 7);
        assertEq(c1.balanceOf(RECIPIENT), cut + 7);
        assertEq(vault.balanceOf(address(hook), c1), 0);
        assertEq(c1.balanceOf(address(hook)), 0);

        vm.expectRevert(abi.encodeWithSelector(DeepCoreDynamicFeeHook.NothingToFlush.selector, c1));
        hook.flushProtocolFees(c1);
    }

    function test_flush_nativeForcedInLeavesToo_andStraySendsAreRefused() public {
        vm.deal(STRANGER, 1 ether);
        vm.prank(STRANGER);
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok, "receive accepts only the vault");
        vm.deal(address(hook), 5); // forced in, as a selfdestruct would
        hook.flushProtocolFees(CurrencyLibrary.NATIVE);
        assertEq(RECIPIENT.balance, 5);
    }

    function test_lockAcquired_onlyThroughFlush() public {
        vm.expectRevert(DeepCoreDynamicFeeHook.UnexpectedLockCallback.selector);
        hook.lockAcquired(abi.encode(c1, uint256(1)));
        vm.prank(address(vault));
        vm.expectRevert(DeepCoreDynamicFeeHook.UnexpectedLockCallback.selector);
        hook.lockAcquired(abi.encode(c1, uint256(1)));
    }

    function test_callbacks_onlyThePoolManager() public {
        vm.expectRevert();
        hook.beforeSwap(address(this), key, ICLPoolManager.SwapParams(true, -1, 0), ZERO_BYTES);
    }
}
