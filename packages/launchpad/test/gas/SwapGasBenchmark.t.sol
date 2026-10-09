// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {LiquidityConfigurations} from "infinity-core/src/pool-bin/libraries/math/LiquidityConfigurations.sol";
import {PackedUint128Math} from "infinity-core/src/pool-bin/libraries/math/PackedUint128Math.sol";
import {Constants as BinConstants} from "infinity-core/src/pool-bin/libraries/Constants.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {BinLiquidityHelper} from "infinity-core/test/pool-bin/helpers/BinLiquidityHelper.sol";

import {ICLRouterBase} from "infinity-periphery/src/pool-cl/interfaces/ICLRouterBase.sol";
import {IBinRouterBase} from "infinity-periphery/src/pool-bin/interfaces/IBinRouterBase.sol";
import {Actions} from "infinity-periphery/src/libraries/Actions.sol";
import {ActionConstants} from "infinity-periphery/src/libraries/ActionConstants.sol";
import {Plan, Planner} from "infinity-periphery/src/libraries/Planner.sol";

import {UniversalRouter} from "deepcore-router/src/UniversalRouter.sol";
import {RouterParameters} from "deepcore-router/src/base/RouterImmutables.sol";
import {Commands} from "deepcore-router/src/libraries/Commands.sol";

import {LaunchGuardHook, ILaunchTokenOrigin} from "deepcore-hooks/src/launch/LaunchGuardHook.sol";
import {LaunchTaxModule} from "deepcore-hooks/src/launch/LaunchTaxModule.sol";
import {RevShareHook} from "deepcore-hooks-revshare/src/RevShareHook.sol";

/// @title SwapGasBenchmark (launchpad package) — what a trader pays on a DeepCore pool, by router and by hook.
///
/// @notice Single-hop EXACT-IN swaps of 1e18 on 0.30 % / tick-spacing-60 CL pools with identical
/// liquidity (1e24 over [2400, 3600], price at tick 3000 — see the core-package twin for why), through
/// the real `UniversalRouter` (Permit2 allowance already granted, `INFI_SWAP` →
/// `CL_SWAP_EXACT_IN_SINGLE` + `SETTLE_ALL` + `TAKE_ALL`) and through core's `CLPoolManagerRouter`.
///
/// Scenarios (every pool is in STEADY STATE: `setUp` swapped once in each direction so no slot the
/// measured swap writes is zero, and no measured swap crosses a tick):
///   hookless           control pool, static 3000 fee
///   guard_decay        `LaunchGuardHook`, enabled, inside the decay window (fee 10 % → 0.30 % over 1 h,
///                      measured 10 min in); no `maxBuyPerTx`; no tax
///   guard_settled      `LaunchGuardHook`, decay elapsed, fee override = 3000; no tax
///   guard_settled_tax  as above plus a live creator tax (1 % buy, 1 % sell, split 70/10/20)
///   revshare           `RevShareHook`, 1 % cut, 20 % donated to LPs and 80 % to one beneficiary
///   bin_hookless       Bin pool, one bin, through the UniversalRouter (`BIN_SWAP_EXACT_IN_SINGLE`)
///   v4periphery_recipe hookless pool built the way Uniswap v4-periphery's `V4Router_ExactInputSingle`
///                      snapshot builds its pool (1:1, 200e18 liquidity over the full range, 1e18 exact-in,
///                      FIRST swap after setup — fee growth written from zero), so that published number
///                      has a like-for-like row; the second swap shows the steady state of the same pool
///
/// Every figure is the COLD execution gas of the router frame — forge starts each top-level call from
/// the test with a fresh access list (see the core twin) — and excludes the 21,000 intrinsic gas and
/// calldata. The calldata cost of each UniversalRouter call is computed and logged separately
/// (EIP-2028: 4 gas per zero byte, 16 per non-zero) so the document can state the full transaction.
///
/// Compiler settings are this package's (`optimizer_runs = 1_000_000`), which is why the hookless row
/// here differs slightly from the core package's 25,666-run build; the hook deltas are same-build.
///
/// Run: `forge test --match-path test/gas/SwapGasBenchmark.t.sol -vv`
contract SwapGasBenchmark is Test, DeployPermit2 {
    using CLPoolParametersHelper for bytes32;
    using BinPoolParametersHelper for bytes32;
    using Planner for Plan;

    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant START_TICK = 3000;
    int24 internal constant RANGE_LOWER = 2400;
    int24 internal constant RANGE_UPPER = 3600;
    int128 internal constant LIQUIDITY = 1e24;
    uint256 internal constant SWAP_IN = 1e18;
    uint16 internal constant BIN_STEP = 10;
    uint24 internal constant ACTIVE_ID = 2 ** 23;

    uint256 internal constant T0 = 1_800_000_000;
    uint32 internal constant DECAY_LONG = 3600;
    uint32 internal constant DECAY_SHORT = 60;
    uint256 internal constant MEASURE_AT = T0 + 600;

    Vault internal vault;
    CLPoolManager internal clManager;
    BinPoolManager internal binManager;
    IAllowanceTransfer internal permit2;
    WETH internal weth;
    UniversalRouter internal router;
    CLPoolManagerRouter internal clRouter;
    BinLiquidityHelper internal binLiquidity;
    LaunchGuardHook internal guard;
    RevShareHook internal revShare;

    Currency internal currency0;
    Currency internal currency1;
    MockERC20 internal token0;
    MockERC20 internal token1;

    PoolKey internal keyHookless;
    PoolKey internal keyGuardDecay;
    PoolKey internal keyGuardSettled;
    PoolKey internal keyGuardSettledTax;
    PoolKey internal keyRevShare;
    PoolKey internal keyBin;
    PoolKey internal keyV4PeripheryRecipe;

    address internal alice = makeAddr("alice");
    address internal creator = makeAddr("creator");
    address internal integrator = makeAddr("integrator");
    address internal treasury = makeAddr("treasury");
    address internal guardian = makeAddr("guardian");

    function setUp() public {
        vm.warp(T0);

        vault = new Vault();
        clManager = new CLPoolManager(vault);
        binManager = new BinPoolManager(vault);
        vault.registerApp(address(clManager));
        vault.registerApp(address(binManager));

        permit2 = IAllowanceTransfer(deployPermit2());
        weth = new WETH();
        router = new UniversalRouter(
            RouterParameters({
                permit2: address(permit2),
                weth9: address(weth),
                v2Factory: address(0),
                v3Factory: address(0),
                v3Deployer: address(0),
                v2InitCodeHash: bytes32(0),
                v3InitCodeHash: bytes32(0),
                stableFactory: address(0),
                stableInfo: address(0),
                infiVault: address(vault),
                infiClPoolManager: address(clManager),
                infiBinPoolManager: address(binManager)
            })
        );
        clRouter = new CLPoolManagerRouter(vault, clManager);
        binLiquidity = new BinLiquidityHelper(binManager, vault);

        guard = new LaunchGuardHook(clManager, ILaunchTokenOrigin(address(0)), treasury, 0);
        revShare = new RevShareHook(clManager, address(this), guardian, uint40(12 hours), 8);

        MockERC20 a = new MockERC20("TEST0", "T0", 18);
        MockERC20 b = new MockERC20("TEST1", "T1", 18);
        (currency0, currency1) = address(a) < address(b) ? (Currency.wrap(address(a)), Currency.wrap(address(b)))
            : (Currency.wrap(address(b)), Currency.wrap(address(a)));
        token0 = MockERC20(Currency.unwrap(currency0));
        token1 = MockERC20(Currency.unwrap(currency1));

        token0.mint(address(this), 1e30);
        token1.mint(address(this), 1e30);
        token0.mint(alice, 1e24);
        token1.mint(alice, 1e24);
        token0.approve(address(clRouter), type(uint256).max);
        token1.approve(address(clRouter), type(uint256).max);
        token0.approve(address(binLiquidity), type(uint256).max);
        token1.approve(address(binLiquidity), type(uint256).max);

        // Trader approvals: Permit2 for the UniversalRouter, plain ERC-20 for the test router.
        // Measured once in test_gas_approvals_measuredOnce, never inside a swap figure.
        vm.startPrank(alice);
        token0.approve(address(permit2), type(uint256).max);
        token1.approve(address(permit2), type(uint256).max);
        permit2.approve(address(token0), address(router), type(uint160).max, type(uint48).max);
        permit2.approve(address(token1), address(router), type(uint160).max, type(uint48).max);
        token0.approve(address(clRouter), type(uint256).max);
        token1.approve(address(clRouter), type(uint256).max);
        vm.stopPrank();

        // ---- pools ----
        keyHookless = _clKey(IHooks(address(0)), FEE, 0);
        keyGuardDecay = _clKey(guard, LPFeeLibrary.DYNAMIC_FEE_FLAG, guard.getHooksRegistrationBitmap());
        keyGuardSettled = _clKey(guard, LPFeeLibrary.DYNAMIC_FEE_FLAG, guard.getHooksRegistrationBitmap());
        keyGuardSettledTax = _clKey(guard, LPFeeLibrary.DYNAMIC_FEE_FLAG, guard.getHooksRegistrationBitmap());
        keyRevShare = _clKey(revShare, FEE, revShare.getHooksRegistrationBitmap());
        // A pool id is (currencies, hook, manager, fee, parameters): three guard pools of the same
        // shape need their own token pairs. Same shape is the point, so the pairs differ, not the pool.
        keyGuardSettled = _withFreshTokens(keyGuardSettled);
        keyGuardSettledTax = _withFreshTokens(keyGuardSettledTax);

        // Launch configs. startTime == now is allowed; the decay pool is measured 600 s in.
        guard.configureLaunch(keyGuardDecay, _launchConfig(DECAY_LONG));
        guard.configureLaunch(keyGuardSettled, _launchConfig(DECAY_SHORT));
        guard.configureLaunch(keyGuardSettledTax, _launchConfig(DECAY_SHORT));
        // The guard takes its fee itself and refuses a pool without the split it pays by.
        LaunchTaxModule.FeeSplit memory split = LaunchTaxModule.FeeSplit({
            creator: creator,
            creatorBps: 7000,
            protocolBps: 2000,
            integratorBps: 1000,
            integrator: integrator
        });
        guard.configureFeeSplit(keyGuardDecay, split);
        guard.configureFeeSplit(keyGuardSettled, split);
        guard.configureFeeSplit(keyGuardSettledTax, split);
        guard.configureTax(
            keyGuardSettledTax,
            LaunchTaxModule.TaxConfig({
                buyBps: 100,
                sellBps: 100,
                expiresAt: uint40(T0 + 30 days),
                creator: creator,
                integrator: integrator,
                creatorBps: 7000,
                protocolBps: 1000,
                integratorBps: 2000
            })
        );

        // RevShare: claim LP-only, roster, then the real split (the order the hook requires).
        revShare.configure(keyRevShare, _revParams(10_000, 0));
        RevShareHook.Beneficiary[] memory roster = new RevShareHook.Beneficiary[](1);
        roster[0] = RevShareHook.Beneficiary({recipient: treasury, weight: 1});
        revShare.setBeneficiaries(keyRevShare, roster);
        revShare.configure(keyRevShare, _revParams(2_000, 8_000));

        _initAndSeed(keyHookless);
        _initAndSeed(keyGuardDecay);
        _initAndSeed(keyGuardSettled);
        _initAndSeed(keyGuardSettledTax);
        _initAndSeed(keyRevShare);

        // ---- v4-periphery recipe: fresh pair, 1:1, full-range 200e18, never swapped before the test ----
        keyV4PeripheryRecipe = _withFreshTokens(_clKey(IHooks(address(0)), FEE, 0));
        clManager.initialize(keyV4PeripheryRecipe, 79228162514264337593543950336);
        clRouter.modifyPosition(
            keyV4PeripheryRecipe,
            ICLPoolManager.ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 200 ether, salt: 0}),
            ""
        );

        // ---- Bin ----
        keyBin = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: IPoolManager(address(binManager)),
            fee: FEE,
            parameters: bytes32(0).setBinStep(BIN_STEP)
        });
        binManager.initialize(keyBin, ACTIVE_ID);
        bytes32[] memory configs = new bytes32[](1);
        configs[0] =
            LiquidityConfigurations.encodeParams(uint64(BinConstants.PRECISION), uint64(BinConstants.PRECISION), ACTIVE_ID);
        binLiquidity.mint(
            keyBin,
            IBinPoolManager.MintParams({
                liquidityConfigs: configs, amountIn: PackedUint128Math.encode(uint128(1e22), uint128(1e22)), salt: 0
            }),
            ""
        );

        // ---- steady state: one swap each way on every pool, through both routers ----
        vm.warp(MEASURE_AT);
        PoolKey[5] memory keys = [keyHookless, keyGuardDecay, keyGuardSettled, keyGuardSettledTax, keyRevShare];
        for (uint256 i; i < keys.length; ++i) {
            _urSwap(keys[i], true);
            _urSwap(keys[i], false);
            _clRouterSwap(keys[i], true);
            _clRouterSwap(keys[i], false);
        }
        _urBinSwap(true);
        _urBinSwap(false);

        // Sanity: the guard's schedule is where the scenario names say it is.
        assertGt(guard.currentFee(keyGuardDecay.toId()), FEE, "decay pool must still be decaying");
        assertEq(guard.currentFee(keyGuardSettled.toId()), FEE, "settled pool must be at its final fee");
        assertEq(guard.currentFee(keyGuardSettledTax.toId()), FEE, "settled+tax pool must be at its final fee");
    }

    /*//////////////////////////////////////////////////////////////
                              BENCHMARKS
    //////////////////////////////////////////////////////////////*/

    function test_gas_hookless() public {
        _measure("hookless", keyHookless);
    }

    function test_gas_guard_decay() public {
        _measure("guard_decay", keyGuardDecay);
        assertGt(guard.currentFee(keyGuardDecay.toId()), FEE);
    }

    function test_gas_guard_settled() public {
        _measure("guard_settled", keyGuardSettled);
    }

    function test_gas_guard_settled_tax() public {
        // The launch token is currency1 here, so the quote, which the tax and the fee are taken in, is
        // currency0.
        uint256 takenBefore = guard.totalTaken(keyGuardSettledTax.toId(), keyGuardSettledTax.currency0);
        uint256 feeBefore = guard.feeTaken(keyGuardSettledTax.toId(), keyGuardSettledTax.currency0);
        _measure("guard_settled_tax", keyGuardSettledTax);
        assertGt(guard.totalTaken(keyGuardSettledTax.toId(), keyGuardSettledTax.currency0), takenBefore, "tax must be live");
        assertGt(guard.feeTaken(keyGuardSettledTax.toId(), keyGuardSettledTax.currency0), feeBefore, "fee must be taken");
        assertEq(guard.totalTaken(keyGuardSettledTax.toId(), keyGuardSettledTax.currency1), 0, "never in the launch token");
    }

    function test_gas_revshare() public {
        uint256 takenBefore = revShare.totalTaken(keyRevShare.toId(), currency1);
        _measure("revshare", keyRevShare);
        assertGt(revShare.totalTaken(keyRevShare.toId(), currency1), takenBefore, "cut must be live");
    }

    function test_gas_bin_hookless_universalRouter() public {
        (bytes memory commands, bytes[] memory inputs) = _urBinCalldata(true);
        vm.prank(alice);
        router.execute(commands, inputs);
        uint256 gas = vm.snapshotGasLastCall("bin_hookless_universalRouter");
        uint256 cd = _calldataGas(abi.encodeWithSignature("execute(bytes,bytes[])", commands, inputs));
        console2.log("bin_hookless  UniversalRouter %d  calldata %d", gas, cd);
        (uint24 activeId,,) = binManager.getSlot0(keyBin.toId());
        assertEq(activeId, ACTIVE_ID, "swap must stay inside the active bin");
    }

    /// Uniswap v4-periphery `V4Router_ExactInputSingle` recipe on DeepCore's UniversalRouter: first swap
    /// of a fresh full-range pool (their snapshot), then the same swap again (steady state).
    function test_gas_hookless_v4peripheryRecipe() public {
        (bytes memory commands, bytes[] memory inputs) = _urCalldata(keyV4PeripheryRecipe, true);
        vm.prank(alice);
        router.execute(commands, inputs);
        uint256 first = vm.snapshotGasLastCall("hookless_v4peripheryRecipe_firstSwap_universalRouter");
        vm.prank(alice);
        router.execute(commands, inputs);
        uint256 second = vm.snapshotGasLastCall("hookless_v4peripheryRecipe_secondSwap_universalRouter");
        _clRouterSwap(keyV4PeripheryRecipe, true);
        uint256 tr = vm.snapshotGasLastCall("hookless_v4peripheryRecipe_thirdSwap_clPoolManagerRouter");
        console2.log("hookless_v4peripheryRecipe  UniversalRouter first %d  second %d  CLPoolManagerRouter third %d", first, second, tr);
    }

    /// The one-time cost of being ABLE to swap: not part of any swap figure.
    function test_gas_approvals_measuredOnce() public {
        address bob = makeAddr("bob");
        token0.mint(bob, 1e18);
        vm.startPrank(bob);
        token0.approve(address(permit2), type(uint256).max);
        uint256 erc20ToPermit2 = vm.snapshotGasLastCall("approve_erc20_to_permit2");
        permit2.approve(address(token0), address(router), type(uint160).max, type(uint48).max);
        uint256 permit2ToRouter = vm.snapshotGasLastCall("approve_permit2_to_router");
        token0.approve(address(clRouter), type(uint256).max);
        uint256 erc20ToRouter = vm.snapshotGasLastCall("approve_erc20_to_testRouter");
        vm.stopPrank();
        console2.log("approvals  erc20->permit2 %d  permit2->router %d  erc20->testRouter %d", erc20ToPermit2, permit2ToRouter, erc20ToRouter);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _measure(string memory name, PoolKey memory key) internal {
        (bytes memory commands, bytes[] memory inputs) = _urCalldata(key, true);
        vm.prank(alice);
        router.execute(commands, inputs);
        uint256 ur = vm.snapshotGasLastCall(string.concat(name, "_universalRouter"));
        uint256 cd = _calldataGas(abi.encodeWithSignature("execute(bytes,bytes[])", commands, inputs));

        _clRouterSwap(key, true);
        uint256 tr = vm.snapshotGasLastCall(string.concat(name, "_clPoolManagerRouter"));

        console2.log(string.concat(name, "  UniversalRouter %d  calldata %d  CLPoolManagerRouter %d"), ur, cd, tr);
        _assertNoTickCrossed(key);
    }

    function _clKey(IHooks hooks, uint24 fee, uint16 bitmap) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: hooks,
            poolManager: clManager,
            fee: fee,
            parameters: bytes32(uint256(bitmap)).setTickSpacing(TICK_SPACING)
        });
    }

    /// Same shape, fresh token pair (minted, approved for alice and the LP exactly like the main pair).
    function _withFreshTokens(PoolKey memory key) internal returns (PoolKey memory) {
        MockERC20 a = new MockERC20("TESTa", "Ta", 18);
        MockERC20 b = new MockERC20("TESTb", "Tb", 18);
        (MockERC20 lo, MockERC20 hi) = address(a) < address(b) ? (a, b) : (b, a);
        MockERC20[2] memory pair = [lo, hi];
        for (uint256 i; i < 2; ++i) {
            pair[i].mint(address(this), 1e30);
            pair[i].mint(alice, 1e24);
            pair[i].approve(address(clRouter), type(uint256).max);
            vm.startPrank(alice);
            pair[i].approve(address(permit2), type(uint256).max);
            permit2.approve(address(pair[i]), address(router), type(uint160).max, type(uint48).max);
            pair[i].approve(address(clRouter), type(uint256).max);
            vm.stopPrank();
        }
        key.currency0 = Currency.wrap(address(lo));
        key.currency1 = Currency.wrap(address(hi));
        return key;
    }

    function _launchConfig(uint32 decaySeconds) internal pure returns (LaunchGuardHook.LaunchConfig memory) {
        return LaunchGuardHook.LaunchConfig({
            startTime: uint40(T0),
            decaySeconds: decaySeconds,
            initialFeeBips: 100_000,
            finalFeeBips: FEE,
            maxBuyPerTx: 0,
            launchTokenIsCurrency0: false, // zeroForOne (quote in, token out) is a buy
            enabled: true
        });
    }

    function _revParams(uint16 lpBps, uint16 benBps) internal pure returns (RevShareHook.ConfigParams memory) {
        return RevShareHook.ConfigParams({
            feePips: 10_000,
            lpDonateBps: lpBps,
            beneficiaryBps: benBps,
            distributorBps: 0,
            distributor: address(0),
            enabled: true
        });
    }

    function _initAndSeed(PoolKey memory key) internal {
        clManager.initialize(key, TickMath.getSqrtRatioAtTick(START_TICK));
        clRouter.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: RANGE_LOWER, tickUpper: RANGE_UPPER, liquidityDelta: LIQUIDITY, salt: 0
            }),
            ""
        );
    }

    function _urCalldata(PoolKey memory key, bool zeroForOne)
        internal
        pure
        returns (bytes memory commands, bytes[] memory inputs)
    {
        ICLRouterBase.CLSwapExactInputSingleParams memory params =
            ICLRouterBase.CLSwapExactInputSingleParams(key, zeroForOne, uint128(SWAP_IN), 0, "");
        Plan memory plan = Planner.init().add(Actions.CL_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        (Currency inC, Currency outC) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        bytes memory data = plan.finalizeSwap(inC, outC, ActionConstants.MSG_SENDER);
        commands = abi.encodePacked(bytes1(uint8(Commands.INFI_SWAP)));
        inputs = new bytes[](1);
        inputs[0] = data;
    }

    function _urBinCalldata(bool swapForY) internal view returns (bytes memory commands, bytes[] memory inputs) {
        IBinRouterBase.BinSwapExactInputSingleParams memory params =
            IBinRouterBase.BinSwapExactInputSingleParams(keyBin, swapForY, uint128(SWAP_IN), 0, "");
        Plan memory plan = Planner.init().add(Actions.BIN_SWAP_EXACT_IN_SINGLE, abi.encode(params));
        (Currency inC, Currency outC) = swapForY ? (keyBin.currency0, keyBin.currency1) : (keyBin.currency1, keyBin.currency0);
        bytes memory data = plan.finalizeSwap(inC, outC, ActionConstants.MSG_SENDER);
        commands = abi.encodePacked(bytes1(uint8(Commands.INFI_SWAP)));
        inputs = new bytes[](1);
        inputs[0] = data;
    }

    function _urSwap(PoolKey memory key, bool zeroForOne) internal {
        (bytes memory commands, bytes[] memory inputs) = _urCalldata(key, zeroForOne);
        vm.prank(alice);
        router.execute(commands, inputs);
    }

    function _urBinSwap(bool swapForY) internal {
        (bytes memory commands, bytes[] memory inputs) = _urBinCalldata(swapForY);
        vm.prank(alice);
        router.execute(commands, inputs);
    }

    function _clRouterSwap(PoolKey memory key, bool zeroForOne) internal {
        vm.prank(alice);
        clRouter.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(SWAP_IN),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
    }

    /// EIP-2028 calldata gas of a transaction payload: 4 per zero byte, 16 per non-zero byte.
    function _calldataGas(bytes memory data) internal pure returns (uint256 gas) {
        for (uint256 i; i < data.length; ++i) {
            gas += data[i] == 0 ? 4 : 16;
        }
    }

    function _assertNoTickCrossed(PoolKey memory key) internal view {
        (, int24 tick,,) = clManager.getSlot0(key.toId());
        assertTrue(tick >= START_TICK - TICK_SPACING && tick < START_TICK + TICK_SPACING, "swap must not cross a tick");
    }
}
