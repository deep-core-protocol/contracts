// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Vault} from "../../src/Vault.sol";
import {IHooks} from "../../src/interfaces/IHooks.sol";
import {IPoolManager} from "../../src/interfaces/IPoolManager.sol";
import {Currency} from "../../src/types/Currency.sol";
import {PoolKey} from "../../src/types/PoolKey.sol";
import {CLPoolManager} from "../../src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "../../src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolParametersHelper} from "../../src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "../../src/pool-cl/libraries/TickMath.sol";
import {BinPoolManager} from "../../src/pool-bin/BinPoolManager.sol";
import {IBinPoolManager} from "../../src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinPoolParametersHelper} from "../../src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {LiquidityConfigurations} from "../../src/pool-bin/libraries/math/LiquidityConfigurations.sol";
import {PackedUint128Math} from "../../src/pool-bin/libraries/math/PackedUint128Math.sol";
import {Constants as BinConstants} from "../../src/pool-bin/libraries/Constants.sol";

import {CLPoolManagerRouter} from "../pool-cl/helpers/CLPoolManagerRouter.sol";
import {BinSwapHelper} from "../pool-bin/helpers/BinSwapHelper.sol";
import {BinLiquidityHelper} from "../pool-bin/helpers/BinLiquidityHelper.sol";
import {SortTokens} from "../helpers/SortTokens.sol";

/// @title SwapGasBenchmark — core-level swap gas, reproducible.
///
/// @notice Measures what a single-hop EXACT-IN swap costs on a hookless CL pool and a hookless Bin
/// pool through core's own test routers (`CLPoolManagerRouter`, `BinSwapHelper`). The same file
/// compiles unchanged against upstream `pancakeswap/infinity-core` at the fork base, which is how
/// the DeepCore-vs-Infinity delta is measured: copy this file to `<upstream>/test/gas/` and run the
/// same command there. Every import resolves to a path that exists in both trees.
///
/// Method (see docs/gas-benchmark-2026-09-18.md):
///  * Pool: fee 3000 (0.30 %), tick spacing 60, no hook, initialised at tick 3000 (compressed
///    tick 50, the middle of bitmap word 0) with liquidity 1e24 over [2400, 3600]. A 1e18
///    exact-in swap then moves the price a fraction of a tick, never crosses an initialised tick
///    and never steps across a bitmap word (a pool sitting at tick 0 does: the first swap below
///    tick 0 costs one extra loop iteration, ~5.5k gas, which is a fixture artefact, not a cost).
///  * Steady state: `setUp` already ran one swap in EACH direction, so every slot the measured
///    swap writes (slot0, feeGrowthGlobal0/1, the Vault's reserves, the trader's and the Vault's
///    ERC-20 balances) is non-zero → no 20k "zero to non-zero" SSTOREs are counted.
///  * Access-list state: forge starts EVERY top-level call from the test contract with a cold
///    access list (verified 2026-09-18 with a probe: a contract read costs 8,787 as a top-level
///    call and 1,549 when repeated inside the same frame; `--isolate` changes nothing). So each
///    `vm.snapshotGasLastCall` figure here is the COLD execution gas of the router frame — what
///    a real transaction pays inside `to`, minus the 21,000 intrinsic gas and the calldata cost.
///    The second, repeated call in each test is a consistency check, not a "warm" number.
///  * Settlement: real ERC-20 `transferFrom` in and `transfer` out (`settleUsingTransfer`,
///    `withdrawTokens`), not ERC-6909 claims. Approvals are set in `setUp` and never measured.
///  * `v4recipe_*` reproduces Uniswap v4-core's `swap against liquidity` snapshot (liquidity 1e18
///    at [-120, 120] around tick 0, 100 wei exact-in, second swap of the test) so the published v4
///    number has a like-for-like row on this code.
///
/// Run: `forge test --match-path test/gas/SwapGasBenchmark.t.sol -vv` (default profile = Cancun /
/// EIP-1153, what every certified chain runs). Gas is also written to `snapshots/SwapGasBenchmark.json`.
contract SwapGasBenchmark is Test {
    using CLPoolParametersHelper for bytes32;
    using BinPoolParametersHelper for bytes32;

    uint160 internal constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 2^96
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint16 internal constant BIN_STEP = 10;
    uint24 internal constant ACTIVE_ID = 2 ** 23; // 1:1 price

    uint256 internal constant SWAP_IN = 1e18;
    int128 internal constant LIQUIDITY = 1e24;
    int24 internal constant START_TICK = 3000;
    int24 internal constant RANGE_LOWER = 2400;
    int24 internal constant RANGE_UPPER = 3600;

    Vault internal vault;
    CLPoolManager internal clManager;
    BinPoolManager internal binManager;
    CLPoolManagerRouter internal clRouter;
    BinSwapHelper internal binSwap;
    BinLiquidityHelper internal binLiquidity;

    Currency internal currency0;
    Currency internal currency1;
    MockERC20 internal token0;
    MockERC20 internal token1;

    PoolKey internal clKey;
    PoolKey internal clKeyV4Recipe;
    PoolKey internal binKey;

    address internal alice = makeAddr("alice");

    function setUp() public {
        vault = new Vault();
        clManager = new CLPoolManager(vault);
        binManager = new BinPoolManager(vault);
        vault.registerApp(address(clManager));
        vault.registerApp(address(binManager));

        clRouter = new CLPoolManagerRouter(vault, clManager);
        binSwap = new BinSwapHelper(binManager, vault);
        binLiquidity = new BinLiquidityHelper(binManager, vault);

        MockERC20 a = new MockERC20("TEST0", "T0", 18);
        MockERC20 b = new MockERC20("TEST1", "T1", 18);
        (currency0, currency1) = SortTokens.sort(a, b);
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        // LP (this contract) and trader (alice) both hold BOTH tokens, so no balance slot the swap
        // touches is ever written from zero.
        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        token0.mint(alice, 1e24);
        token1.mint(alice, 1e24);
        token0.approve(address(clRouter), type(uint256).max);
        token1.approve(address(clRouter), type(uint256).max);
        token0.approve(address(binLiquidity), type(uint256).max);
        token1.approve(address(binLiquidity), type(uint256).max);
        vm.startPrank(alice);
        token0.approve(address(clRouter), type(uint256).max);
        token1.approve(address(clRouter), type(uint256).max);
        token0.approve(address(binSwap), type(uint256).max);
        token1.approve(address(binSwap), type(uint256).max);
        vm.stopPrank();

        // ---- CL, benchmark shape ----
        clKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: clManager,
            fee: FEE,
            parameters: bytes32(0).setTickSpacing(TICK_SPACING)
        });
        clManager.initialize(clKey, TickMath.getSqrtRatioAtTick(START_TICK));
        clRouter.modifyPosition(
            clKey,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: RANGE_LOWER, tickUpper: RANGE_UPPER, liquidityDelta: LIQUIDITY, salt: 0
            }),
            ""
        );
        _clSwap(clKey, true, SWAP_IN); // warm-up: feeGrowthGlobal0 leaves zero
        _clSwap(clKey, false, SWAP_IN); // warm-up: feeGrowthGlobal1 leaves zero

        // ---- CL, Uniswap v4 "swap against liquidity" recipe ----
        MockERC20 c = new MockERC20("TEST2", "T2", 18);
        MockERC20 d = new MockERC20("TEST3", "T3", 18);
        (Currency c2, Currency c3) = SortTokens.sort(c, d);
        MockERC20(Currency.unwrap(c2)).mint(address(this), 1e30);
        MockERC20(Currency.unwrap(c3)).mint(address(this), 1e30);
        MockERC20(Currency.unwrap(c2)).approve(address(clRouter), type(uint256).max);
        MockERC20(Currency.unwrap(c3)).approve(address(clRouter), type(uint256).max);
        clKeyV4Recipe = PoolKey({
            currency0: c2,
            currency1: c3,
            hooks: IHooks(address(0)),
            poolManager: clManager,
            fee: FEE,
            parameters: bytes32(0).setTickSpacing(TICK_SPACING)
        });
        clManager.initialize(clKeyV4Recipe, SQRT_PRICE_1_1);
        clRouter.modifyPosition(
            clKeyV4Recipe,
            ICLPoolManager.ModifyLiquidityParams({tickLower: -120, tickUpper: 120, liquidityDelta: 1e18, salt: 0}),
            ""
        );

        // ---- Bin, benchmark shape: one bin, both sides ----
        binKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(binManager)),
            fee: FEE,
            parameters: bytes32(0).setBinStep(BIN_STEP)
        });
        binManager.initialize(binKey, ACTIVE_ID);
        bytes32[] memory configs = new bytes32[](1);
        configs[0] =
            LiquidityConfigurations.encodeParams(uint64(BinConstants.PRECISION), uint64(BinConstants.PRECISION), ACTIVE_ID);
        binLiquidity.mint(
            binKey,
            IBinPoolManager.MintParams({
                liquidityConfigs: configs, amountIn: PackedUint128Math.encode(uint128(1e22), uint128(1e22)), salt: 0
            }),
            ""
        );
        _binSwap(true, SWAP_IN);
        _binSwap(false, SWAP_IN);
    }

    /*//////////////////////////////////////////////////////////////
                              BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    /// CL hookless, 1e18 exact-in zeroForOne, through CLPoolManagerRouter.
    function test_gas_cl_hookless_exactIn_1e18() public {
        _clSwap(clKey, true, SWAP_IN);
        uint256 gas = vm.snapshotGasLastCall("cl_hookless_exactIn_1e18");
        _clSwap(clKey, true, SWAP_IN);
        uint256 again = vm.snapshotGasLastCall("cl_hookless_exactIn_1e18_repeat");
        console2.log("cl_hookless_exactIn_1e18  %d  (repeat %d)", gas, again);
        _assertNoTickCrossed(clKey);
    }

    /// CL hookless, 1e18 exact-in oneForZero (the other direction).
    function test_gas_cl_hookless_exactIn_1e18_oneForZero() public {
        _clSwap(clKey, false, SWAP_IN);
        uint256 gas = vm.snapshotGasLastCall("cl_hookless_exactIn_1e18_oneForZero");
        _clSwap(clKey, false, SWAP_IN);
        uint256 again = vm.snapshotGasLastCall("cl_hookless_exactIn_1e18_oneForZero_repeat");
        console2.log("cl_hookless_exactIn_1e18_oneForZero  %d  (repeat %d)", gas, again);
        _assertNoTickCrossed(clKey);
    }

    /// Uniswap v4-core `swap against liquidity` recipe: liquidity 1e18 at [-120,120], 100 wei exact-in,
    /// first swap (feeGrowthGlobal0 and the trader's output balance written from zero) then the
    /// second — v4 snapshots the second, which is the steady-state one.
    function test_gas_cl_hookless_v4recipe() public {
        vm.startPrank(alice);
        MockERC20(Currency.unwrap(clKeyV4Recipe.currency0)).mint(alice, 1e18);
        MockERC20(Currency.unwrap(clKeyV4Recipe.currency0)).approve(address(clRouter), type(uint256).max);
        vm.stopPrank();
        _clSwapLimit(clKeyV4Recipe, true, 100, TickMath.getSqrtRatioAtTick(-6932)); // v4's SQRT_PRICE_1_2
        uint256 first = vm.snapshotGasLastCall("cl_hookless_v4recipe_firstSwap");
        _clSwapLimit(clKeyV4Recipe, true, 100, TickMath.getSqrtRatioAtTick(-13864)); // v4's SQRT_PRICE_1_4
        uint256 second = vm.snapshotGasLastCall("cl_hookless_v4recipe_secondSwap");
        console2.log("cl_hookless_v4recipe  first %d  second (= v4 'swap against liquidity') %d", first, second);
    }

    /// Bin hookless, 1e18 exact-in X->Y inside one bin, through BinSwapHelper.
    function test_gas_bin_hookless_exactIn_1e18() public {
        _binSwap(true, SWAP_IN);
        uint256 gas = vm.snapshotGasLastCall("bin_hookless_exactIn_1e18");
        _binSwap(true, SWAP_IN);
        uint256 again = vm.snapshotGasLastCall("bin_hookless_exactIn_1e18_repeat");
        console2.log("bin_hookless_exactIn_1e18  %d  (repeat %d)", gas, again);
        (uint24 activeId,,) = binManager.getSlot0(binKey.toId());
        assertEq(activeId, ACTIVE_ID, "swap must stay inside the active bin");
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _clSwap(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal {
        _clSwapLimit(key, zeroForOne, amountIn, zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1);
    }

    function _clSwapLimit(PoolKey memory key, bool zeroForOne, uint256 amountIn, uint160 limit) internal {
        vm.prank(alice);
        clRouter.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
    }

    function _binSwap(bool swapForY, uint256 amountIn) internal {
        vm.prank(alice);
        binSwap.swap(
            binKey,
            swapForY,
            -int128(int256(amountIn)),
            BinSwapHelper.TestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
    }

    function _assertNoTickCrossed(PoolKey memory key) internal view {
        (, int24 tick,,) = clManager.getSlot0(key.toId());
        // Four 1e18 swaps against 1e24 liquidity move the price well under one tick spacing:
        // the pool must still sit in the tick-spacing bucket it was initialised in.
        assertTrue(tick >= START_TICK - TICK_SPACING && tick < START_TICK + TICK_SPACING, "swap must not cross a tick");
        assertTrue(tick > RANGE_LOWER && tick < RANGE_UPPER, "swap must stay inside the range");
    }
}
