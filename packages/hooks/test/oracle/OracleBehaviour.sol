// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

import {OracleModule} from "../../src/oracle/OracleModule.sol";
import {IDeepCoreOracle} from "../../src/oracle/IDeepCoreOracle.sol";

/// @dev Swap and read the oracle inside ONE call, as a consumer contract would.
contract SwapThenConsult {
    CLPoolManagerRouter internal immutable router;

    constructor(CLPoolManagerRouter router_, Currency c0, Currency c1) {
        router = router_;
        IERC20(Currency.unwrap(c0)).approve(address(router_), type(uint256).max);
        IERC20(Currency.unwrap(c1)).approve(address(router_), type(uint256).max);
    }

    function run(PoolKey calldata k, int24 target, uint32 window) external returns (int24 meanTick) {
        (, int24 c,,) = ICLPoolManager(address(k.poolManager)).getSlot0(k.toId());
        bool zf1 = target < c;
        router.swap(
            k,
            ICLPoolManager.SwapParams({zeroForOne: zf1, amountSpecified: -1e30, sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(target)}),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
        (meanTick,) = OracleModule(address(k.hooks)).consult(k.toId(), window);
    }
}

/// @notice The oracle's behaviour, written once and run against every hook that embeds
/// `OracleModule` (the standalone `DeepCoreOracleHook` and `DeepCoreDexHook`). A reference model in
/// the test recomputes every observation from the pool's own tick read before each swap, and every
/// `consult` is compared with it to the tick.
abstract contract OracleBehaviour is Test, Deployers {
    uint256 internal constant T0 = 1_800_000_000;
    uint24 internal constant D = 100;
    uint32 internal constant MIN_WINDOW = 600;
    uint16 internal constant INITIAL_CARD = 16;

    Vault internal vault;
    CLPoolManager internal manager;
    CLPoolManagerRouter internal router;
    Currency internal c0;
    Currency internal c1;
    PoolKey internal key;
    PoolId internal id;

    struct Rec {
        uint40 t;
        int56 cum;
        int24 tick;
    }

    Rec[] internal recs;

    /*//////////////////////////////////////////////////////////////
                         SUPPLIED BY EACH SUITE
    //////////////////////////////////////////////////////////////*/

    /// @dev Deploy the hook under test with the given oracle immutables.
    function _deployHook(uint24 maxDelta, uint32 minWindow, uint16 initialCard) internal virtual returns (address);
    /// @dev The key's LP fee field for this hook.
    function _keyFee() internal view virtual returns (uint24);
    /// @dev Anything the hook needs before `initialize` (the dex hook's configure).
    function _beforeInit(PoolKey memory k) internal virtual;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        vm.warp(T0);
        (vault, manager) = createFreshManager();
        router = new CLPoolManagerRouter(vault, manager);
        (c0, c1) = deployCurrencies(2 ** 250);
        IERC20(Currency.unwrap(c0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(c1)).approve(address(router), type(uint256).max);
        address h = _deployHook(D, MIN_WINDOW, INITIAL_CARD);
        (key, id) = _open(h, 0);
    }

    /// @dev Under via-IR the optimizer may reuse one TIMESTAMP read across `vm.warp` calls inside a
    /// test, so `vm.warp(block.timestamp + x)` can warp to the same second twice. Read the cheatcode.
    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _oracle() internal view returns (OracleModule) {
        return OracleModule(address(key.hooks));
    }

    function _open(address h, int24 startTick) internal returns (PoolKey memory k, PoolId pid) {
        k = PoolKey({
            currency0: c0,
            currency1: c1,
            hooks: IHooks(h),
            poolManager: manager,
            fee: _keyFee(),
            parameters: CLPoolParametersHelper.setTickSpacing(
                bytes32(uint256(IHooks(h).getHooksRegistrationBitmap())), 10
            )
        });
        pid = k.toId();
        _beforeInit(k);
        manager.initialize(k, TickMath.getSqrtRatioAtTick(startTick));
        router.modifyPosition(
            k,
            ICLPoolManager.ModifyLiquidityParams({tickLower: -200_000, tickUpper: 200_000, liquidityDelta: 1e24, salt: 0}),
            ZERO_BYTES
        );
        delete recs;
        (, int24 t0,,) = manager.getSlot0(pid);
        recs.push(Rec({t: uint40(_now()), cum: 0, tick: t0}));
    }

    /*//////////////////////////////////////////////////////////////
                            REFERENCE MODEL
    //////////////////////////////////////////////////////////////*/

    function _tick() internal view returns (int24 t) {
        (, t,,) = manager.getSlot0(id);
    }

    function _clamp(int24 x, int24 ref) internal pure returns (int24) {
        int256 lo = int256(ref) - int256(uint256(D));
        int256 hi = int256(ref) + int256(uint256(D));
        if (x < lo) return int24(lo);
        if (x > hi) return int24(hi);
        return x;
    }

    /// @dev Swap the pool to `target` (exact tick limit), recording what the oracle should record.
    function _moveTo(int24 target) internal {
        int24 c = _tick();
        Rec memory last = recs[recs.length - 1];
        uint40 t = uint40(_now());
        if (t > last.t) {
            int24 cl = _clamp(c, last.tick);
            recs.push(Rec({t: t, cum: last.cum + int56(cl) * int56(uint56(t - last.t)), tick: cl}));
        }
        if (target == c) target = c + 1; // always swap, so the write path runs
        router.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: target < c,
                amountSpecified: -1e30,
                sqrtPriceLimitX96: TickMath.getSqrtRatioAtTick(target)
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ZERO_BYTES
        );
    }

    function _refCum(uint40 target) internal view returns (int56) {
        Rec memory last = recs[recs.length - 1];
        if (target >= last.t) {
            return last.cum + int56(_clamp(_tick(), last.tick)) * int56(uint56(target - last.t));
        }
        for (uint256 i = recs.length - 1; i > 0; --i) {
            if (recs[i - 1].t <= target) {
                return recs[i - 1].cum + int56(recs[i].tick) * int56(uint56(target - recs[i - 1].t));
            }
        }
        revert("before history");
    }

    function _refConsult(uint32 window) internal view returns (int24) {
        uint40 t = uint40(_now());
        int56 delta = _refCum(t) - _refCum(t - window);
        int56 q = delta / int56(uint56(window));
        if (delta < 0 && delta % int56(uint56(window)) != 0) q--;
        return int24(q);
    }

    /*//////////////////////////////////////////////////////////////
                                 TESTS
    //////////////////////////////////////////////////////////////*/

    function test_oracle_kind() public view {
        assertEq(_oracle().kind(), keccak256("deepcore.oracle.truncated-twap.v1"));
    }

    function test_oracle_initialize_writesTheBirthObservationAndPrepaysTheRing() public view {
        (uint16 index, uint16 card, uint16 cardNext) = _oracle().stateOf(id);
        assertEq(index, 0);
        assertEq(card, 1);
        assertEq(cardNext, INITIAL_CARD);
        IDeepCoreOracle.Observation memory o = _oracle().lastObservation(id);
        assertEq(o.timestamp, T0);
        assertEq(o.tickCumulative, 0);
        assertEq(o.tick, 0);
        assertTrue(o.initialized);
        for (uint16 i = 1; i < INITIAL_CARD; ++i) {
            IDeepCoreOracle.Observation memory p = _oracle().observationAt(id, i);
            assertEq(p.timestamp, 1, "pre-paid");
            assertFalse(p.initialized, "pre-paid, not history");
        }
        assertEq(_oracle().observationAt(id, INITIAL_CARD).timestamp, 0, "nothing past the ring");
    }

    function test_oracle_oneObservationPerSecond_recordingThePreSwapTick() public {
        vm.warp(T0 + 10);
        _moveTo(50);
        _moveTo(80); // same second: no write
        (uint16 index, uint16 card,) = _oracle().stateOf(id);
        assertEq(index, 1);
        assertEq(card, INITIAL_CARD, "the ring grew at the first wrap point");
        IDeepCoreOracle.Observation memory o = _oracle().lastObservation(id);
        assertEq(o.timestamp, T0 + 10);
        assertEq(o.tick, 0, "the tick BEFORE the second's first swap");
        assertEq(o.tickCumulative, 0);

        vm.warp(T0 + 15);
        int24 pre = _tick();
        _moveTo(20);
        o = _oracle().lastObservation(id);
        assertEq(o.timestamp, T0 + 15);
        assertEq(o.tick, pre, "a move within D is recorded whole");
        assertEq(o.tickCumulative, int56(pre) * 5);
    }

    function test_oracle_clampsEachObservationToD_upAndDown() public {
        vm.warp(T0 + 1);
        _moveTo(5_000);
        vm.warp(T0 + 2);
        _moveTo(5_000);
        assertEq(_oracle().lastObservation(id).tick, int24(uint24(D)), "up by at most D");
        vm.warp(T0 + 3);
        _moveTo(-5_000);
        assertEq(_oracle().lastObservation(id).tick, 2 * int24(uint24(D)), "still walking up: the pool stood at 5,000");
        vm.warp(T0 + 4);
        _moveTo(-5_000);
        assertEq(_oracle().lastObservation(id).tick, int24(uint24(D)), "down by at most D");
    }

    function test_oracle_consult_matchesTheReference() public {
        int24[8] memory path = [int24(30), -40, 120, 90, -300, 10, 10, 250];
        for (uint256 i; i < path.length; ++i) {
            vm.warp(_now() + 37 + i * 11);
            _moveTo(path[i]);
        }
        vm.warp(_now() + 90);
        uint32[3] memory windows = [uint32(600), 650, 694];
        for (uint256 i; i < windows.length; ++i) {
            (int24 m, uint32 age) = _oracle().consult(id, windows[i]);
            assertEq(m, _refConsult(windows[i]), "consult == reference");
            assertEq(age, 90);
        }
    }

    function test_oracle_consult_refusesAShortWindowAShortHistoryAndAnUnobservedPool() public {
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreOracle.WindowTooShort.selector, MIN_WINDOW - 1, MIN_WINDOW));
        _oracle().consult(id, MIN_WINDOW - 1);
        vm.warp(T0 + 599);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreOracle.HistoryTooShort.selector, 599, 600));
        _oracle().consult(id, 600);
        vm.warp(T0 + 600);
        _oracle().consult(id, 600);
        PoolId none = PoolId.wrap(bytes32(uint256(1)));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreOracle.PoolNotObserved.selector, none));
        _oracle().consult(none, 600);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreOracle.PoolNotObserved.selector, none));
        _oracle().lastObservation(none);
    }

    function test_oracle_extrapolatesWithTheCurrentTick_clamped() public {
        vm.warp(T0 + 1_000);
        _moveTo(5_000); // records 0 at T0+1000, pool now at 5,000
        vm.warp(T0 + 1_600);
        (int24 m,) = _oracle().consult(id, 600);
        // the last 600 s are extrapolated at clamp(5000, 0) = D, never at 5,000
        assertEq(m, int24(uint24(D)));
        assertEq(m, _refConsult(600));
    }

    function test_oracle_aSwapInTheReadingTransactionCannotMoveTheAnswer() public {
        vm.warp(T0 + 1_200);
        (int24 before,) = _oracle().consult(id, 600);
        SwapThenConsult reader = new SwapThenConsult(router, c0, c1);
        IERC20(Currency.unwrap(c0)).transfer(address(reader), 1e40);
        IERC20(Currency.unwrap(c1)).transfer(address(reader), 1e40);
        int24 afterSwap = reader.run(key, 50_000, 600);
        assertEq(afterSwap, before, "the swap's own write holds the pre-swap tick");
        assertGt(_tick(), 40_000, "the pool did move");
    }

    /// @dev An attacker moves the pool 5,000 ticks and holds it for k seconds, forcing an
    /// observation every second (the worst case for a count-based defence). The clamp bounds the
    /// recorded walk to D per observation, so the mean moves at most D * k(k+1)/2 / window.
    function test_oracle_manipulation_heldMoveIsBoundedByTheClamp() public {
        _oracle().increaseCardinalityNext(id, 64);
        for (uint256 i; i < 35; ++i) {
            vm.warp(_now() + 60);
            _moveTo(i % 2 == 0 ? int24(5) : int24(-5));
        }
        vm.warp(_now() + 60);
        (int24 honest,) = _oracle().consult(id, 1_800);
        uint256 k = 10;
        for (uint256 i; i < k; ++i) {
            vm.warp(_now() + 1);
            _moveTo(5_000);
        }
        (int24 attacked,) = _oracle().consult(id, 1_800);
        int256 shift = int256(attacked) - int256(honest);
        int256 bound = int256(uint256(D) * k * (k + 1) / 2 / 1_800) + 2;
        assertLe(shift, bound, "bounded by the clamp");
        assertEq(attacked, _refConsult(1_800));
        // Unclamped, the same hold would have moved the mean by about 5,000 * k / window.
        assertLt(bound, int256(5_000 * k / 1_800), "the clamp is what bounds it");
    }

    function test_oracle_ringWrapsAndGrows() public {
        address h = _deployHook(D, MIN_WINDOW, 2);
        (key, id) = _open(h, 0);
        for (uint256 i; i < 5; ++i) {
            vm.warp(_now() + 100);
            _moveTo(int24(int256(i)) * 7);
        }
        (uint16 index, uint16 card, uint16 next) = _oracle().stateOf(id);
        assertEq(card, 2);
        assertEq(next, 2);
        assertEq(index, 1); // 0 (birth) -> 1 -> 0 -> 1 -> 0 -> 1
        assertEq(_oracle().oldestObservationAge(id), 100, "only two slots of history");

        vm.expectRevert(abi.encodeWithSelector(IDeepCoreOracle.CardinalityNotIncreased.selector, 2, 2));
        _oracle().increaseCardinalityNext(id, 2);
        vm.expectEmit(address(h));
        emit IDeepCoreOracle.CardinalityNextIncreased(id, 2, 6);
        _oracle().increaseCardinalityNext(id, 6);
        for (uint256 i; i < 8; ++i) {
            vm.warp(_now() + 150);
            _moveTo(int24(int256(i)) * -3);
        }
        (, card,) = _oracle().stateOf(id);
        assertEq(card, 6, "grew at the next wrap point");
        assertEq(_oracle().oldestObservationAge(id), 750, "six slots of history");
        vm.warp(_now() + 13);
        (int24 m,) = _oracle().consult(id, 600);
        assertEq(m, _refConsult(600));
    }

    function test_oracle_observe_matchesTheReference() public {
        for (uint256 i; i < 6; ++i) {
            vm.warp(_now() + 123);
            _moveTo(int24(int256(i * 31)) - 60);
        }
        vm.warp(_now() + 7);
        uint32[] memory ago = new uint32[](4);
        ago[0] = 0;
        ago[1] = 7;
        ago[2] = 200;
        ago[3] = 700;
        int56[] memory cums = _oracle().observe(id, ago);
        for (uint256 i; i < ago.length; ++i) {
            assertEq(cums[i], _refCum(uint40(_now() - ago[i])));
        }
        ago[3] = 10_000;
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreOracle.HistoryTooShort.selector, 745, 10_000));
        _oracle().observe(id, ago);
    }

    function test_oracle_increaseCardinalityNext_refusesAnUnobservedPool() public {
        PoolId none = PoolId.wrap(bytes32(uint256(7)));
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreOracle.PoolNotObserved.selector, none));
        _oracle().increaseCardinalityNext(none, 20);
    }

    /// @dev An EXTERNAL constructor call, so `vm.expectRevert` applies to this call. With
    /// `allow_internal_expect_revert`, an expected revert on a bare `new` inside the test makes the TEST
    /// itself revert-and-pass, and every line after the first refusal silently never runs (found by a
    /// surviving mutant, 2026-10-14).
    function deployHookExt(uint24 maxDelta, uint32 minWindow, uint16 initialCard) external returns (address) {
        return _deployHook(maxDelta, minWindow, initialCard);
    }

    function test_oracle_deploy_refusesParametersOutsideTheHardBounds() public {
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreOracle.InvalidOracleParameters.selector, 1));
        this.deployHookExt(0, MIN_WINDOW, 16);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreOracle.InvalidOracleParameters.selector, 1));
        this.deployHookExt(1_001, MIN_WINDOW, 16);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreOracle.InvalidOracleParameters.selector, 2));
        this.deployHookExt(D, 59, 16);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreOracle.InvalidOracleParameters.selector, 2));
        this.deployHookExt(D, 86_401, 16);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreOracle.InvalidOracleParameters.selector, 3));
        this.deployHookExt(D, MIN_WINDOW, 0);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreOracle.InvalidOracleParameters.selector, 3));
        this.deployHookExt(D, MIN_WINDOW, 1_025);
        assertTrue(this.deployHookExt(D, MIN_WINDOW, 1_024) != address(0), "the bounds themselves are accepted");
    }

    function test_oracle_sourceUsesNoTransientStorage() public view {
        string memory src = vm.readFile("src/oracle/OracleModule.sol");
        assertFalse(_contains(src, "hp-transient"), "no transient backend import");
        assertFalse(_contains(src, "tstore"), "no tstore");
        assertFalse(_contains(src, "TransientSlot"), "no transient slot");
    }

    function _contains(string memory hay, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(hay);
        bytes memory n = bytes(needle);
        if (n.length > h.length) return false;
        for (uint256 i; i + n.length <= h.length; ++i) {
            bool ok = true;
            for (uint256 j; j < n.length; ++j) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    /// @dev Random swaps and time steps: every consult equals the reference, lies between the
    /// lowest and highest recorded tick, the cardinality never exceeds its target, and swaps never
    /// revert because of the oracle.
    function testFuzz_oracle_consultEqualsReferenceAndStaysInsideTheRecordedRange(uint256 seed) public {
        for (uint256 i; i < 24; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            uint256 dt = seed % 140; // 0 = same second
            vm.warp(_now() + dt);
            int24 target = int24(int256((seed >> 16) % 4_000) - 2_000);
            _moveTo(target);
            (, uint16 card, uint16 next) = _oracle().stateOf(id);
            assertLe(card, next);
            // exactly one observation per second with a swap, holding the pre-swap tick
            IDeepCoreOracle.Observation memory o = _oracle().lastObservation(id);
            Rec memory r = recs[recs.length - 1];
            assertEq(o.timestamp, r.t);
            assertEq(o.tick, r.tick);
            assertEq(o.tickCumulative, r.cum);
        }
        vm.warp(_now() + 1 + (seed % 50));
        uint32 avail = _oracle().oldestObservationAge(id);
        if (avail < MIN_WINDOW) return;
        uint32 w = MIN_WINDOW + uint32(seed % (avail - MIN_WINDOW + 1));
        (int24 m,) = _oracle().consult(id, w);
        assertEq(m, _refConsult(w));
        int24 lo = type(int24).max;
        int24 hi = type(int24).min;
        for (uint256 i; i < recs.length; ++i) {
            if (recs[i].tick < lo) lo = recs[i].tick;
            if (recs[i].tick > hi) hi = recs[i].tick;
        }
        int24 ext = _clamp(_tick(), recs[recs.length - 1].tick);
        if (ext < lo) lo = ext;
        if (ext > hi) hi = ext;
        assertGe(m, lo);
        assertLe(m, hi);
    }
}
