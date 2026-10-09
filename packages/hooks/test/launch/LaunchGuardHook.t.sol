// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "infinity-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

import {TokenFixture} from "infinity-core/test/helpers/TokenFixture.sol";
import {SortTokens} from "infinity-core/test/helpers/SortTokens.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";

import {BaseCLHook} from "../../src/base/BaseCLHook.sol";
import {LaunchGuardHook, ILaunchTokenOrigin} from "../../src/launch/LaunchGuardHook.sol";
import {LaunchTaxModule} from "../../src/launch/LaunchTaxModule.sol";

/// @dev The protocol recipient of the fee and of the creator tax, for every hook these tests deploy.
/// The money path is exercised in `LaunchTax.t.sol`; this file is about the guard: the gate, the
/// schedule, the cap, and that the schedule is CHARGED BY THE GUARD IN THE QUOTE CURRENCY while
/// core applies an LP fee of zero.
address constant TAX_PROTOCOL = address(0xFEE);

/// @dev A `LaunchGuardHook` that records the `sender` argument core hands to `beforeSwap`.
/// Used only by `test_sender_isTheLockerNotTheBuyer` to pin the constraint the whole design rests
/// on. Behaviour is otherwise identical to the production hook.
contract SenderRecordingLaunchGuardHook is LaunchGuardHook {
    address public lastSwapSender;
    uint256 public swapCount;

    constructor(ICLPoolManager _pm) LaunchGuardHook(_pm, ILaunchTokenOrigin(address(0)), TAX_PROTOCOL, 0) {}

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        ICLPoolManager.SwapParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        lastSwapSender = sender;
        swapCount++;
        return super._beforeSwap(sender, key, params, hookData);
    }
}

/// @dev Stands in for `LaunchTokenFactory.deployerOf`.
contract MockLaunchTokenOrigin {
    mapping(address token => address deployer) public deployerOf;

    function set(address token, address deployer) external {
        deployerOf[token] = deployer;
    }
}

contract LaunchGuardHookTest is Test, Deployers, TokenFixture {
    using LPFeeLibrary for uint24;
    using CurrencyLibrary for Currency;

    Vault vault;
    CLPoolManager poolManager;
    LaunchGuardHook hook;
    CLPoolManagerRouter router;

    PoolKey key;
    PoolId poolId;

    /// @dev Foundry starts tests at timestamp 1; the default launch opens 100 seconds later.
    uint40 constant START_TIME = 101;
    uint32 constant DECAY_SECONDS = 100;
    uint24 constant INITIAL_FEE = 300_000; // 30%
    uint24 constant FINAL_FEE = 3_000; // 0.30%

    int256 constant SWAP_AMOUNT = -10_000; // exact input, tiny relative to liquidity

    /// @dev The fee split every pool in this file is born with. `LaunchTax.t.sol` tests its bounds.
    address constant FEE_CREATOR = address(0xC0FFEE);
    address constant FEE_INTEGRATOR = address(0x1D7E);

    // Mirrors of the hook's events, so `vm.expectEmit` can match them.
    event LaunchClaimed(PoolId indexed poolId, address indexed owner);
    event LaunchConfigured(
        PoolId indexed poolId,
        address indexed owner,
        uint40 startTime,
        uint32 decaySeconds,
        uint24 initialFeeBips,
        uint24 finalFeeBips,
        uint128 maxBuyPerTx,
        bool launchTokenIsCurrency0,
        bool enabled
    );
    event LaunchStarted(PoolId indexed poolId, uint256 timestamp);


    function setUp() public {
        (vault, poolManager) = createFreshManager();
        hook = new LaunchGuardHook(poolManager, ILaunchTokenOrigin(address(0)), TAX_PROTOCOL, 0);
        router = new CLPoolManagerRouter(vault, poolManager);

        initializeTokens();
        key = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 1);
        poolId = key.toId();

        hook.configureLaunch(key, _defaultConfig());
        hook.configureFeeSplit(key, _defaultFeeSplit());
        poolManager.initialize(key, SQRT_RATIO_1_1);

        IERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        router.modifyPosition(
            key,
            ICLPoolManager.ModifyLiquidityParams({tickLower: -10, tickUpper: 10, liquidityDelta: 10_000 ether, salt: 0}),
            ZERO_BYTES
        );
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _key(IHooks _hook, uint24 fee, int24 tickSpacing) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: _hook,
            poolManager: poolManager,
            fee: fee,
            parameters: CLPoolParametersHelper.setTickSpacing(
                bytes32(uint256(_hook.getHooksRegistrationBitmap())), tickSpacing
            )
        });
    }

    function _defaultConfig() internal pure returns (LaunchGuardHook.LaunchConfig memory) {
        return LaunchGuardHook.LaunchConfig({
            startTime: START_TIME,
            decaySeconds: DECAY_SECONDS,
            initialFeeBips: INITIAL_FEE,
            finalFeeBips: FINAL_FEE,
            maxBuyPerTx: 0,
            launchTokenIsCurrency0: false, // currency1 is the launched token => a buy is zeroForOne
            enabled: true
        });
    }

    function _defaultFeeSplit() internal pure returns (LaunchTaxModule.FeeSplit memory) {
        return LaunchTaxModule.FeeSplit({
            creator: FEE_CREATOR,
            creatorBps: 6_000,
            protocolBps: 2_000, // exactly the fee's floor
            integratorBps: 2_000, // exactly the cap
            integrator: FEE_INTEGRATOR
        });
    }

    /// @dev Core wraps a reverting hook in ERC-7751 `WrappedError`. Rebuild that envelope so tests
    /// can assert on the hook's own error rather than a generic failure.
    function _expectHookRevert(address hookAddr, bytes4 hookFn, bytes memory inner) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                hookAddr,
                hookFn,
                inner,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _swapParams(bool zeroForOne, int256 amountSpecified)
        internal
        pure
        returns (ICLPoolManager.SwapParams memory)
    {
        return ICLPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? SQRT_RATIO_1_2 : SQRT_RATIO_4_1
        });
    }

    function _swap(PoolKey memory k, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return router.swap(
            k,
            _swapParams(zeroForOne, amountSpecified),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ZERO_BYTES
        );
    }

    /// @dev What one swap was charged, measured from outside the guard.
    struct Charge {
        uint24 lpFee; // the LP fee CORE applied, out of its own `Swap` event
        uint256 base; // the swap's quote amount: named by the trader, or computed by the pool
        uint256 fee; // growth of the pool's fee pot, in the quote
        uint256 claims; // growth of the guard's vault claims in the quote
        uint256 tokenTaken; // growth of anything the guard holds or counts in the LAUNCH TOKEN
        int256 poolQuote; // what the pool itself traded, from the trader's side
        int256 poolToken;
        int256 traderQuote; // the trader's real balance changes
        int256 traderToken;
    }

    function _tokenFootprint(PoolId id, Currency token) internal view returns (uint256) {
        return hook.feeTaken(id, token) + hook.totalTaken(id, token) + hook.grossTaken(token) + hook.totalOwed(token)
            + vault.balanceOf(address(hook), token) + token.balanceOf(address(hook));
    }

    /// @dev Executes a swap on `key` and reports what it was charged. The LP fee and the pool's own
    /// amounts are read out of core's `Swap` event, which core emits before `afterSwap`: that is
    /// the ground truth for what reached `CLPool.swap`, not what the hook said it returned.
    function _swapAndReadCharge(bool zeroForOne, int256 amountSpecified) internal returns (Charge memory) {
        return this.measureCharge(zeroForOne, amountSpecified);
    }

    /// @dev Behind an EXTERNAL call to this contract on purpose. Decoding `Vm.Log[]` takes a dozen
    /// stack slots, and via-IR inlines an internal helper into whichever test calls it: with the
    /// test's own structs live that is one slot too many ("too deep in the stack"). The router's
    /// caller is this contract either way, and `vm.expectEmit` sees the events of nested calls.
    function measureCharge(bool zeroForOne, int256 amountSpecified) external returns (Charge memory c) {
        bool tokenIs0 = hook.getLaunch(poolId).launchTokenIsCurrency0;
        (Currency quote, Currency token) = tokenIs0 ? (currency1, currency0) : (currency0, currency1);
        bool isBuy = tokenIs0 ? !zeroForOne : zeroForOne;

        uint256 feeBefore = hook.feeTaken(poolId, quote);
        uint256 claimsBefore = vault.balanceOf(address(hook), quote);
        uint256 tokenBefore = _tokenFootprint(poolId, token);
        uint256 quoteBefore = quote.balanceOf(address(this));
        uint256 heldBefore = token.balanceOf(address(this));

        vm.recordLogs();
        _swap(key, zeroForOne, amountSpecified);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(poolManager) && logs[i].topics[0] == ICLPoolManager.Swap.selector) {
                // Swap(PoolId indexed, address indexed, int128, int128, uint160, uint128, int24, uint24, uint16)
                (int128 g0, int128 g1,,,, uint24 fee,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24, uint16));
                c.lpFee = fee;
                (c.poolQuote, c.poolToken) = tokenIs0 ? (int256(g1), int256(g0)) : (int256(g0), int256(g1));
                seen = true;
            }
        }
        require(seen, "Swap event not found");

        c.fee = hook.feeTaken(poolId, quote) - feeBefore;
        c.claims = vault.balanceOf(address(hook), quote) - claimsBefore;
        c.tokenTaken = _tokenFootprint(poolId, token) - tokenBefore;
        c.traderQuote = int256(quote.balanceOf(address(this))) - int256(quoteBefore);
        c.traderToken = int256(token.balanceOf(address(this))) - int256(heldBefore);
        // The quote is the specified side of an exact-input buy and of an exact-output sell: the
        // base is then the amount the trader named. Otherwise it is the amount the pool computed.
        bool quoteSpecified = (amountSpecified < 0) == isBuy;
        c.base = quoteSpecified
            ? (amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified))
            : (c.poolQuote < 0 ? uint256(-c.poolQuote) : uint256(c.poolQuote));
    }

    /// @dev One swap on `key` that must be charged exactly `feePips` of its quote amount BY THE
    /// GUARD, in the quote, with an LP fee of zero and nothing taken in the launch token. No tax is
    /// configured in this file unless a test says so, so the guard's take is the fee alone.
    function _assertCharged(bool zeroForOne, int256 amountSpecified, uint24 feePips)
        internal
        returns (Charge memory c)
    {
        c = _swapAndReadCharge(zeroForOne, amountSpecified);
        assertEq(c.lpFee, 0, "core applied an LP fee");
        assertEq(c.fee, c.base * feePips / 1_000_000, "the guard's fee is not the schedule's");
        assertEq(c.claims, c.fee, "taken as a vault claim in the quote");
        assertEq(c.tokenTaken, 0, "the guard took launch token");
        assertEq(c.traderQuote, c.poolQuote - int256(c.fee), "the trader paid the pool's quote and the fee");
        assertEq(c.traderToken, c.poolToken, "the launch token side is the pool's alone");
    }

    function _expectedFee(uint256 elapsed) internal pure returns (uint24) {
        if (elapsed >= DECAY_SECONDS) return FINAL_FEE;
        uint256 spread = INITIAL_FEE - FINAL_FEE;
        return uint24(INITIAL_FEE - (spread * elapsed) / DECAY_SECONDS);
    }

    /*//////////////////////////////////////////////////////////////
                             REGISTRATION
    //////////////////////////////////////////////////////////////*/

    function test_bitmap_declaresOnlyWhatIsImplemented() public view {
        // bit 0 (beforeInitialize) | bit 6 (beforeSwap) | bit 7 (afterSwap)
        // | bit 10 (beforeSwapReturnsDelta) | bit 11 (afterSwapReturnsDelta) == 0x0CC1.
        // The two returns-delta bits are how the guard takes its fee and the creator tax in the
        // quote: bit 10 when the quote is the specified side of the swap, bit 11 when it is not.
        assertEq(hook.getHooksRegistrationBitmap(), uint16(0x0CC1));
        assertEq(hook.getHooksRegistrationBitmap(), uint16(1 << 0 | 1 << 6 | 1 << 7 | 1 << 10 | 1 << 11));
    }

    /// @dev `BaseCLHook`'s constructor runs `_validatePermissions` on the bitmap: bit 10 needs bit 6
    /// and bit 11 needs bit 7. A guard that deploys has passed it, and core accepts the same bitmap
    /// in a pool's parameters (the pool in `setUp` was initialized under it).
    function test_bitmap_validatesAtDeployAndIsAcceptedByCore() public {
        LaunchGuardHook fresh = new LaunchGuardHook(poolManager, ILaunchTokenOrigin(address(0)), TAX_PROTOCOL, 0);
        assertEq(fresh.getHooksRegistrationBitmap(), uint16(0x0CC1));
        assertEq(uint16(uint256(key.parameters)), uint16(0x0CC1), "the bitmap the pool was created under");
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(poolId);
        assertEq(sqrtPriceX96, SQRT_RATIO_1_1);
    }

    function test_feeCaps_leaveTheTraderSomething() public view {
        // The schedule is no longer an LP fee, so core's LPFeeTooLarge no longer bounds it; what
        // bounds it is core's `HookDeltaExceedsSwapAmount` (a hook may not take more than the swap)
        // and this hook's own caps, which are far tighter: 50% at the open, 10% after it.
        assertEq(hook.MAX_INITIAL_FEE(), 500_000);
        assertEq(hook.MAX_FINAL_FEE(), 100_000);
        assertLe(hook.MAX_FINAL_FEE(), hook.MAX_INITIAL_FEE());
        // With the creator tax at its own cap on the same base the guard takes 60% at most.
        assertEq(uint256(hook.MAX_INITIAL_FEE()) + uint256(hook.MAX_TAX_BPS()) * 100, 600_000);
        assertLt(uint256(hook.MAX_INITIAL_FEE()) + uint256(hook.MAX_TAX_BPS()) * 100, hook.FEE_DENOMINATOR());
    }

    /*//////////////////////////////////////////////////////////////
                             CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function test_configure_claimsOwnershipAndStoresConfig() public {
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60);
        PoolId id = k.toId();
        address launcher = makeAddr("launcher");

        assertEq(hook.launchOwner(id), address(0));

        vm.expectEmit(true, true, false, true, address(hook));
        emit LaunchClaimed(id, launcher);
        vm.expectEmit(true, true, false, true, address(hook));
        emit LaunchConfigured(id, launcher, START_TIME, DECAY_SECONDS, INITIAL_FEE, FINAL_FEE, 0, false, true);

        vm.prank(launcher);
        hook.configureLaunch(k, _defaultConfig());

        LaunchGuardHook.Launch memory l = hook.getLaunch(id);
        assertEq(l.owner, launcher);
        assertEq(l.startTime, START_TIME);
        assertEq(l.decaySeconds, DECAY_SECONDS);
        assertEq(l.initialFeeBips, INITIAL_FEE);
        assertEq(l.finalFeeBips, FINAL_FEE);
        assertEq(l.maxBuyPerTx, 0);
        assertTrue(l.enabled);
        assertFalse(l.launched);
    }

    function test_configure_revertsOnForeignHookAddress() public {
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60);
        k.hooks = IHooks(makeAddr("someOtherHook"));
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.HookMismatch.selector, address(k.hooks)));
        hook.configureLaunch(k, _defaultConfig());
    }

    function test_configure_revertsOnForeignPoolManager() public {
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60);
        k.poolManager = IPoolManager(makeAddr("someOtherManager"));
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.PoolManagerMismatch.selector, address(k.poolManager)));
        hook.configureLaunch(k, _defaultConfig());
    }

    function test_configure_revertsOnStaticFeePool() public {
        PoolKey memory k = _key(hook, 3000, 60);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.PoolMustUseDynamicFee.selector, uint24(3000)));
        hook.configureLaunch(k, _defaultConfig());
    }

    function test_configure_unauthorizedCallerCannotReconfigure() public {
        address attacker = makeAddr("attacker");
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.initialFeeBips = 1_000;

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.NotLaunchOwner.selector, poolId, attacker));
        hook.configureLaunch(key, cfg);

        // untouched
        assertEq(hook.getLaunch(poolId).initialFeeBips, INITIAL_FEE);
    }

    function test_configure_ownerMayUpdateBeforeStartTime() public {
        vm.warp(START_TIME - 1);

        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.initialFeeBips = 200_000;
        cfg.finalFeeBips = 1_000;
        cfg.maxBuyPerTx = 12345;
        hook.configureLaunch(key, cfg);

        LaunchGuardHook.Launch memory l = hook.getLaunch(poolId);
        assertEq(l.initialFeeBips, 200_000);
        assertEq(l.finalFeeBips, 1_000);
        assertEq(l.maxBuyPerTx, 12345);
        assertEq(l.owner, address(this)); // ownership unchanged by an update
    }

    function test_configure_frozenAtExactStartTime() public {
        vm.warp(START_TIME);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchGuardHook.LaunchAlreadyStarted.selector, poolId, uint256(START_TIME))
        );
        hook.configureLaunch(key, _defaultConfig());
    }

    function test_configure_frozenAfterStartTime() public {
        vm.warp(START_TIME + 1);
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.startTime = uint40(START_TIME + 500);
        cfg.initialFeeBips = 500_000; // the rug attempt: spike the fee mid-launch

        vm.expectRevert(
            abi.encodeWithSelector(LaunchGuardHook.LaunchAlreadyStarted.selector, poolId, uint256(START_TIME))
        );
        hook.configureLaunch(key, cfg);
    }

    function test_configure_frozenEvenLongAfterTheDecayWindow() public {
        vm.warp(START_TIME + DECAY_SECONDS + 1_000_000);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchGuardHook.LaunchAlreadyStarted.selector, poolId, uint256(START_TIME))
        );
        hook.configureLaunch(key, _defaultConfig());
    }

    function test_configure_rejectsStartTimeInThePast() public {
        vm.warp(1000);
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.startTime = 999;
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.InvalidStartTime.selector, uint256(999), uint256(1000)));
        hook.configureLaunch(k, cfg);
    }

    function test_configure_acceptsStartTimeEqualToNow() public {
        vm.warp(1000);
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.startTime = 1000;
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60);
        hook.configureLaunch(k, cfg);
        assertEq(hook.getLaunch(k.toId()).startTime, 1000);

        // ...and it is immediately frozen, because the launch is already open.
        vm.expectRevert(
            abi.encodeWithSelector(LaunchGuardHook.LaunchAlreadyStarted.selector, k.toId(), uint256(1000))
        );
        hook.configureLaunch(k, cfg);
    }

    function test_configure_rejectsStartTimeTooFarAhead() public {
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.startTime = uint40(block.timestamp + hook.MAX_START_DELAY_SECONDS() + 1);
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchGuardHook.InvalidStartTime.selector, uint256(cfg.startTime), block.timestamp)
        );
        hook.configureLaunch(k, cfg);
    }

    function test_configure_rejectsZeroDecaySeconds() public {
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.decaySeconds = 0;
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.InvalidDecaySeconds.selector, uint32(0)));
        hook.configureLaunch(k, cfg);
    }

    function test_configure_rejectsOversizedDecayWindow() public {
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.decaySeconds = hook.MAX_DECAY_SECONDS() + 1;
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.InvalidDecaySeconds.selector, cfg.decaySeconds));
        hook.configureLaunch(k, cfg);
    }

    function test_configure_rejectsRisingFeeSchedule() public {
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.initialFeeBips = 1_000;
        cfg.finalFeeBips = 2_000;
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchGuardHook.InvalidFeeSchedule.selector, uint24(1_000), uint24(2_000))
        );
        hook.configureLaunch(k, cfg);
    }

    function test_configure_rejectsInitialFeeAboveCap() public {
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.initialFeeBips = hook.MAX_INITIAL_FEE() + 1;
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchGuardHook.InvalidFeeSchedule.selector, cfg.initialFeeBips, FINAL_FEE)
        );
        hook.configureLaunch(k, cfg);
    }

    function test_configure_rejectsFinalFeeAboveCap() public {
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.finalFeeBips = hook.MAX_FINAL_FEE() + 1;
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchGuardHook.InvalidFeeSchedule.selector, INITIAL_FEE, cfg.finalFeeBips)
        );
        hook.configureLaunch(k, cfg);
    }

    /// @dev RESIDUAL RISK, DELIBERATELY CAPTURED. Ownership is established by first-claim, so a
    /// front-runner can squat an unclaimed pool id and make that exact PoolKey unusable. The blast
    /// radius is bounded - the squatter gets no funds, and the launcher can move to another
    /// tickSpacing (a different pool id) or claim atomically in the same transaction that
    /// initializes and seeds the pool - but the race itself cannot be removed at this layer,
    /// because a PoolKey carries no field that could bind it to an intended owner. (Core rejects
    /// non-zero bits above `OFFSET_MOST_SIGNIFICANT_UNUSED_BITS` in `parameters`, so the owner
    /// cannot be smuggled into the key either.)
    function test_risk_unclaimedPoolIdCanBeSquattedByAFrontRunner() public {
        PoolKey memory victimKey = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60);
        PoolId victimId = victimKey.toId();

        address squatter = makeAddr("squatter");
        LaunchGuardHook.LaunchConfig memory hostile = _defaultConfig();
        hostile.startTime = uint40(block.timestamp + hook.MAX_START_DELAY_SECONDS()); // never opens in practice
        vm.prank(squatter);
        hook.configureLaunch(victimKey, hostile);

        // The real launcher is now locked out of this exact PoolKey.
        address launcher = makeAddr("launcher");
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.NotLaunchOwner.selector, victimId, launcher));
        hook.configureLaunch(victimKey, _defaultConfig());

        // ...but only that key. A different tickSpacing is a different pool id, still free.
        PoolKey memory escapeKey = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 61);
        vm.prank(launcher);
        hook.configureLaunch(escapeKey, _defaultConfig());
        assertEq(hook.launchOwner(escapeKey.toId()), launcher);

        // And the squatter never gains custody of anything: the pool was never initialized and
        // the hook holds no funds at any point.
        assertEq(MockERC20(Currency.unwrap(currency0)).balanceOf(address(hook)), 0);
        assertEq(MockERC20(Currency.unwrap(currency1)).balanceOf(address(hook)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                              INITIALIZE
    //////////////////////////////////////////////////////////////*/

    function test_initialize_revertsWhenPoolIsNotConfigured() public {
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60);
        _expectHookRevert(
            address(hook),
            ICLHooks.beforeInitialize.selector,
            abi.encodeWithSelector(LaunchGuardHook.LaunchNotConfigured.selector, k.toId())
        );
        poolManager.initialize(k, SQRT_RATIO_1_1);
    }

    /// @dev A claimed pool with no fee split cannot be created: its fees would land in a pot with
    /// no split, and the split can be written once only, before trading.
    function test_initialize_revertsWhenThePoolHasNoFeeSplit() public {
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60);
        hook.configureLaunch(k, _defaultConfig());
        _expectHookRevert(
            address(hook),
            ICLHooks.beforeInitialize.selector,
            abi.encodeWithSelector(LaunchTaxModule.FeeSplitNotConfigured.selector, k.toId())
        );
        poolManager.initialize(k, SQRT_RATIO_1_1);

        hook.configureFeeSplit(k, _defaultFeeSplit());
        poolManager.initialize(k, SQRT_RATIO_1_1);
    }

    /// @dev On a static-fee pool `CLHooks.beforeSwap` silently DISCARDS the LP fee the hook returns.
    /// The guard returns an LP fee of ZERO, so on a static-fee pool core would charge the pool's
    /// own static fee ON TOP of the guard's take, in the input currency: a sell would pay part of
    /// its cost in launch token again. The hook refuses to let such a pool exist.
    function test_initialize_revertsOnStaticFeePool() public {
        LaunchGuardHook openHook = new LaunchGuardHook(poolManager, ILaunchTokenOrigin(address(0)), TAX_PROTOCOL, 0);
        PoolKey memory k = _key(openHook, 3000, 60);

        // Prove the static-fee pool is otherwise perfectly valid to core: same bitmap, same shape.
        assertEq(openHook.getHooksRegistrationBitmap(), hook.getHooksRegistrationBitmap());

        _expectHookRevert(
            address(openHook),
            ICLHooks.beforeInitialize.selector,
            abi.encodeWithSelector(LaunchGuardHook.PoolMustUseDynamicFee.selector, uint24(3000))
        );
        poolManager.initialize(k, SQRT_RATIO_1_1);
    }

    /*//////////////////////////////////////////////////////////////
                            THE LAUNCH GATE
    //////////////////////////////////////////////////////////////*/

    function test_swap_revertsBeforeStartTime() public {
        vm.warp(START_TIME - 1);
        _expectHookRevert(
            address(hook),
            ICLHooks.beforeSwap.selector,
            abi.encodeWithSelector(
                LaunchGuardHook.TradingNotOpen.selector, poolId, uint256(START_TIME), uint256(START_TIME - 1)
            )
        );
        _swap(key, true, SWAP_AMOUNT);
    }

    function test_swap_revertsBeforeStartTime_inBothDirections() public {
        vm.warp(START_TIME - 1);
        _expectHookRevert(
            address(hook),
            ICLHooks.beforeSwap.selector,
            abi.encodeWithSelector(
                LaunchGuardHook.TradingNotOpen.selector, poolId, uint256(START_TIME), uint256(START_TIME - 1)
            )
        );
        _swap(key, false, SWAP_AMOUNT);
    }

    function test_swap_succeedsAtExactStartTime() public {
        vm.warp(START_TIME);
        Charge memory c = _assertCharged(true, SWAP_AMOUNT, INITIAL_FEE);
        assertEq(c.fee, 3_000, "30% of the 10_000 wei of quote the buyer sent");
        assertEq(c.traderQuote, SWAP_AMOUNT);
    }

    function test_launchStarted_emittedOnceOnFirstSwap() public {
        vm.warp(START_TIME);

        vm.expectEmit(true, false, false, true, address(hook));
        emit LaunchStarted(poolId, START_TIME);
        _swap(key, true, SWAP_AMOUNT);
        assertTrue(hook.getLaunch(poolId).launched);

        // A second swap must NOT re-emit.
        vm.warp(START_TIME + 5);
        vm.recordLogs();
        _swap(key, true, SWAP_AMOUNT);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook)) {
                assertTrue(logs[i].topics[0] != LaunchStarted.selector, "LaunchStarted re-emitted");
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                          FEE DECAY BOUNDARIES
    //////////////////////////////////////////////////////////////*/

    function test_decay_second0IsExactlyInitialFee() public {
        vm.warp(START_TIME);
        assertEq(hook.currentFee(poolId), INITIAL_FEE);
        Charge memory c = _assertCharged(true, SWAP_AMOUNT, INITIAL_FEE);
        assertEq(c.fee, 3_000);
    }

    function test_decay_midWindow() public {
        vm.warp(START_TIME + 50);
        uint24 expected = _expectedFee(50);
        assertEq(expected, 151_500);
        assertEq(hook.currentFee(poolId), expected);
        Charge memory c = _assertCharged(true, SWAP_AMOUNT, expected);
        assertEq(c.fee, 1_515);
    }

    function test_decay_lastSecondOfWindowIsStillTaxed() public {
        // The window is half-open: [startTime, startTime + decaySeconds). The final block inside
        // it must still charge strictly more than the post-launch fee.
        vm.warp(START_TIME + DECAY_SECONDS - 1);
        uint24 expected = _expectedFee(DECAY_SECONDS - 1);
        assertEq(expected, 5_970);
        assertGt(expected, FINAL_FEE);
        assertEq(hook.currentFee(poolId), expected);
        Charge memory c = _assertCharged(true, SWAP_AMOUNT, expected);
        assertEq(c.fee, 59, "floor(10_000 * 0.597%)");
    }

    function test_decay_exactEndOfWindowIsFinalFee() public {
        vm.warp(START_TIME + DECAY_SECONDS);
        assertEq(hook.currentFee(poolId), FINAL_FEE);
        Charge memory c = _assertCharged(true, SWAP_AMOUNT, FINAL_FEE);
        assertEq(c.fee, 30);
    }

    function test_decay_longAfterWindowIsFinalFee() public {
        vm.warp(START_TIME + DECAY_SECONDS + 5_000_000);
        assertEq(hook.currentFee(poolId), FINAL_FEE);
        Charge memory c = _assertCharged(true, SWAP_AMOUNT, FINAL_FEE);
        assertEq(c.fee, 30, "the final fee is permanent");
    }

    /// @dev A sell pays the same schedule, and pays it in the QUOTE it receives: that is the whole
    /// point of the change. Under the LP fee it paid in the launch token it sent.
    function test_decay_appliesToSellsToo() public {
        vm.warp(START_TIME);
        Charge memory c = _assertCharged(false, SWAP_AMOUNT, INITIAL_FEE);
        assertEq(c.traderToken, SWAP_AMOUNT, "every launch token the seller sent reached the pool");
        assertEq(c.poolToken, SWAP_AMOUNT);
        assertGt(c.poolQuote, 0);
        assertEq(c.base, uint256(c.poolQuote), "the base is the quote the pool paid out");
        assertEq(c.fee, uint256(c.poolQuote) * 3 / 10);
    }

    /// @dev The schedule on every shape of swap, at the opening rate: the two shapes charged in
    /// `beforeSwap` (on the amount named) and the two charged in `afterSwap` (on the pool's).
    function test_decay_everyShapeIsChargedTheSchedule() public {
        vm.warp(START_TIME);
        Charge memory c = _assertCharged(true, -1 ether, INITIAL_FEE); // buy, exact input
        assertEq(c.fee, 0.3 ether);
        assertEq(c.poolQuote, -0.7 ether, "the pool is handed the amount less the fee");
        c = _assertCharged(false, -1 ether, INITIAL_FEE); // sell, exact input
        assertEq(c.base, uint256(c.poolQuote));
        c = _assertCharged(true, 1 ether, INITIAL_FEE); // buy, exact output
        assertEq(c.traderToken, 1 ether);
        assertEq(c.base, uint256(-c.poolQuote));
        c = _assertCharged(false, 1 ether, INITIAL_FEE); // sell, exact output
        assertEq(c.fee, 0.3 ether);
        assertEq(c.poolQuote, 1.3 ether, "the pool pays out the amount plus the fee");
        assertEq(c.traderQuote, 1 ether);
    }

    /// @dev Ties the fee to real economics, not just to a counter: on a ~1:1 pool with no LP fee
    /// the buyer receives the launch token that the quote LEFT AFTER THE FEE buys, to the wei.
    function test_decay_isEconomicallyRealNotJustReported() public {
        vm.warp(START_TIME + 50);
        uint256 expectedFee = _expectedFee(50);
        uint256 amountIn = uint256(-SWAP_AMOUNT);
        uint256 fee = amountIn * expectedFee / 1e6;
        BalanceDelta delta = _swap(key, true, SWAP_AMOUNT);

        assertEq(delta.amount0(), SWAP_AMOUNT, "the buyer pays what it named, fee included");
        assertApproxEqAbs(uint256(int256(delta.amount1())), amountIn - fee, 1);
        assertEq(hook.pendingFee(poolId, currency0), fee);
        assertEq(vault.balanceOf(address(hook), currency0), fee);
    }

    function test_decay_feeIsNeverWrittenToPoolStorage() public {
        vm.warp(START_TIME);
        _swap(key, true, SWAP_AMOUNT);
        (,,, uint24 storedLpFee) = poolManager.getSlot0(poolId);
        // Dynamic-fee pools store 0 and the hook never calls updateDynamicLPFee. The guard's
        // override is zero as well, on every path, so the pool's LP fee is zero by both routes.
        assertEq(storedLpFee, 0);
    }

    /// @dev What `beforeSwap` hands core as the LP fee, read from the callback itself: zero with
    /// the override flag, at the opening, mid-decay and after it. (An exact-input sell is charged
    /// in `afterSwap`, so its `beforeSwap` makes no vault call and can be called outside a lock.)
    /// MUTATION-CHECKED (c): returning the decayed fee as the override fails here and in every
    /// `_assertCharged`.
    function test_beforeSwap_returnsAZeroLpFeeOverrideOnEveryPath() public {
        uint40[4] memory at = [START_TIME, START_TIME + 50, START_TIME + DECAY_SECONDS, START_TIME + 1 days];
        for (uint256 i; i < at.length; ++i) {
            vm.warp(at[i]);
            vm.prank(address(poolManager));
            (bytes4 selector, BeforeSwapDelta delta, uint24 lpFee) =
                hook.beforeSwap(address(router), key, _swapParams(false, SWAP_AMOUNT), ZERO_BYTES);
            assertEq(selector, ICLHooks.beforeSwap.selector);
            assertEq(lpFee, LPFeeLibrary.OVERRIDE_FEE_FLAG, "the override flag alone: an LP fee of zero");
            assertEq(BeforeSwapDelta.unwrap(delta), 0, "nothing is taken before a swap charged after it");
        }
    }

    function test_feeAt_revertsForUnconfiguredPool() public {
        PoolId unknown = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60).toId();
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.LaunchNotConfigured.selector, unknown));
        hook.feeAt(unknown, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                            DISABLED LAUNCH
    //////////////////////////////////////////////////////////////*/

    function test_disabled_appliesFinalFeeAndNoGate() public {
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.enabled = false;
        hook.configureLaunch(key, cfg);

        // Before startTime, and yet tradeable: the gate is part of the protection, not the pool.
        vm.warp(START_TIME - 1);
        assertEq(hook.currentFee(poolId), FINAL_FEE);
        _assertCharged(true, SWAP_AMOUNT, FINAL_FEE);
        _assertCharged(false, SWAP_AMOUNT, FINAL_FEE);
        _assertCharged(true, 10_000, FINAL_FEE);
        _assertCharged(false, 10_000, FINAL_FEE);

        // And it never decays from anything: inside what would have been the window it is the same.
        vm.warp(START_TIME + 10);
        _assertCharged(true, SWAP_AMOUNT, FINAL_FEE);
    }

    function test_disabled_stillChargesSoThePoolIsNeverFeeFree() public {
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.enabled = false;
        cfg.finalFeeBips = 500;
        hook.configureLaunch(key, cfg);

        vm.warp(START_TIME - 1);
        Charge memory c = _assertCharged(true, SWAP_AMOUNT, 500);
        assertEq(c.fee, 5, "0.05% of 10_000");
    }

    /// @dev A disabled schedule with a final fee of zero is a pool that charges nothing at all:
    /// no LP fee and no take. The owner chose it and a trader can read it before trading.
    function test_disabled_aZeroFinalFeeChargesNothing() public {
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.enabled = false;
        cfg.initialFeeBips = 0;
        cfg.finalFeeBips = 0;
        hook.configureLaunch(key, cfg);
        Charge memory c = _assertCharged(true, -1 ether, 0);
        assertEq(c.fee, 0);
        assertEq(c.poolQuote, -1 ether);
        assertEq(hook.grossTaken(currency0), 0);
    }

    /*//////////////////////////////////////////////////////////////
                       PER-TRANSACTION BUY CAP

        NOTE: this is a per-TRANSACTION cap and nothing more. See
        `test_maxBuy_doesNotStopSplittingAcrossTransactions`.
    //////////////////////////////////////////////////////////////*/

    function _configureWithCap(uint128 cap) internal {
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.maxBuyPerTx = cap;
        hook.configureLaunch(key, cfg);
    }

    function test_maxBuy_allowsBuyAtExactlyTheCap() public {
        _configureWithCap(5_000);
        vm.warp(START_TIME);
        Charge memory c = _assertCharged(true, -5_000, INITIAL_FEE); // exactly at the cap
        assertEq(c.poolQuote, -3_500, "of which 3_500 reached the pool");
    }

    /// @dev THE CAP IS ON WHAT THE TRADER SENDS, before the guard's take. A buy of 5_001 hands the
    /// pool only 3_501 at the opening fee, well under the cap of 5_000, and is refused all the
    /// same; so is every larger buy whose net would still fit. The amount reported is the gross.
    /// MUTATION-CHECKED (e): checking the cap against the net amount lets all three through.
    function test_maxBuy_isCheckedOnTheGrossAmountBeforeTheTake() public {
        _configureWithCap(5_000);
        vm.warp(START_TIME);
        uint256[3] memory gross = [uint256(5_001), 6_000, 7_142]; // net of 30%: 3_501, 4_200, 5_000
        for (uint256 i; i < gross.length; ++i) {
            assertLe(gross[i] - gross[i] * INITIAL_FEE / 1_000_000, 5_000, "the net would have fitted");
            _expectHookRevert(
                address(hook),
                ICLHooks.beforeSwap.selector,
                abi.encodeWithSelector(LaunchGuardHook.BuyExceedsMaxPerTx.selector, gross[i], uint128(5_000))
            );
            _swap(key, true, -int256(gross[i]));
        }
        assertEq(hook.grossTaken(currency0), 0, "a refused buy is charged nothing");
    }

    /// @dev The same with a creator tax on top: at both caps the pool receives 40% of a buy, and
    /// the cap still counts all of it.
    function test_maxBuy_isCheckedOnTheGrossAmountWithATaxLive() public {
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.maxBuyPerTx = 5_000;
        cfg.initialFeeBips = hook.MAX_INITIAL_FEE();
        hook.configureLaunch(key, cfg);
        hook.configureTax(
            key,
            LaunchTaxModule.TaxConfig({
                buyBps: 1_000,
                sellBps: 1_000,
                expiresAt: START_TIME + 1 days,
                creator: FEE_CREATOR,
                integrator: address(0),
                creatorBps: 9_000,
                protocolBps: 1_000,
                integratorBps: 0
            })
        );
        vm.warp(START_TIME);

        _expectHookRevert(
            address(hook),
            ICLHooks.beforeSwap.selector,
            abi.encodeWithSelector(LaunchGuardHook.BuyExceedsMaxPerTx.selector, uint256(5_001), uint128(5_000))
        );
        _swap(key, true, -5_001); // 2_001 would have reached the pool

        Charge memory c = _swapAndReadCharge(true, -5_000);
        assertEq(c.lpFee, 0);
        assertEq(c.fee, 2_500);
        assertEq(hook.pendingTax(poolId, currency0), 500);
        assertEq(c.poolQuote, -2_000);
        assertEq(c.traderQuote, -5_000);
        assertEq(c.tokenTaken, 0);
    }

    function test_maxBuy_rejectsBuyOneWeiOverTheCap() public {
        _configureWithCap(5_000);
        vm.warp(START_TIME);
        _expectHookRevert(
            address(hook),
            ICLHooks.beforeSwap.selector,
            abi.encodeWithSelector(LaunchGuardHook.BuyExceedsMaxPerTx.selector, uint256(5_001), uint128(5_000))
        );
        _swap(key, true, -5_001);
    }

    function test_maxBuy_doesNotConstrainSells() public {
        _configureWithCap(5_000);
        vm.warp(START_TIME);
        // currency1 is the launch token, so oneForZero is a SELL and is uncapped by design.
        _assertCharged(false, -50_000, INITIAL_FEE);
        // However large, and whichever side of the sell is named.
        _assertCharged(false, -1 ether, INITIAL_FEE);
        _assertCharged(false, 1 ether, INITIAL_FEE);
    }

    function test_maxBuy_directionFollowsLaunchTokenSide() public {
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.maxBuyPerTx = 5_000;
        cfg.launchTokenIsCurrency0 = true; // now oneForZero is the buy
        hook.configureLaunch(key, cfg);
        vm.warp(START_TIME);

        _swap(key, true, -50_000); // zeroForOne is now a sell: uncapped

        _expectHookRevert(
            address(hook),
            ICLHooks.beforeSwap.selector,
            abi.encodeWithSelector(LaunchGuardHook.BuyExceedsMaxPerTx.selector, uint256(5_001), uint128(5_000))
        );
        _swap(key, false, -5_001);
    }

    function test_maxBuy_blocksExactOutputBuysWhileCapIsLive() public {
        _configureWithCap(5_000);
        vm.warp(START_TIME);
        _expectHookRevert(
            address(hook),
            ICLHooks.beforeSwap.selector,
            abi.encodeWithSelector(LaunchGuardHook.ExactOutputBuyBlockedDuringLaunch.selector)
        );
        _swap(key, true, 1_000); // positive == exact output; input amount is unknowable here
    }

    function test_maxBuy_exactOutputSellsAreUnaffected() public {
        _configureWithCap(5_000);
        vm.warp(START_TIME);
        _assertCharged(false, 1_000, INITIAL_FEE);
        _assertCharged(false, 50_000, INITIAL_FEE); // ten times the cap, in quote: a sell is never capped
    }

    /// @dev The exact-output buy is refused for the whole window, to its last second, whatever its
    /// size: one wei of launch token is refused like any other.
    function test_maxBuy_blocksExactOutputBuysToTheLastSecondOfTheWindow() public {
        _configureWithCap(5_000);
        vm.warp(START_TIME + DECAY_SECONDS - 1);
        _expectHookRevert(
            address(hook),
            ICLHooks.beforeSwap.selector,
            abi.encodeWithSelector(LaunchGuardHook.ExactOutputBuyBlockedDuringLaunch.selector)
        );
        _swap(key, true, 1);
        _expectHookRevert(
            address(hook),
            ICLHooks.beforeSwap.selector,
            abi.encodeWithSelector(LaunchGuardHook.BuyExceedsMaxPerTx.selector, uint256(5_001), uint128(5_000))
        );
        _swap(key, true, -5_001);
    }

    function test_maxBuy_liftsAfterTheDecayWindow() public {
        _configureWithCap(5_000);
        vm.warp(START_TIME + DECAY_SECONDS);
        _assertCharged(true, -500_000, FINAL_FEE); // far above the cap, but the window has closed
        _assertCharged(true, 1_000, FINAL_FEE); // exact-output buys are permitted again too
    }

    function test_maxBuy_zeroMeansDisabled() public {
        _configureWithCap(0);
        vm.warp(START_TIME);
        _assertCharged(true, -500_000, INITIAL_FEE);
        _assertCharged(true, 1_000, INITIAL_FEE);
    }

    /// @dev Documents the limit of the cap: it is per-transaction, so an entity that wants more
    /// than the cap simply sends more transactions. This is not a bug to be fixed at this layer.
    function test_maxBuy_doesNotStopSplittingAcrossTransactions() public {
        _configureWithCap(5_000);
        vm.warp(START_TIME);

        // Ten separate buys in the SAME block, each at the cap, from ten different addresses.
        // Total acquired is 10x the "max buy". The hook cannot tell them apart and does not try.
        for (uint256 i = 0; i < 10; i++) {
            address buyer = address(uint160(0xB0B0000 + i));
            MockERC20(Currency.unwrap(currency0)).mint(buyer, 1 ether);
            vm.startPrank(buyer);
            MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
            _swap(key, true, -5_000);
            vm.stopPrank();
        }
        assertEq(block.timestamp, START_TIME); // all in one block
    }

    /*//////////////////////////////////////////////////////////////
                          onlyPoolManager GUARD
    //////////////////////////////////////////////////////////////*/

    function test_onlyPoolManager_beforeSwapIsUnreachableDirectly() public {
        vm.warp(START_TIME);
        vm.expectRevert(BaseCLHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, _swapParams(true, SWAP_AMOUNT), ZERO_BYTES);
    }

    function test_onlyPoolManager_beforeInitializeIsUnreachableDirectly() public {
        vm.expectRevert(BaseCLHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_RATIO_1_1);
    }

    function test_onlyPoolManager_alsoBlocksTheLaunchOwner() public {
        // The gate is on the caller, not on privilege: even the launch owner cannot fake a swap
        // and flip the `launched` flag or drive the hook's accounting.
        vm.warp(START_TIME);
        assertEq(hook.launchOwner(poolId), address(this));
        vm.expectRevert(BaseCLHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, _swapParams(true, SWAP_AMOUNT), ZERO_BYTES);
        assertFalse(hook.getLaunch(poolId).launched);
    }

    function test_onlyPoolManager_unimplementedCallbacksStillRevertForOutsiders() public {
        vm.expectRevert(BaseCLHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, SQRT_RATIO_1_1, 0);
    }

    /// @dev `afterSwap` takes fees too now. Nobody but the pool manager can make it take one.
    function test_onlyPoolManager_afterSwapIsUnreachableDirectly() public {
        vm.warp(START_TIME);
        vm.expectRevert(BaseCLHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, _swapParams(false, SWAP_AMOUNT), BalanceDelta.wrap(0), ZERO_BYTES);
        vm.prank(hook.launchOwner(poolId));
        vm.expectRevert(BaseCLHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, _swapParams(true, 1 ether), BalanceDelta.wrap(0), ZERO_BYTES);
        assertEq(hook.grossTaken(currency0) + hook.grossTaken(currency1), 0);
    }

    /*//////////////////////////////////////////////////////////////
        THE `sender` CONSTRAINT — CAPTURED IN THE SUITE ON PURPOSE

        `CLHooks.beforeSwap` calls the hook with `msg.sender` of `CLPoolManager.swap`, which is
        whoever locked the Vault: the ROUTER. It is never the buyer. Any per-wallet rule keyed on
        this argument would be consumed by the first buyer on everyone's behalf, which is why this
        hook taxes time instead of identity.
    //////////////////////////////////////////////////////////////*/

    function test_sender_isTheLockerNotTheBuyer() public {
        SenderRecordingLaunchGuardHook spy = new SenderRecordingLaunchGuardHook(poolManager);
        PoolKey memory k = _key(spy, LPFeeLibrary.DYNAMIC_FEE_FLAG, 1);
        spy.configureLaunch(k, _defaultConfig());
        spy.configureFeeSplit(k, _defaultFeeSplit());
        poolManager.initialize(k, SQRT_RATIO_1_1);

        IERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        router.modifyPosition(
            k,
            ICLPoolManager.ModifyLiquidityParams({tickLower: -10, tickUpper: 10, liquidityDelta: 10_000 ether, salt: 0}),
            ZERO_BYTES
        );

        vm.warp(START_TIME);

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        MockERC20(Currency.unwrap(currency0)).mint(alice, 1 ether);
        MockERC20(Currency.unwrap(currency0)).mint(bob, 1 ether);

        vm.startPrank(alice);
        MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        _swap(k, true, SWAP_AMOUNT);
        vm.stopPrank();
        address senderSeenForAlice = spy.lastSwapSender();

        vm.startPrank(bob);
        MockERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        _swap(k, true, SWAP_AMOUNT);
        vm.stopPrank();
        address senderSeenForBob = spy.lastSwapSender();

        assertEq(spy.swapCount(), 2);

        // The hook saw the router both times, never the buyer.
        assertEq(senderSeenForAlice, address(router));
        assertEq(senderSeenForBob, address(router));
        assertEq(senderSeenForAlice, senderSeenForBob);
        assertTrue(senderSeenForAlice != alice);
        assertTrue(senderSeenForBob != bob);
    }

    /// @dev Second half of the same constraint: a caller who bypasses the router and locks the
    /// Vault himself presents whatever `sender` he likes (his own contract) and whatever
    /// `hookData` he likes. Neither can be used as an identity.
    function test_sender_aSecondRouterPresentsADifferentSenderEntirely() public {
        SenderRecordingLaunchGuardHook spy = new SenderRecordingLaunchGuardHook(poolManager);
        PoolKey memory k = _key(spy, LPFeeLibrary.DYNAMIC_FEE_FLAG, 1);
        spy.configureLaunch(k, _defaultConfig());
        spy.configureFeeSplit(k, _defaultFeeSplit());
        poolManager.initialize(k, SQRT_RATIO_1_1);

        IERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        router.modifyPosition(
            k,
            ICLPoolManager.ModifyLiquidityParams({tickLower: -10, tickUpper: 10, liquidityDelta: 10_000 ether, salt: 0}),
            ZERO_BYTES
        );

        CLPoolManagerRouter rogue = new CLPoolManagerRouter(vault, poolManager);
        IERC20(Currency.unwrap(currency0)).approve(address(rogue), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(rogue), type(uint256).max);

        vm.warp(START_TIME);

        _swap(k, true, SWAP_AMOUNT);
        assertEq(spy.lastSwapSender(), address(router));

        rogue.swap(
            k,
            _swapParams(true, SWAP_AMOUNT),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            // arbitrary attacker-chosen hookData naming a victim: unverifiable, hence unused
            abi.encode(makeAddr("someVictim"))
        );
        assertEq(spy.lastSwapSender(), address(rogue));
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev Reconfigures the pool's schedule and returns the (frozen) start time. Safe to call
    /// repeatedly because the fuzz tests never roll past `START_TIME`.
    function _fuzzConfigure(uint24 initialFee, uint24 finalFee, uint32 decaySeconds)
        internal
        returns (uint24, uint24, uint32)
    {
        finalFee = uint24(bound(finalFee, 0, hook.MAX_FINAL_FEE()));
        initialFee = uint24(bound(initialFee, finalFee, hook.MAX_INITIAL_FEE()));
        decaySeconds = uint32(bound(decaySeconds, hook.MIN_DECAY_SECONDS(), hook.MAX_DECAY_SECONDS()));

        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.initialFeeBips = initialFee;
        cfg.finalFeeBips = finalFee;
        cfg.decaySeconds = decaySeconds;
        hook.configureLaunch(key, cfg);

        return (initialFee, finalFee, decaySeconds);
    }

    function testFuzz_decay_alwaysInRangeAndMonotonicNonIncreasing(
        uint24 initialFee,
        uint24 finalFee,
        uint32 decaySeconds
    ) public {
        (initialFee, finalFee, decaySeconds) = _fuzzConfigure(initialFee, finalFee, decaySeconds);

        // Boundary anchors.
        assertEq(hook.feeAt(poolId, START_TIME), initialFee, "block 0 != initialFee");
        assertEq(hook.feeAt(poolId, uint256(START_TIME) + decaySeconds), finalFee, "end of window != finalFee");
        assertEq(hook.feeAt(poolId, uint256(START_TIME) + decaySeconds + 1), finalFee, "after window != finalFee");
        assertEq(
            hook.feeAt(poolId, uint256(START_TIME) + uint256(decaySeconds) * 1000), finalFee, "far future != finalFee"
        );

        // Sweep the window on an ascending ladder of offsets and check range + monotonicity.
        uint24 previous = type(uint24).max;
        for (uint256 i = 0; i <= 34; i++) {
            uint256 offset = i <= 32 ? (uint256(decaySeconds) * i) / 32 : (i == 33 ? decaySeconds : decaySeconds + 1);
            uint24 fee = hook.feeAt(poolId, uint256(START_TIME) + offset);

            assertLe(fee, initialFee, "fee above initialFee");
            assertGe(fee, finalFee, "fee below finalFee");
            // Never exceeds what core will accept for a CL pool.
            assertLe(fee, LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE, "fee above core max");
            assertLe(fee, previous, "fee increased");
            previous = fee;
        }
    }

    function testFuzz_decay_pairwiseMonotonic(
        uint24 initialFee,
        uint24 finalFee,
        uint32 decaySeconds,
        uint32 offsetA,
        uint32 offsetB
    ) public {
        (initialFee, finalFee, decaySeconds) = _fuzzConfigure(initialFee, finalFee, decaySeconds);

        uint256 lo = bound(offsetA, 0, uint256(decaySeconds) * 2);
        uint256 hi = bound(offsetB, lo, uint256(decaySeconds) * 2 + 1);

        uint24 feeLo = hook.feeAt(poolId, uint256(START_TIME) + lo);
        uint24 feeHi = hook.feeAt(poolId, uint256(START_TIME) + hi);

        assertGe(feeLo, feeHi, "later block charged more");
        assertLe(feeLo, initialFee);
        assertGe(feeHi, finalFee);
    }

    /// @dev Whatever schedule the hook accepts, at whatever moment, in whatever direction and
    /// whichever side is named: the guard takes exactly the scheduled share of the swap's quote
    /// amount, in the quote, core applies an LP fee of zero, and the swap never reverts.
    function testFuzz_decay_chargedFeeMatchesSchedule(
        uint24 initialFee,
        uint24 finalFee,
        uint32 decaySeconds,
        uint16 elapsed,
        uint256 amount,
        bool zeroForOne,
        bool exactIn
    ) public {
        decaySeconds = uint32(bound(decaySeconds, hook.MIN_DECAY_SECONDS(), 5_000));
        (initialFee, finalFee, decaySeconds) = _fuzzConfigure(initialFee, finalFee, decaySeconds);
        amount = bound(amount, 1, 1 ether);

        uint256 offset = bound(elapsed, 0, uint256(decaySeconds) + 10);
        vm.warp(uint256(START_TIME) + offset);

        // The schedule, written out here rather than read back from the hook.
        uint24 expected = offset >= decaySeconds
            ? finalFee
            : uint24(uint256(initialFee) - (uint256(initialFee - finalFee) * offset) / decaySeconds);
        assertEq(hook.currentFee(poolId), expected, "the view disagrees with the schedule");

        Charge memory c = _assertCharged(zeroForOne, exactIn ? -int256(amount) : int256(amount), expected);
        assertLe(c.fee, c.base / 2, "never more than the 50% cap");
    }

    /*//////////////////////////////////////////////////////////////
       THE CLOCK IS block.timestamp NOW, AND ONLY block.timestamp

       The retired hook measured everything in `block.timestamp`, sized through a
       `blockTimeCentis` argument. On Robinhood (Arbitrum Nitro) the EVM's
       `block.timestamp` is Ethereum's ~12 s block while the RPC shows ~0.1 s L2
       blocks, the deployment was built for the wrong one, and every window ran
       ~120x long - a 30-day cap became ~9.9 years. These tests pin the new clock:
       rolling blocks without moving time must change nothing, and moving time
       without rolling blocks must change everything.

       FAILING-FIRST: every `test_CLOCK_*` below fails against the block-numbered
       source, where `vm.roll` opened trading and `vm.warp` did nothing.
    //////////////////////////////////////////////////////////////*/

    function test_CLOCK_modeIsTimestamp() public {
        assertEq(hook.CLOCK_MODE(), "mode=timestamp");
        vm.warp(1_790_000_000);
        assertEq(hook.clock(), 1_790_000_000);
    }

    function test_CLOCK_blocksAloneNeverOpenTrading() public {
        // A hundred million blocks later, but not one second: the gate must still hold.
        vm.roll(block.number + 100_000_000);
        assertLt(block.timestamp, START_TIME);
        _expectHookRevert(
            address(hook),
            ICLHooks.beforeSwap.selector,
            abi.encodeWithSelector(LaunchGuardHook.TradingNotOpen.selector, poolId, uint256(START_TIME), block.timestamp)
        );
        _swap(key, true, SWAP_AMOUNT);
    }

    function test_CLOCK_timeAloneOpensTradingAndDrivesTheDecay() public {
        uint256 blockBefore = block.number;
        vm.warp(START_TIME + DECAY_SECONDS / 2);
        assertEq(block.number, blockBefore, "no block was rolled");
        uint24 expected = INITIAL_FEE - uint24((uint256(INITIAL_FEE - FINAL_FEE) * (DECAY_SECONDS / 2)) / DECAY_SECONDS);
        assertEq(hook.currentFee(poolId), expected);
        _assertCharged(true, SWAP_AMOUNT, expected);
    }

    function test_CLOCK_blocksDoNotAdvanceTheDecay() public {
        vm.warp(START_TIME);
        uint24 atOpen = hook.currentFee(poolId);
        vm.roll(block.number + 50_000_000);
        assertEq(hook.currentFee(poolId), atOpen, "rolling blocks moved the fee");
        assertEq(atOpen, INITIAL_FEE);
        _assertCharged(true, SWAP_AMOUNT, INITIAL_FEE); // and what is charged did not move either
    }

    /*//////////////////////////////////////////////////////////////
       MINIMUM WINDOW - a sequencer skew must not erase the tax for free
    //////////////////////////////////////////////////////////////*/

    /// @dev The numbers the floor is justified by, pinned so a later edit has to argue with them.
    function test_MINWINDOW_floorIsSixtySecondsAndBelowEveryPreset() public view {
        assertEq(hook.MIN_DECAY_SECONDS(), 60);
        // At least 4x the ~15 s resync granularity of the block-number clock it replaces.
        assertGe(uint256(hook.MIN_DECAY_SECONDS()), 4 * 15);
        // Never above the shortest owner-decided preset (Stealth, 120 s).
        assertLe(uint256(hook.MIN_DECAY_SECONDS()), 120);
    }

    /// @dev MUTATION-CHECKED: replacing `cfg.decaySeconds < MIN_DECAY_SECONDS` with `== 0` makes
    /// this fail at 59 s.
    function test_MINWINDOW_rejectsOneSecondBelowTheFloor() public {
        vm.warp(START_TIME - 10);
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.decaySeconds = hook.MIN_DECAY_SECONDS() - 1;
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.InvalidDecaySeconds.selector, uint32(59)));
        hook.configureLaunch(key, cfg);
    }

    function test_MINWINDOW_acceptsExactlyTheFloor() public {
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.decaySeconds = hook.MIN_DECAY_SECONDS();
        hook.configureLaunch(key, cfg);
        assertEq(hook.getLaunch(poolId).decaySeconds, 60);
    }

    /// @dev The floor is not waived for a disabled launch: a later write could re-enable it.
    function test_MINWINDOW_appliesToDisabledLaunchesToo() public {
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.enabled = false;
        cfg.decaySeconds = 1;
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.InvalidDecaySeconds.selector, uint32(1)));
        hook.configureLaunch(key, cfg);
    }

    function testFuzz_MINWINDOW_acceptedIffInsideBounds(uint32 decaySeconds) public {
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.decaySeconds = decaySeconds;
        if (decaySeconds < hook.MIN_DECAY_SECONDS() || decaySeconds > hook.MAX_DECAY_SECONDS()) {
            vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.InvalidDecaySeconds.selector, decaySeconds));
            hook.configureLaunch(key, cfg);
        } else {
            hook.configureLaunch(key, cfg);
            assertEq(hook.getLaunch(poolId).decaySeconds, decaySeconds);
        }
    }

    /// @dev THE RESIDUAL RISK, asserted rather than papered over. A Nitro sequencer may stamp a
    /// block up to one hour ahead of real time. A 120 s window is then over in the first block
    /// after the jump. The floor does not and cannot stop this; the trust assumption is on the
    /// chain operator, as the contract-level CLOCK note says.
    function test_SKEW_aOneHourForwardJumpErasesAShortWindow() public {
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.decaySeconds = 120;
        hook.configureLaunch(key, cfg);
        vm.warp(START_TIME + 1 hours);
        assertEq(hook.currentFee(poolId), FINAL_FEE);
    }

    /// @dev The honest-skew case the floor IS sized for: a 6 s jump on the minimum window leaves
    /// at least 90% of the spread still being charged at the moment of the jump.
    function test_SKEW_aSixSecondJumpOnTheFloorLeavesNinetyPercentOfTheTax() public {
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.decaySeconds = hook.MIN_DECAY_SECONDS();
        hook.configureLaunch(key, cfg);
        vm.warp(START_TIME + 6);
        uint256 remaining = uint256(hook.currentFee(poolId) - FINAL_FEE);
        assertGe(remaining * 10, uint256(INITIAL_FEE - FINAL_FEE) * 9);
    }

    /*//////////////////////////////////////////////////////////////
       THE "NO PERMANENT TAX" ENVELOPE
    //////////////////////////////////////////////////////////////*/

    function test_ENVELOPE_capsSitInsideTheDesignBounds() public view {
        assertEq(uint256(hook.MAX_DECAY_SECONDS()), 30 days);
        assertEq(uint256(hook.MAX_START_DELAY_SECONDS()), 30 days);
        assertGe(uint256(hook.MAX_DECAY_SECONDS()), hook.MIN_LAUNCH_WINDOW_SECONDS(), "a 3-day launch must fit");
        assertLe(
            uint256(hook.MAX_START_DELAY_SECONDS()) + hook.MAX_DECAY_SECONDS(),
            hook.MAX_LAUNCH_WINDOW_SECONDS(),
            "start + decay must end inside 180 days"
        );
    }

    /// @dev The worst a hostile launch owner can configure: the latest start and the longest
    /// decay. Sixty days after that write, the fee is `finalFeeBips` and can never move again.
    function test_ENVELOPE_worstCaseTaxIsGoneWithinSixtyDays() public {
        uint256 t = block.timestamp;
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.startTime = uint40(t + hook.MAX_START_DELAY_SECONDS());
        cfg.decaySeconds = hook.MAX_DECAY_SECONDS();
        hook.configureLaunch(key, cfg);

        vm.warp(t + 60 days - 1);
        assertGt(hook.currentFee(poolId), FINAL_FEE, "still inside the window one second before");
        vm.warp(t + 60 days);
        assertEq(hook.currentFee(poolId), FINAL_FEE);
    }

    function test_ENVELOPE_aThreeDayFairLaunchConfigures() public {
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.decaySeconds = 3 days;
        hook.configureLaunch(key, cfg);
        assertEq(hook.getLaunch(poolId).decaySeconds, 3 days);
    }

    function test_ENVELOPE_startExactlyAtTheCapIsAccepted() public {
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.startTime = uint40(block.timestamp + hook.MAX_START_DELAY_SECONDS());
        hook.configureLaunch(key, cfg);
        assertEq(hook.getLaunch(poolId).startTime, cfg.startTime);
    }

    /*//////////////////////////////////////////////////////////////
       POOL-ID RESERVATION (owner decision 2026-09-14, Kit v2 #4)

       FAILING-FIRST: against the pre-reservation hook, every front-runner
       below claimed the pool and the kit's own claim reverted NotLaunchOwner.
       MUTATION-CHECKED: deleting the two `_requireMayClaim` calls in
       `configureLaunch` turns test_RESERVE_frontRunnerCannotClaimAFactoryTokenPool
       and test_RESERVE_noClaimOnACurrencyWithoutCode red.
    //////////////////////////////////////////////////////////////*/

    address constant KIT = address(0x6B17);
    address constant CREATOR = address(0xC4EA);
    address constant FRONT_RUNNER = address(0xF4A7);

    function _reservingHook() internal returns (LaunchGuardHook rh, MockLaunchTokenOrigin origin, PoolKey memory k) {
        origin = new MockLaunchTokenOrigin();
        rh = new LaunchGuardHook(poolManager, ILaunchTokenOrigin(address(origin)), TAX_PROTOCOL, 0);
        k = _key(rh, LPFeeLibrary.DYNAMIC_FEE_FLAG, 1);
    }

    function test_RESERVE_frontRunnerCannotClaimAFactoryTokenPool() public {
        (LaunchGuardHook rh, MockLaunchTokenOrigin origin, PoolKey memory k) = _reservingHook();
        address token = Currency.unwrap(k.currency1);
        origin.set(token, KIT); // the kit created the launch token

        vm.prank(FRONT_RUNNER);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.LaunchPoolReserved.selector, token, KIT, FRONT_RUNNER));
        rh.configureLaunch(k, _defaultConfig());
        assertEq(rh.launchOwner(k.toId()), address(0), "nobody claimed it");

        // ...and without a claim nobody can initialize it either.
        _expectHookRevert(
            address(rh),
            ICLHooks.beforeInitialize.selector,
            abi.encodeWithSelector(LaunchGuardHook.LaunchNotConfigured.selector, k.toId())
        );
        vm.prank(FRONT_RUNNER);
        poolManager.initialize(k, SQRT_RATIO_1_1);

        // Nor can the front-runner write the fee split of a pool it could not claim.
        vm.prank(FRONT_RUNNER);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.LaunchNotConfigured.selector, k.toId()));
        rh.configureFeeSplit(k, _defaultFeeSplit());

        // The kit path succeeds: claim, split, initialize.
        vm.prank(KIT);
        rh.configureLaunch(k, _defaultConfig());
        assertEq(rh.launchOwner(k.toId()), KIT);
        vm.prank(FRONT_RUNNER);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.NotLaunchOwner.selector, k.toId(), FRONT_RUNNER));
        rh.configureFeeSplit(k, _defaultFeeSplit());
        vm.prank(KIT);
        rh.configureFeeSplit(k, _defaultFeeSplit());
        poolManager.initialize(k, SQRT_RATIO_1_1);
    }

    function test_RESERVE_creatorMayDelegateTheClaimToAKit() public {
        (LaunchGuardHook rh, MockLaunchTokenOrigin origin, PoolKey memory k) = _reservingHook();
        address token = Currency.unwrap(k.currency0);
        origin.set(token, CREATOR);

        vm.prank(KIT);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.LaunchPoolReserved.selector, token, CREATOR, KIT));
        rh.configureLaunch(k, _defaultConfig());

        vm.prank(FRONT_RUNNER);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.NotTokenCreator.selector, token, FRONT_RUNNER));
        rh.setLaunchClaimer(token, FRONT_RUNNER);

        vm.prank(CREATOR);
        rh.setLaunchClaimer(token, KIT);
        assertEq(rh.launchClaimerOf(token), KIT);

        vm.prank(FRONT_RUNNER);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.LaunchPoolReserved.selector, token, CREATOR, FRONT_RUNNER));
        rh.configureLaunch(k, _defaultConfig());

        vm.prank(KIT);
        rh.configureLaunch(k, _defaultConfig());
        assertEq(rh.launchOwner(k.toId()), KIT);
    }

    function test_RESERVE_creatorItselfMayClaim() public {
        (LaunchGuardHook rh, MockLaunchTokenOrigin origin, PoolKey memory k) = _reservingHook();
        origin.set(Currency.unwrap(k.currency1), CREATOR);
        vm.prank(CREATOR);
        rh.configureLaunch(k, _defaultConfig());
        assertEq(rh.launchOwner(k.toId()), CREATOR);
    }

    /// @dev Rule 1: a token that does not exist YET cannot have its pool squatted.
    function test_RESERVE_noClaimOnACurrencyWithoutCode() public {
        (LaunchGuardHook rh,, PoolKey memory k) = _reservingHook();
        address notYetDeployed = address(uint160(0xDEAD0001));
        k.currency1 = Currency.wrap(notYetDeployed);
        vm.prank(FRONT_RUNNER);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.CurrencyHasNoCode.selector, notYetDeployed));
        rh.configureLaunch(k, _defaultConfig());
    }

    /// @dev Non-factory tokens: first claim, exactly as before - including on the hook with no factory.
    function test_RESERVE_nonFactoryPoolsAreUnaffected() public {
        (LaunchGuardHook rh,, PoolKey memory k) = _reservingHook();
        vm.prank(FRONT_RUNNER);
        rh.configureLaunch(k, _defaultConfig());
        assertEq(rh.launchOwner(k.toId()), FRONT_RUNNER, "first claim, as before");

        LaunchGuardHook plain = new LaunchGuardHook(poolManager, ILaunchTokenOrigin(address(0)), TAX_PROTOCOL, 0);
        PoolKey memory pk = _key(plain, LPFeeLibrary.DYNAMIC_FEE_FLAG, 1);
        vm.prank(FRONT_RUNNER);
        plain.configureLaunch(pk, _defaultConfig());
        assertEq(plain.launchOwner(pk.toId()), FRONT_RUNNER);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.NotTokenCreator.selector, address(1), address(this)));
        plain.setLaunchClaimer(address(1), KIT);
    }

    /// @dev The native asset is never "a currency without code".
    function test_RESERVE_nativeQuoteIsAllowed() public {
        (LaunchGuardHook rh,, PoolKey memory k) = _reservingHook();
        k.currency0 = Currency.wrap(address(0));
        rh.configureLaunch(k, _defaultConfig());
        assertEq(rh.launchOwner(k.toId()), address(this));
    }

    /*//////////////////////////////////////////////////////////////
          FIX (review 2026-09-18): A DISABLED LAUNCH FREEZES ON ITS FIRST SWAP

        `enabled == false` has no trading gate, so the pool trades before
        `startTime`, while the old freeze keyed on `startTime` alone. The
        owner could therefore let the public buy into an open pool and then
        close it (`enabled = true`, `startTime` 30 days out, repeatable) or
        impose the 50% opening fee on everyone's exit. Now the first swap
        freezes the configuration whatever `startTime` says.
    //////////////////////////////////////////////////////////////*/

    function test_FIX_disabledLaunchFreezesOnItsFirstSwap() public {
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.enabled = false;
        hook.configureLaunch(key, cfg);

        // Trades before `startTime`, and the first trade is recorded.
        vm.warp(START_TIME - 50);
        vm.expectEmit(true, false, false, true, address(hook));
        emit LaunchStarted(poolId, START_TIME - 50);
        _swap(key, true, SWAP_AMOUNT);
        assertTrue(hook.getLaunch(poolId).launched, "first swap recorded");

        // The rug: re-enable with the maximum fee and an open 30 days out. Refused.
        LaunchGuardHook.LaunchConfig memory rug = _defaultConfig();
        rug.enabled = true;
        rug.initialFeeBips = hook.MAX_INITIAL_FEE();
        rug.finalFeeBips = hook.MAX_FINAL_FEE();
        rug.startTime = uint40(block.timestamp + 30 days);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchGuardHook.LaunchAlreadyStarted.selector, poolId, uint256(START_TIME))
        );
        hook.configureLaunch(key, rug);

        // A holder can still sell at the fee they bought under.
        _assertCharged(false, SWAP_AMOUNT, FINAL_FEE);
        // The fee split and the tax are under the same freeze.
        vm.expectRevert(
            abi.encodeWithSelector(LaunchGuardHook.LaunchAlreadyStarted.selector, poolId, uint256(START_TIME))
        );
        hook.configureFeeSplit(key, _defaultFeeSplit());
    }

    function test_FIX_disabledLaunchStaysReconfigurableUntilSomebodyTrades() public {
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.enabled = false;
        hook.configureLaunch(key, cfg);

        // No swap yet: the owner may still change its mind, in either direction.
        vm.warp(START_TIME - 50);
        cfg.finalFeeBips = 500;
        hook.configureLaunch(key, cfg);
        assertEq(hook.getLaunch(poolId).finalFeeBips, 500);
        cfg.enabled = true;
        hook.configureLaunch(key, cfg);
        assertTrue(hook.getLaunch(poolId).enabled);
    }

    /// @dev The other direction of the same trick: an enabled launch flipped to disabled before its open
    /// (which opens trading at once) freezes on the first trade too, so it cannot be flipped back.
    function test_FIX_enabledLaunchFlippedToDisabledFreezesOnFirstSwap() public {
        vm.warp(START_TIME - 50);
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.enabled = false;
        hook.configureLaunch(key, cfg); // allowed: nobody has traded

        _swap(key, true, SWAP_AMOUNT); // somebody buys the open pool

        cfg.enabled = true;
        cfg.startTime = uint40(block.timestamp + 30 days);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchGuardHook.LaunchAlreadyStarted.selector, poolId, uint256(START_TIME))
        );
        hook.configureLaunch(key, cfg);
    }

    /*//////////////////////////////////////////////////////////////
          L-1 (review 2026-09-18): an untraded launch cannot be postponed for ever
    //////////////////////////////////////////////////////////////*/

    /// @dev `setUp` claimed the pool; the deadline is claim time + 30 days and no later write moves it.
    function test_FIX_L1_openDeadlineIsFixedAtFirstClaim() public {
        uint256 deadline = hook.openDeadline(poolId);
        assertEq(deadline, 1 + uint256(hook.MAX_START_DELAY_SECONDS()), "claim time + MAX_START_DELAY");
        vm.warp(START_TIME - 50);
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.startTime = uint40(block.timestamp + 10 days);
        hook.configureLaunch(key, cfg);
        assertEq(hook.openDeadline(poolId), deadline, "a reconfiguration does not move the deadline");
        assertEq(hook.openDeadline(PoolId.wrap(bytes32(uint256(1)))), 0, "an unclaimed pool has none");
    }

    /// @dev Before the fix each write could look 30 days ahead of NOW, so re-pushing just before every
    /// open postponed an untraded launch indefinitely. Now no write may go past the deadline, and the
    /// launch opens at the latest when the deadline arrives.
    function test_FIX_L1_cannotPostponeAnUntradedLaunchPastItsDeadline() public {
        uint256 deadline = hook.openDeadline(poolId);
        LaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();

        vm.warp(START_TIME - 1);
        cfg.startTime = uint40(deadline + 1); // within 30 days of now, past the deadline
        vm.expectRevert(
            abi.encodeWithSelector(LaunchGuardHook.StartTimeAfterOpenDeadline.selector, poolId, deadline + 1, deadline)
        );
        hook.configureLaunch(key, cfg);

        cfg.startTime = uint40(deadline); // exactly the deadline is allowed
        hook.configureLaunch(key, cfg);

        vm.warp(deadline - 1); // the last moment a write is possible: every later open is refused
        cfg.startTime = uint40(block.timestamp + 30 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                LaunchGuardHook.StartTimeAfterOpenDeadline.selector, poolId, uint256(cfg.startTime), deadline
            )
        );
        hook.configureLaunch(key, cfg);

        vm.warp(deadline); // and it opens
        _swap(key, true, SWAP_AMOUNT);
        assertTrue(hook.getLaunch(poolId).launched, "the launch traded at its deadline");
    }
}
