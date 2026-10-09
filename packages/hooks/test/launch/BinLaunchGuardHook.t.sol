// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
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
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {PackedUint128Math} from "infinity-core/src/pool-bin/libraries/math/PackedUint128Math.sol";

import {
    IBinHooks,
    HOOKS_BEFORE_INITIALIZE_OFFSET,
    HOOKS_AFTER_INITIALIZE_OFFSET,
    HOOKS_BEFORE_MINT_OFFSET,
    HOOKS_AFTER_MINT_OFFSET,
    HOOKS_BEFORE_BURN_OFFSET,
    HOOKS_AFTER_BURN_OFFSET,
    HOOKS_BEFORE_SWAP_OFFSET,
    HOOKS_AFTER_SWAP_OFFSET,
    HOOKS_BEFORE_DONATE_OFFSET,
    HOOKS_AFTER_DONATE_OFFSET,
    HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET,
    HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET,
    HOOKS_AFTER_MINT_RETURNS_DELTA_OFFSET,
    HOOKS_AFTER_BURN_RETURNS_DELTA_OFFSET
} from "infinity-core/src/pool-bin/interfaces/IBinHooks.sol";

import {BinTestHelper} from "infinity-core/test/pool-bin/helpers/BinTestHelper.sol";
import {BinSwapHelper} from "infinity-core/test/pool-bin/helpers/BinSwapHelper.sol";
import {BinLiquidityHelper} from "infinity-core/test/pool-bin/helpers/BinLiquidityHelper.sol";

import {BaseBinHook} from "../../src/base/BaseBinHook.sol";
import {BinLaunchGuardHook} from "../../src/launch/BinLaunchGuardHook.sol";
import {ILaunchTokenOrigin} from "../../src/launch/LaunchGuardHook.sol";
import {LaunchTaxModule} from "../../src/launch/LaunchTaxModule.sol";

/// @dev The protocol recipient of the fee and of the creator tax, for every hook these tests deploy.
/// The money path is exercised in `LaunchTax.t.sol`; this file is about the guard: the gate, the
/// schedule, the cap, the mint route, and that ON A SWAP the schedule is CHARGED BY THE GUARD IN THE
/// QUOTE CURRENCY while core applies an LP fee of zero. ON A MINT the same schedule is still handed
/// to core as the composition fee.
address constant TAX_PROTOCOL = address(0xFEE);

/*//////////////////////////////////////////////////////////////
                        TEST-ONLY HOOKS
//////////////////////////////////////////////////////////////*/

/// @dev A minimal `BaseBinHook` used to exercise the base contract's deploy-time permission
/// validation and its reverting default callbacks.
/// @dev `getHooksRegistrationBitmap` must be `pure`, so it cannot read a constructor argument. The
/// bitmap under test is therefore handed straight to `_validatePermissions` — the same internal
/// function the base constructor calls — which is what these tests are actually asserting on.
contract ConfigurableBinHook is BaseBinHook {
    constructor(IBinPoolManager _pm, uint16 bitmap_) BaseBinHook(_pm) {
        _validatePermissions(bitmap_);
    }

    function getHooksRegistrationBitmap() public pure override returns (uint16) {
        return 0;
    }

    /// @dev Re-expose the constants so tests can assert them against core's own offsets.
    function beforeInitializeBit() external pure returns (uint16) {
        return BEFORE_INITIALIZE;
    }

    function afterInitializeBit() external pure returns (uint16) {
        return AFTER_INITIALIZE;
    }

    function beforeMintBit() external pure returns (uint16) {
        return BEFORE_MINT;
    }

    function afterMintBit() external pure returns (uint16) {
        return AFTER_MINT;
    }

    function beforeBurnBit() external pure returns (uint16) {
        return BEFORE_BURN;
    }

    function afterBurnBit() external pure returns (uint16) {
        return AFTER_BURN;
    }

    function beforeSwapBit() external pure returns (uint16) {
        return BEFORE_SWAP;
    }

    function afterSwapBit() external pure returns (uint16) {
        return AFTER_SWAP;
    }

    function beforeDonateBit() external pure returns (uint16) {
        return BEFORE_DONATE;
    }

    function afterDonateBit() external pure returns (uint16) {
        return AFTER_DONATE;
    }

    function beforeSwapReturnsDeltaBit() external pure returns (uint16) {
        return BEFORE_SWAP_RETURNS_DELTA;
    }

    function afterSwapReturnsDeltaBit() external pure returns (uint16) {
        return AFTER_SWAP_RETURNS_DELTA;
    }

    function afterMintReturnsDeltaBit() external pure returns (uint16) {
        return AFTER_MINT_RETURNS_DELTA;
    }

    function afterBurnReturnsDeltaBit() external pure returns (uint16) {
        return AFTER_BURN_RETURNS_DELTA;
    }

    function maxLpFee() external pure returns (uint24) {
        return MAX_LP_FEE;
    }
}

/// @dev A `BinLaunchGuardHook` that records the `sender` argument core hands to `beforeSwap` and
/// `beforeMint`. Used only by the `sender` tests to pin the constraint the whole design rests on.
contract SenderRecordingBinLaunchGuardHook is BinLaunchGuardHook {
    address public lastSwapSender;
    address public lastMintSender;
    uint256 public swapCount;

    constructor(IBinPoolManager _pm) BinLaunchGuardHook(_pm, ILaunchTokenOrigin(address(0)), TAX_PROTOCOL, 0) {}

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        bool swapForY,
        int128 amountSpecified,
        bytes calldata hookData
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        lastSwapSender = sender;
        swapCount++;
        return super._beforeSwap(sender, key, swapForY, amountSpecified, hookData);
    }

    function _beforeMint(
        address sender,
        PoolKey calldata key,
        IBinPoolManager.MintParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4, uint24) {
        lastMintSender = sender;
        return super._beforeMint(sender, key, params, hookData);
    }
}

/// @dev The naive port: exactly the CL hook's permission set (`beforeInitialize | beforeSwap`),
/// with `beforeMint` left unregistered. Used to DEMONSTRATE the bin-only hole that motivates the
/// real hook's extra permission bit. It is not a hook anybody should deploy.
contract NaiveBinLaunchGuardHook is BinLaunchGuardHook {
    constructor(IBinPoolManager _pm) BinLaunchGuardHook(_pm, ILaunchTokenOrigin(address(0)), TAX_PROTOCOL, 0) {}

    function getHooksRegistrationBitmap() public pure override returns (uint16) {
        return BEFORE_INITIALIZE | BEFORE_SWAP;
    }
}

/// @dev Stands in for `LaunchTokenFactory.deployerOf`, so the reservation can be driven per token.
contract MockBinLaunchTokenOrigin {
    mapping(address token => address deployer) public deployerOf;

    function set(address token, address deployer) external {
        deployerOf[token] = deployer;
    }
}

/*//////////////////////////////////////////////////////////////
                              TESTS
//////////////////////////////////////////////////////////////*/

contract BinLaunchGuardHookTest is Test, BinTestHelper {
    using LPFeeLibrary for uint24;
    using CurrencyLibrary for Currency;
    using BinPoolParametersHelper for bytes32;
    using PackedUint128Math for bytes32;

    Vault vault;
    BinPoolManager poolManager;
    BinLaunchGuardHook hook;
    BinSwapHelper swapHelper;
    BinLiquidityHelper liquidityHelper;

    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;

    PoolKey key;
    PoolId poolId;

    /// @dev binId at which token0 and token1 trade 1:1.
    uint24 constant ACTIVE_ID = 2 ** 23;
    uint16 constant BIN_STEP = 10;

    /// @dev Foundry starts tests at timestamp 1; the default launch opens 100 seconds later.
    uint40 constant START_TIME = 101;
    uint32 constant DECAY_SECONDS = 100;

    /// @dev 8%. The CL suite's default opening tax is 30% and its ceiling is 50%; BOTH are simply
    /// unreachable on a bin pool, whose ceiling is 10% (`test_feeCap_binCeilingIsOneTenthOfCL`).
    uint24 constant INITIAL_FEE = 80_000;
    uint24 constant FINAL_FEE = 3_000; // 0.30%

    int128 constant SWAP_AMOUNT = -10_000; // exact input, tiny relative to liquidity

    /// @dev The fee split every pool in this file is born with. `LaunchTax.t.sol` tests its bounds.
    address constant FEE_CREATOR = address(0xC0FFEE);
    address constant FEE_INTEGRATOR = address(0x1D7E);

    bytes constant ZERO_BYTES = "";

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
        vault = new Vault();
        poolManager = new BinPoolManager(IVault(address(vault)));
        vault.registerApp(address(poolManager));

        token0 = new MockERC20("TestA", "A", 18);
        token1 = new MockERC20("TestB", "B", 18);
        (token0, token1) = address(token0) < address(token1) ? (token0, token1) : (token1, token0);
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));
        token0.mint(address(this), 1000 ether);
        token1.mint(address(this), 1000 ether);

        swapHelper = new BinSwapHelper(poolManager, vault);
        liquidityHelper = new BinLiquidityHelper(poolManager, vault);
        _approveAll(address(this));

        hook = new BinLaunchGuardHook(poolManager, ILaunchTokenOrigin(address(0)), TAX_PROTOCOL, 0);
        key = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, BIN_STEP);
        poolId = key.toId();

        hook.configureLaunch(key, _defaultConfig());
        hook.configureFeeSplit(key, _defaultFeeSplit());
        poolManager.initialize(key, ACTIVE_ID);

        // Seed the pool. A ratio-matched mint into a fresh bin incurs no composition fee, so the
        // hook's mint tax does not penalise seeding (see `test_mint_balancedSeedingIsUntaxed`).
        liquidityHelper.mint(key, _getSingleBinMintParams(ACTIVE_ID, 100 ether, 100 ether), ZERO_BYTES);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _approveAll(address who) internal {
        vm.startPrank(who);
        token0.approve(address(swapHelper), type(uint256).max);
        token1.approve(address(swapHelper), type(uint256).max);
        token0.approve(address(liquidityHelper), type(uint256).max);
        token1.approve(address(liquidityHelper), type(uint256).max);
        vm.stopPrank();
    }

    function _key(IHooks _hook, uint24 fee, uint16 binStep) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: _hook,
            poolManager: poolManager,
            fee: fee,
            parameters: bytes32(uint256(_hook.getHooksRegistrationBitmap())).setBinStep(binStep)
        });
    }

    function _defaultConfig() internal pure returns (BinLaunchGuardHook.LaunchConfig memory) {
        return BinLaunchGuardHook.LaunchConfig({
            startTime: START_TIME,
            decaySeconds: DECAY_SECONDS,
            initialFeeBips: INITIAL_FEE,
            finalFeeBips: FINAL_FEE,
            maxBuyPerTx: 0,
            launchTokenIsCurrency0: false, // currency1 (Y) is the launched token => a buy is swapForY
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

    function _swap(PoolKey memory k, bool swapForY, int128 amountSpecified) internal returns (BalanceDelta) {
        return swapHelper.swap(k, swapForY, amountSpecified, BinSwapHelper.TestSettings(true, true), ZERO_BYTES);
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
    /// the ground truth for what reached `BinPool.swap`, not what the hook said it returned. With
    /// no protocol fee controller set, the event's `fee` field is the LP fee exactly.
    function _swapAndReadCharge(bool swapForY, int128 amountSpecified) internal returns (Charge memory) {
        return this.measureCharge(swapForY, amountSpecified);
    }

    /// @dev Behind an EXTERNAL call to this contract on purpose. Decoding `Vm.Log[]` takes a dozen
    /// stack slots, and via-IR inlines an internal helper into whichever test calls it: with the
    /// test's own structs live that is one slot too many ("too deep in the stack"). The router's
    /// caller is this contract either way, and `vm.expectEmit` sees the events of nested calls.
    function measureCharge(bool swapForY, int128 amountSpecified) external returns (Charge memory c) {
        bool tokenIs0 = hook.getLaunch(poolId).launchTokenIsCurrency0;
        (Currency quote, Currency token) = tokenIs0 ? (currency1, currency0) : (currency0, currency1);
        bool isBuy = tokenIs0 ? !swapForY : swapForY;

        uint256 feeBefore = hook.feeTaken(poolId, quote);
        uint256 claimsBefore = vault.balanceOf(address(hook), quote);
        uint256 tokenBefore = _tokenFootprint(poolId, token);
        uint256 quoteBefore = quote.balanceOf(address(this));
        uint256 heldBefore = token.balanceOf(address(this));

        vm.recordLogs();
        _swap(key, swapForY, amountSpecified);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(poolManager) && logs[i].topics[0] == IBinPoolManager.Swap.selector) {
                // Swap(PoolId indexed, address indexed, int128, int128, uint24 activeId, uint24 fee, uint16)
                (int128 g0, int128 g1,, uint24 fee,) = abi.decode(logs[i].data, (int128, int128, uint24, uint24, uint16));
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
            ? (amountSpecified < 0 ? uint256(-int256(amountSpecified)) : uint256(int256(amountSpecified)))
            : (c.poolQuote < 0 ? uint256(-c.poolQuote) : uint256(c.poolQuote));
    }

    /// @dev One swap on `key` that must be charged exactly `feePips` of its quote amount BY THE
    /// GUARD, in the quote, with an LP fee of zero and nothing taken in the launch token. No tax is
    /// configured in this file unless a test says so, so the guard's take is the fee alone.
    function _assertCharged(bool swapForY, int128 amountSpecified, uint24 feePips)
        internal
        returns (Charge memory c)
    {
        c = _swapAndReadCharge(swapForY, amountSpecified);
        assertEq(c.lpFee, 0, "core applied an LP fee");
        assertEq(c.fee, c.base * feePips / 1_000_000, "the guard's fee is not the schedule's");
        assertEq(c.claims, c.fee, "taken as a vault claim in the quote");
        assertEq(c.tokenTaken, 0, "the guard took launch token");
        assertEq(c.traderQuote, c.poolQuote - int256(c.fee), "the trader paid the pool's quote and the fee");
        assertEq(c.traderToken, c.poolToken, "the launch token side is the pool's alone");
    }

    /// @dev Mints single-sided X into the ACTIVE bin — a lopsided add, which core turns into an
    /// implicit swap — and returns the composition fee it charged, read out of core's `Mint` event.
    /// This is the bin-only route around a swap tax; see the contract's "THE MINT HOLE" note.
    function _lopsidedMintAndReadCompositionFee(PoolKey memory k, uint256 amountX)
        internal
        returns (uint128 feeX, uint128 feeY)
    {
        vm.recordLogs();
        liquidityHelper.mint(k, _getCustomSingleSidedBinMintParam(ACTIVE_ID, amountX, false), ZERO_BYTES);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(poolManager) && logs[i].topics[0] == IBinPoolManager.Mint.selector) {
                // Mint(PoolId indexed, address indexed, uint256[] ids, bytes32 salt, bytes32[] amounts,
                //      bytes32 compositionFeeAmount, bytes32 feeAmountToProtocol)
                (,,, bytes32 compositionFee,) =
                    abi.decode(logs[i].data, (uint256[], bytes32, bytes32[], bytes32, bytes32));
                return (compositionFee.decodeX(), compositionFee.decodeY());
            }
        }
        revert("Mint event not found");
    }

    /// @dev A second pool on the SAME hook instance, distinguished only by its binStep, configured
    /// with the default schedule, initialized and seeded identically to `key`.
    function _freshGuardedPool(uint16 binStep) internal returns (PoolKey memory k) {
        k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, binStep);
        hook.configureLaunch(k, _defaultConfig());
        hook.configureFeeSplit(k, _defaultFeeSplit());
        poolManager.initialize(k, ACTIVE_ID);
        liquidityHelper.mint(k, _getSingleBinMintParams(ACTIVE_ID, 100 ether, 100 ether), ZERO_BYTES);
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
        // bit 0 (beforeInitialize) | bit 2 (beforeMint) | bit 6 (beforeSwap) | bit 7 (afterSwap)
        // | bit 10 (beforeSwapReturnsDelta) | bit 11 (afterSwapReturnsDelta) == 0x0CC5. beforeMint is
        // the bin-only addition: without it the composition-fee route is untaxed. The two
        // returns-delta bits are how the guard takes its fee and the creator tax in the quote: bit 10
        // when the quote is the specified side of the swap, bit 11 when it is not.
        assertEq(hook.getHooksRegistrationBitmap(), uint16(0x0CC5));
        assertEq(
            hook.getHooksRegistrationBitmap(),
            uint16(1) << HOOKS_BEFORE_INITIALIZE_OFFSET | uint16(1) << HOOKS_BEFORE_MINT_OFFSET | uint16(1)
                << HOOKS_BEFORE_SWAP_OFFSET | uint16(1) << HOOKS_AFTER_SWAP_OFFSET | uint16(1)
                << HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET | uint16(1) << HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET
        );
    }

    /// @dev `BaseBinHook`'s constructor runs `_validatePermissions` on the bitmap: bit 10 needs bit 6
    /// and bit 11 needs bit 7. A guard that deploys has passed it, the same function accepts the
    /// bitmap when it is handed over directly, and core accepts it in a pool's parameters (the pool
    /// in `setUp` was initialized under it).
    function test_bitmap_validatesAtDeployAndIsAcceptedByCore() public {
        BinLaunchGuardHook fresh = new BinLaunchGuardHook(poolManager, ILaunchTokenOrigin(address(0)), TAX_PROTOCOL, 0);
        assertEq(fresh.getHooksRegistrationBitmap(), uint16(0x0CC5));
        new ConfigurableBinHook(poolManager, uint16(0x0CC5)); // does not revert
        assertEq(uint16(uint256(key.parameters)), uint16(0x0CC5), "the bitmap the pool was created under");
        (uint24 activeId,,) = poolManager.getSlot0(poolId);
        assertEq(activeId, ACTIVE_ID);

        // Either returns-delta bit without its callback is refused by the same validation.
        vm.expectRevert(abi.encodeWithSelector(BaseBinHook.PermissionDependencyMissing.selector, uint16(0x0C85)));
        new ConfigurableBinHook(poolManager, uint16(0x0C85)); // 0x0CC5 without beforeSwap (bit 6)
        vm.expectRevert(abi.encodeWithSelector(BaseBinHook.PermissionDependencyMissing.selector, uint16(0x0C45)));
        new ConfigurableBinHook(poolManager, uint16(0x0C45)); // 0x0CC5 without afterSwap (bit 7)
    }

    /// @dev Pins BaseBinHook's constants against core's own offsets. Bits 0-13 are the same layout
    /// as CL; only bits 2-5, 12 and 13 are RENAMED (mint/burn instead of add/remove-liquidity).
    function test_bitmap_offsetsMatchCoreExactly() public {
        ConfigurableBinHook probe = new ConfigurableBinHook(poolManager, 0);

        assertEq(probe.beforeInitializeBit(), uint16(1) << HOOKS_BEFORE_INITIALIZE_OFFSET);
        assertEq(probe.afterInitializeBit(), uint16(1) << HOOKS_AFTER_INITIALIZE_OFFSET);
        assertEq(probe.beforeMintBit(), uint16(1) << HOOKS_BEFORE_MINT_OFFSET);
        assertEq(probe.afterMintBit(), uint16(1) << HOOKS_AFTER_MINT_OFFSET);
        assertEq(probe.beforeBurnBit(), uint16(1) << HOOKS_BEFORE_BURN_OFFSET);
        assertEq(probe.afterBurnBit(), uint16(1) << HOOKS_AFTER_BURN_OFFSET);
        assertEq(probe.beforeSwapBit(), uint16(1) << HOOKS_BEFORE_SWAP_OFFSET);
        assertEq(probe.afterSwapBit(), uint16(1) << HOOKS_AFTER_SWAP_OFFSET);
        assertEq(probe.beforeDonateBit(), uint16(1) << HOOKS_BEFORE_DONATE_OFFSET);
        assertEq(probe.afterDonateBit(), uint16(1) << HOOKS_AFTER_DONATE_OFFSET);
        assertEq(probe.beforeSwapReturnsDeltaBit(), uint16(1) << HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET);
        assertEq(probe.afterSwapReturnsDeltaBit(), uint16(1) << HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET);
        assertEq(probe.afterMintReturnsDeltaBit(), uint16(1) << HOOKS_AFTER_MINT_RETURNS_DELTA_OFFSET);
        assertEq(probe.afterBurnReturnsDeltaBit(), uint16(1) << HOOKS_AFTER_BURN_RETURNS_DELTA_OFFSET);

        // Bits 14-15 are unassigned on bin exactly as on CL, and binStep begins at offset 16.
        assertEq(BinPoolParametersHelper.OFFSET_BIN_STEP, 16);
    }

    function test_feeCaps_stayWithinWhatCoreAccepts() public view {
        // Core reverts with LPFeeTooLarge above 100_000 for a BIN pool. On a SWAP the schedule is
        // no longer an LP fee, so core no longer bounds it there; on a MINT it still is, and the
        // two routes read one schedule. The hook's cap therefore stays core's bin ceiling, so a
        // configured schedule can never produce a composition fee core would reject.
        assertEq(hook.MAX_INITIAL_FEE(), LPFeeLibrary.TEN_PERCENT_FEE);
        assertEq(hook.MAX_FINAL_FEE(), 20_000);
        assertLe(hook.MAX_FINAL_FEE(), hook.MAX_INITIAL_FEE());
        // With the creator tax at its own cap on the same base the guard takes 20% at most.
        assertEq(uint256(hook.MAX_INITIAL_FEE()) + uint256(hook.MAX_TAX_BPS()) * 100, 200_000);
    }

    /// @dev The headline difference from the CL hook, asserted rather than merely commented.
    function test_feeCap_binCeilingIsOneTenthOfCL() public {
        assertEq(LPFeeLibrary.TEN_PERCENT_FEE * 10, LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE);
        assertLt(hook.MAX_INITIAL_FEE(), LPFeeLibrary.ONE_HUNDRED_PERCENT_FEE);

        ConfigurableBinHook probe = new ConfigurableBinHook(poolManager, 0);
        assertEq(probe.maxLpFee(), LPFeeLibrary.TEN_PERCENT_FEE);
    }

    /*//////////////////////////////////////////////////////////////
                     BaseBinHook PERMISSION VALIDATION
    //////////////////////////////////////////////////////////////*/

    function test_base_acceptsEveryReturnsDeltaFlagWithItsBaseCallback() public {
        uint16 full = uint16(1) << HOOKS_BEFORE_SWAP_OFFSET | uint16(1) << HOOKS_AFTER_SWAP_OFFSET | uint16(1)
            << HOOKS_AFTER_MINT_OFFSET | uint16(1) << HOOKS_AFTER_BURN_OFFSET | uint16(1)
            << HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET | uint16(1) << HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET | uint16(1)
            << HOOKS_AFTER_MINT_RETURNS_DELTA_OFFSET | uint16(1) << HOOKS_AFTER_BURN_RETURNS_DELTA_OFFSET;
        // Does not revert.
        new ConfigurableBinHook(poolManager, full);
    }

    function test_base_rejectsBeforeSwapReturnsDeltaWithoutBeforeSwap() public {
        uint16 bad = uint16(1) << HOOKS_BEFORE_SWAP_RETURNS_DELTA_OFFSET;
        vm.expectRevert(abi.encodeWithSelector(BaseBinHook.PermissionDependencyMissing.selector, bad));
        new ConfigurableBinHook(poolManager, bad);
    }

    function test_base_rejectsAfterSwapReturnsDeltaWithoutAfterSwap() public {
        uint16 bad = uint16(1) << HOOKS_AFTER_SWAP_RETURNS_DELTA_OFFSET;
        vm.expectRevert(abi.encodeWithSelector(BaseBinHook.PermissionDependencyMissing.selector, bad));
        new ConfigurableBinHook(poolManager, bad);
    }

    /// @dev The bin-renamed bit. Core's own `BinHooks.validatePermissionsConflict` checks the same
    /// pair; this catches it a whole pool-creation earlier.
    function test_base_rejectsAfterMintReturnsDeltaWithoutAfterMint() public {
        uint16 bad = uint16(1) << HOOKS_AFTER_MINT_RETURNS_DELTA_OFFSET;
        vm.expectRevert(abi.encodeWithSelector(BaseBinHook.PermissionDependencyMissing.selector, bad));
        new ConfigurableBinHook(poolManager, bad);
    }

    function test_base_rejectsAfterBurnReturnsDeltaWithoutAfterBurn() public {
        uint16 bad = uint16(1) << HOOKS_AFTER_BURN_RETURNS_DELTA_OFFSET;
        vm.expectRevert(abi.encodeWithSelector(BaseBinHook.PermissionDependencyMissing.selector, bad));
        new ConfigurableBinHook(poolManager, bad);
    }

    /// @dev Bit 16 upwards is `binStep`, so the reserved bits are not merely decorative: a hook
    /// that set bit 15 would be one bit away from silently changing a pool's bin step.
    function test_base_rejectsReservedBits() public {
        vm.expectRevert(abi.encodeWithSelector(BaseBinHook.ReservedBitsSet.selector, uint16(0x4000)));
        new ConfigurableBinHook(poolManager, uint16(0x4000));

        vm.expectRevert(abi.encodeWithSelector(BaseBinHook.ReservedBitsSet.selector, uint16(0x8000)));
        new ConfigurableBinHook(poolManager, uint16(0x8000));
    }

    /// @dev Every callback a subclass has not overridden must revert loudly when core reaches it,
    /// so a bitmap that over-declares fails on the first call rather than corrupting accounting.
    function test_base_unimplementedCallbacksRevertHookNotImplemented() public {
        ConfigurableBinHook bare = new ConfigurableBinHook(poolManager, 0);
        IBinPoolManager.MintParams memory mp = _getSingleBinMintParams(ACTIVE_ID, 1 ether, 1 ether);
        IBinPoolManager.BurnParams memory bp =
            _getSingleBinBurnLiquidityParams(key, poolManager, ACTIVE_ID, address(this), 100);

        vm.startPrank(address(poolManager));

        vm.expectRevert(BaseBinHook.HookNotImplemented.selector);
        bare.beforeInitialize(address(this), key, ACTIVE_ID);
        vm.expectRevert(BaseBinHook.HookNotImplemented.selector);
        bare.afterInitialize(address(this), key, ACTIVE_ID);
        vm.expectRevert(BaseBinHook.HookNotImplemented.selector);
        bare.beforeMint(address(this), key, mp, ZERO_BYTES);
        vm.expectRevert(BaseBinHook.HookNotImplemented.selector);
        bare.afterMint(address(this), key, mp, BalanceDelta.wrap(0), ZERO_BYTES);
        vm.expectRevert(BaseBinHook.HookNotImplemented.selector);
        bare.beforeBurn(address(this), key, bp, ZERO_BYTES);
        vm.expectRevert(BaseBinHook.HookNotImplemented.selector);
        bare.afterBurn(address(this), key, bp, BalanceDelta.wrap(0), ZERO_BYTES);
        vm.expectRevert(BaseBinHook.HookNotImplemented.selector);
        bare.beforeSwap(address(this), key, true, SWAP_AMOUNT, ZERO_BYTES);
        vm.expectRevert(BaseBinHook.HookNotImplemented.selector);
        bare.afterSwap(address(this), key, true, SWAP_AMOUNT, BalanceDelta.wrap(0), ZERO_BYTES);
        vm.expectRevert(BaseBinHook.HookNotImplemented.selector);
        bare.beforeDonate(address(this), key, 1, 1, ZERO_BYTES);
        vm.expectRevert(BaseBinHook.HookNotImplemented.selector);
        bare.afterDonate(address(this), key, 1, 1, ZERO_BYTES);

        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                             CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function test_configure_claimsOwnershipAndStoresConfig() public {
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 20);
        PoolId id = k.toId();
        address launcher = makeAddr("launcher");

        assertEq(hook.launchOwner(id), address(0));

        vm.expectEmit(true, true, false, true, address(hook));
        emit LaunchClaimed(id, launcher);
        vm.expectEmit(true, true, false, true, address(hook));
        emit LaunchConfigured(id, launcher, START_TIME, DECAY_SECONDS, INITIAL_FEE, FINAL_FEE, 0, false, true);

        vm.prank(launcher);
        hook.configureLaunch(k, _defaultConfig());

        BinLaunchGuardHook.Launch memory l = hook.getLaunch(id);
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
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 20);
        k.hooks = IHooks(makeAddr("someOtherHook"));
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.HookMismatch.selector, address(k.hooks)));
        hook.configureLaunch(k, _defaultConfig());
    }

    function test_configure_revertsOnForeignPoolManager() public {
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 20);
        k.poolManager = IPoolManager(makeAddr("someOtherManager"));
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.PoolManagerMismatch.selector, address(k.poolManager)));
        hook.configureLaunch(k, _defaultConfig());
    }

    function test_configure_revertsOnStaticFeePool() public {
        PoolKey memory k = _key(hook, 3000, 20);
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.PoolMustUseDynamicFee.selector, uint24(3000)));
        hook.configureLaunch(k, _defaultConfig());
    }

    function test_configure_unauthorizedCallerCannotReconfigure() public {
        address attacker = makeAddr("attacker");
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.initialFeeBips = 1_000;

        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.NotLaunchOwner.selector, poolId, attacker));
        hook.configureLaunch(key, cfg);

        assertEq(hook.getLaunch(poolId).initialFeeBips, INITIAL_FEE);
    }

    function test_configure_ownerMayUpdateBeforeStartBlock() public {
        vm.warp(START_TIME - 1);

        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.initialFeeBips = 50_000;
        cfg.finalFeeBips = 1_000;
        cfg.maxBuyPerTx = 12345;
        hook.configureLaunch(key, cfg);

        BinLaunchGuardHook.Launch memory l = hook.getLaunch(poolId);
        assertEq(l.initialFeeBips, 50_000);
        assertEq(l.finalFeeBips, 1_000);
        assertEq(l.maxBuyPerTx, 12345);
        assertEq(l.owner, address(this)); // ownership unchanged by an update
    }

    function test_configure_frozenAtExactStartBlock() public {
        vm.warp(START_TIME);
        vm.expectRevert(
            abi.encodeWithSelector(BinLaunchGuardHook.LaunchAlreadyStarted.selector, poolId, uint256(START_TIME))
        );
        hook.configureLaunch(key, _defaultConfig());
    }

    function test_configure_frozenAfterStartBlock() public {
        vm.warp(START_TIME + 1);
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.startTime = uint40(START_TIME + 500);
        cfg.initialFeeBips = 100_000; // the rug attempt: spike the fee mid-launch

        vm.expectRevert(
            abi.encodeWithSelector(BinLaunchGuardHook.LaunchAlreadyStarted.selector, poolId, uint256(START_TIME))
        );
        hook.configureLaunch(key, cfg);
    }

    function test_configure_frozenEvenLongAfterTheDecayWindow() public {
        vm.warp(START_TIME + DECAY_SECONDS + 1_000_000);
        vm.expectRevert(
            abi.encodeWithSelector(BinLaunchGuardHook.LaunchAlreadyStarted.selector, poolId, uint256(START_TIME))
        );
        hook.configureLaunch(key, _defaultConfig());
    }

    function test_configure_rejectsStartBlockInThePast() public {
        vm.warp(1000);
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.startTime = 999;
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 20);
        vm.expectRevert(
            abi.encodeWithSelector(BinLaunchGuardHook.InvalidStartTime.selector, uint256(999), uint256(1000))
        );
        hook.configureLaunch(k, cfg);
    }

    function test_configure_acceptsStartBlockEqualToNow() public {
        vm.warp(1000);
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.startTime = 1000;
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 20);
        hook.configureLaunch(k, cfg);
        assertEq(hook.getLaunch(k.toId()).startTime, 1000);

        // ...and it is immediately frozen, because the launch is already open.
        vm.expectRevert(
            abi.encodeWithSelector(BinLaunchGuardHook.LaunchAlreadyStarted.selector, k.toId(), uint256(1000))
        );
        hook.configureLaunch(k, cfg);
    }

    function test_configure_rejectsStartBlockTooFarAhead() public {
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.startTime = uint40(block.timestamp + hook.MAX_START_DELAY_SECONDS() + 1);
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 20);
        vm.expectRevert(
            abi.encodeWithSelector(BinLaunchGuardHook.InvalidStartTime.selector, uint256(cfg.startTime), block.timestamp)
        );
        hook.configureLaunch(k, cfg);
    }

    function test_configure_rejectsZeroDecayBlocks() public {
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.decaySeconds = 0;
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 20);
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.InvalidDecaySeconds.selector, uint32(0)));
        hook.configureLaunch(k, cfg);
    }

    function test_configure_rejectsOversizedDecayWindow() public {
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.decaySeconds = hook.MAX_DECAY_SECONDS() + 1;
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 20);
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.InvalidDecaySeconds.selector, cfg.decaySeconds));
        hook.configureLaunch(k, cfg);
    }

    function test_configure_rejectsRisingFeeSchedule() public {
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.initialFeeBips = 1_000;
        cfg.finalFeeBips = 2_000;
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 20);
        vm.expectRevert(
            abi.encodeWithSelector(BinLaunchGuardHook.InvalidFeeSchedule.selector, uint24(1_000), uint24(2_000))
        );
        hook.configureLaunch(k, cfg);
    }

    function test_configure_rejectsInitialFeeAboveBinCeiling() public {
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.initialFeeBips = hook.MAX_INITIAL_FEE() + 1; // 100_001
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 20);
        vm.expectRevert(
            abi.encodeWithSelector(BinLaunchGuardHook.InvalidFeeSchedule.selector, cfg.initialFeeBips, FINAL_FEE)
        );
        hook.configureLaunch(k, cfg);
    }

    /// @dev The CL hook's own suite launches at 30% and caps at 50%. Both are simply illegal on a
    /// bin pool: core would revert the very first swap with `LPFeeTooLarge`, so the hook refuses
    /// the configuration instead of letting a launch brick itself.
    function test_configure_rejectsACLGradeOpeningTax() public {
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.initialFeeBips = 300_000; // perfectly legal on CL
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 20);
        vm.expectRevert(
            abi.encodeWithSelector(BinLaunchGuardHook.InvalidFeeSchedule.selector, uint24(300_000), FINAL_FEE)
        );
        hook.configureLaunch(k, cfg);
    }

    function test_configure_rejectsFinalFeeAboveCap() public {
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.finalFeeBips = hook.MAX_FINAL_FEE() + 1;
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 20);
        vm.expectRevert(
            abi.encodeWithSelector(BinLaunchGuardHook.InvalidFeeSchedule.selector, INITIAL_FEE, cfg.finalFeeBips)
        );
        hook.configureLaunch(k, cfg);
    }

    /// @dev RESIDUAL RISK, DELIBERATELY CAPTURED. Ownership is established by first-claim, so a
    /// front-runner can squat an unclaimed pool id and make that exact PoolKey unusable. The blast
    /// radius is bounded - the squatter gets no funds, and the launcher can move to another binStep
    /// (a different pool id) or claim atomically in the same transaction that initializes and seeds
    /// the pool - but the race itself cannot be removed at this layer, because a PoolKey carries no
    /// field that could bind it to an intended owner. On bin the free bits of `parameters` are
    /// binStep and then zeroes core rejects, so the owner cannot be smuggled into the key either.
    function test_risk_unclaimedPoolIdCanBeSquattedByAFrontRunner() public {
        PoolKey memory victimKey = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 20);
        PoolId victimId = victimKey.toId();

        address squatter = makeAddr("squatter");
        BinLaunchGuardHook.LaunchConfig memory hostile = _defaultConfig();
        hostile.startTime = uint40(block.timestamp + hook.MAX_START_DELAY_SECONDS()); // never opens in practice
        vm.prank(squatter);
        hook.configureLaunch(victimKey, hostile);

        address launcher = makeAddr("launcher");
        vm.prank(launcher);
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.NotLaunchOwner.selector, victimId, launcher));
        hook.configureLaunch(victimKey, _defaultConfig());

        // ...but only that key. A different binStep is a different pool id, still free.
        PoolKey memory escapeKey = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 21);
        vm.prank(launcher);
        hook.configureLaunch(escapeKey, _defaultConfig());
        assertEq(hook.launchOwner(escapeKey.toId()), launcher);

        // And the squatter never gains custody of anything: the pool was never initialized and
        // the hook holds no funds at any point.
        assertEq(token0.balanceOf(address(hook)), 0);
        assertEq(token1.balanceOf(address(hook)), 0);
    }

    /*//////////////////////////////////////////////////////////////
                              INITIALIZE
    //////////////////////////////////////////////////////////////*/

    function test_initialize_revertsWhenPoolIsNotConfigured() public {
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 20);
        _expectHookRevert(
            address(hook),
            IBinHooks.beforeInitialize.selector,
            abi.encodeWithSelector(BinLaunchGuardHook.LaunchNotConfigured.selector, k.toId())
        );
        poolManager.initialize(k, ACTIVE_ID);
    }

    /// @dev A claimed pool with no fee split cannot be created: its fees would land in a pot with
    /// no split, and the split can be written once only, before trading.
    function test_initialize_revertsWhenThePoolHasNoFeeSplit() public {
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 20);
        hook.configureLaunch(k, _defaultConfig());
        _expectHookRevert(
            address(hook),
            IBinHooks.beforeInitialize.selector,
            abi.encodeWithSelector(LaunchTaxModule.FeeSplitNotConfigured.selector, k.toId())
        );
        poolManager.initialize(k, ACTIVE_ID);

        hook.configureFeeSplit(k, _defaultFeeSplit());
        poolManager.initialize(k, ACTIVE_ID);
    }

    /// @dev On a static-fee pool `BinHooks.beforeSwap` (and `BinHooks.beforeMint`) silently DISCARD
    /// the fee the hook returns - the decode is guarded by `if (key.fee.isDynamicLPFee())`, which is
    /// `fee == 0x800000` EXACTLY. The guard's zero LP fee on swaps would be replaced by the pool's
    /// static fee, charged on top of the guard's take and in the input currency, and the mint
    /// route would be charged that static fee instead of the schedule.
    function test_initialize_revertsOnStaticFeePool() public {
        BinLaunchGuardHook openHook = new BinLaunchGuardHook(poolManager, ILaunchTokenOrigin(address(0)), TAX_PROTOCOL, 0);
        PoolKey memory k = _key(openHook, 3000, 20);

        // Prove the static-fee pool is otherwise perfectly valid to core: same bitmap, same shape.
        assertEq(openHook.getHooksRegistrationBitmap(), hook.getHooksRegistrationBitmap());

        _expectHookRevert(
            address(openHook),
            IBinHooks.beforeInitialize.selector,
            abi.encodeWithSelector(BinLaunchGuardHook.PoolMustUseDynamicFee.selector, uint24(3000))
        );
        poolManager.initialize(k, ACTIVE_ID);
    }

    /// @dev `isDynamicLPFee` is an exact equality (`fee == 0x800000`), not a mask test: a fee that
    /// merely has the dynamic BIT set is still static, and any fee this hook returned for it would
    /// be discarded.
    ///
    /// On a bin pool such a near-miss never reaches the hook at all, and the ordering is worth
    /// knowing: `BinPoolManager.initialize` runs `getInitialLPFee(...).validate(TEN_PERCENT_FEE)`
    /// BEFORE `BinHooks.beforeInitialize`. Once the exact-equality test fails, 0x800001 is read as
    /// a static fee of 8_388_609 — eighty times the bin ceiling — so core rejects it first.
    /// The hook's own `PoolMustUseDynamicFee` guard is therefore the backstop for the static fees
    /// that DO clear core's ceiling, which is exactly the dangerous case
    /// (`test_initialize_revertsOnStaticFeePool`).
    function test_initialize_nearMissDynamicFeeFlagIsRejectedByCoreFirst() public {
        BinLaunchGuardHook openHook = new BinLaunchGuardHook(poolManager, ILaunchTokenOrigin(address(0)), TAX_PROTOCOL, 0);
        uint24 nearMiss = LPFeeLibrary.DYNAMIC_FEE_FLAG | uint24(1); // 0x800001
        assertFalse(nearMiss.isDynamicLPFee());
        assertGt(nearMiss, LPFeeLibrary.TEN_PERCENT_FEE);

        PoolKey memory k = _key(openHook, nearMiss, 20);
        vm.expectRevert(abi.encodeWithSelector(LPFeeLibrary.LPFeeTooLarge.selector, nearMiss));
        poolManager.initialize(k, ACTIVE_ID);
    }

    /// @dev And the hook's guard is genuinely load-bearing for a fee core is happy with: 100_000 is
    /// exactly the bin ceiling, so core accepts it, and only the hook stops the pool being created
    /// with a launch tax that would be silently discarded on every swap.
    function test_initialize_rejectsStaticFeeAtCoresCeiling() public {
        BinLaunchGuardHook openHook = new BinLaunchGuardHook(poolManager, ILaunchTokenOrigin(address(0)), TAX_PROTOCOL, 0);
        uint24 staticMax = LPFeeLibrary.TEN_PERCENT_FEE;
        assertFalse(staticMax.isDynamicLPFee());

        PoolKey memory k = _key(openHook, staticMax, 20);
        _expectHookRevert(
            address(openHook),
            IBinHooks.beforeInitialize.selector,
            abi.encodeWithSelector(BinLaunchGuardHook.PoolMustUseDynamicFee.selector, staticMax)
        );
        poolManager.initialize(k, ACTIVE_ID);
    }

    /*//////////////////////////////////////////////////////////////
                            THE LAUNCH GATE
    //////////////////////////////////////////////////////////////*/

    function test_swap_revertsBeforeStartBlock() public {
        vm.warp(START_TIME - 1);
        _expectHookRevert(
            address(hook),
            IBinHooks.beforeSwap.selector,
            abi.encodeWithSelector(
                BinLaunchGuardHook.TradingNotOpen.selector, poolId, uint256(START_TIME), uint256(START_TIME - 1)
            )
        );
        _swap(key, true, SWAP_AMOUNT);
    }

    function test_swap_revertsBeforeStartBlock_inBothDirections() public {
        vm.warp(START_TIME - 1);
        _expectHookRevert(
            address(hook),
            IBinHooks.beforeSwap.selector,
            abi.encodeWithSelector(
                BinLaunchGuardHook.TradingNotOpen.selector, poolId, uint256(START_TIME), uint256(START_TIME - 1)
            )
        );
        _swap(key, false, SWAP_AMOUNT);
    }

    function test_swap_succeedsAtExactStartBlock() public {
        vm.warp(START_TIME);
        Charge memory c = _assertCharged(true, SWAP_AMOUNT, INITIAL_FEE);
        assertEq(c.fee, 800, "8% of the 10_000 wei of quote the buyer sent");
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

    function test_decay_block0IsExactlyInitialFee() public {
        vm.warp(START_TIME);
        assertEq(hook.currentFee(poolId), INITIAL_FEE);
        Charge memory c = _assertCharged(true, SWAP_AMOUNT, INITIAL_FEE);
        assertEq(c.fee, 800);
    }

    function test_decay_midWindow() public {
        vm.warp(START_TIME + 50);
        uint24 expected = _expectedFee(50);
        assertEq(expected, 41_500);
        assertEq(hook.currentFee(poolId), expected);
        Charge memory c = _assertCharged(true, SWAP_AMOUNT, expected);
        assertEq(c.fee, 415);
    }

    function test_decay_lastBlockOfWindowIsStillTaxed() public {
        // The window is half-open: [startTime, startTime + decaySeconds). The final block inside
        // it must still charge strictly more than the post-launch fee.
        vm.warp(START_TIME + DECAY_SECONDS - 1);
        uint24 expected = _expectedFee(DECAY_SECONDS - 1);
        assertEq(expected, 3_770);
        assertGt(expected, FINAL_FEE);
        assertEq(hook.currentFee(poolId), expected);
        Charge memory c = _assertCharged(true, SWAP_AMOUNT, expected);
        assertEq(c.fee, 37, "floor(10_000 * 0.377%)");
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
        assertEq(c.poolQuote, 10_000, "the active bin trades 1:1 and core charges nothing");
        assertEq(c.fee, 800);
        assertEq(c.traderQuote, 9_200);
    }

    /// @dev The schedule on every shape of swap, at the opening rate: the two shapes charged in
    /// `beforeSwap` (on the amount named) and the two charged in `afterSwap` (on the pool's).
    function test_decay_everyShapeIsChargedTheSchedule() public {
        vm.warp(START_TIME);
        Charge memory c = _assertCharged(true, -1 ether, INITIAL_FEE); // buy, exact input
        assertEq(c.fee, 0.08 ether);
        assertEq(c.poolQuote, -0.92 ether, "the pool is handed the amount less the fee");
        assertEq(c.traderToken, 0.92 ether, "and pays out 1:1 for it");
        c = _assertCharged(false, -1 ether, INITIAL_FEE); // sell, exact input
        assertEq(c.fee, 0.08 ether);
        assertEq(c.traderQuote, 0.92 ether);
        c = _assertCharged(true, 1 ether, INITIAL_FEE); // buy, exact output
        assertEq(c.traderToken, 1 ether);
        assertEq(c.traderQuote, -1.08 ether);
        c = _assertCharged(false, 1 ether, INITIAL_FEE); // sell, exact output
        assertEq(c.fee, 0.08 ether);
        assertEq(c.poolQuote, 1.08 ether, "the pool pays out the amount plus the fee");
        assertEq(c.traderQuote, 1 ether);
        assertEq(c.traderToken, -1.08 ether);
    }

    /// @dev Ties the fee to real economics, not just to a counter. At `activeId == 2**23` the bin
    /// price is exactly 1:1 whatever the binStep and core charges no LP fee, so the buyer receives
    /// exactly the quote that was left after the guard's fee.
    function test_decay_isEconomicallyRealNotJustReported() public {
        vm.warp(START_TIME + 50);
        uint256 expectedFee = _expectedFee(50);
        uint256 amountIn = uint256(uint128(-SWAP_AMOUNT));
        uint256 fee = amountIn * expectedFee / 1e6;
        BalanceDelta delta = _swap(key, true, SWAP_AMOUNT);

        assertEq(delta.amount0(), SWAP_AMOUNT, "the buyer pays what it named, fee included");
        assertEq(uint256(int256(delta.amount1())), amountIn - fee);
        assertEq(hook.pendingFee(poolId, currency0), fee);
        assertEq(vault.balanceOf(address(hook), currency0), fee);
    }

    /// @dev The harshest opening fee this hook can impose is an order of magnitude weaker than the
    /// CL hook's. Configured at the ceiling, a block-0 buyer still keeps 90% of the trade; the CL
    /// hook's 50% cap would leave 50%. The ceiling is core's, for the MINT route, which is still
    /// an LP fee; the swap route could carry more but reads the same schedule.
    function test_decay_harshestPossibleOpeningFeeIsTenPercent() public {
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.initialFeeBips = hook.MAX_INITIAL_FEE(); // 100_000 == 10%, core's bin ceiling
        hook.configureLaunch(key, cfg);

        vm.warp(START_TIME);
        Charge memory c = _assertCharged(true, SWAP_AMOUNT, LPFeeLibrary.TEN_PERCENT_FEE);
        assertEq(c.fee, 1_000);
        assertEq(c.traderToken, 9_000, "the buyer keeps 90% of the trade");
    }

    function test_decay_feeIsNeverWrittenToPoolStorage() public {
        vm.warp(START_TIME);
        _swap(key, true, SWAP_AMOUNT);
        (,, uint24 storedLpFee) = poolManager.getSlot0(poolId);
        // Dynamic-fee pools store 0 and the hook never calls updateDynamicLPFee. On a swap the
        // guard's override is zero as well; on a mint the override is the schedule, per call only,
        // which is why EVERY beforeMint path must return one.
        assertEq(storedLpFee, 0);
    }

    /// @dev What `beforeSwap` hands core as the LP fee, read from the callback itself: zero with
    /// the override flag, at the opening, mid-decay and after it. (An exact-input sell is charged
    /// in `afterSwap`, so its `beforeSwap` makes no vault call and can be called outside a lock.)
    /// And what `beforeMint` hands core in the same second: the schedule, flagged.
    /// MUTATION-CHECKED (c): returning the decayed fee as the swap's override fails here and in
    /// every `_assertCharged`.
    function test_beforeSwap_returnsAZeroLpFeeOverride_beforeMintTheSchedule() public {
        IBinPoolManager.MintParams memory mp = _getSingleBinMintParams(ACTIVE_ID, 1 ether, 1 ether);
        uint40[4] memory at = [START_TIME, START_TIME + 50, START_TIME + DECAY_SECONDS, START_TIME + 1 days];
        for (uint256 i; i < at.length; ++i) {
            vm.warp(at[i]);
            vm.prank(address(poolManager));
            (bytes4 selector, BeforeSwapDelta delta, uint24 lpFee) =
                hook.beforeSwap(address(swapHelper), key, false, SWAP_AMOUNT, ZERO_BYTES);
            assertEq(selector, IBinHooks.beforeSwap.selector);
            assertEq(lpFee, LPFeeLibrary.OVERRIDE_FEE_FLAG, "the override flag alone: an LP fee of zero");
            assertEq(BeforeSwapDelta.unwrap(delta), 0, "nothing is taken before a swap charged after it");

            vm.prank(address(poolManager));
            (bytes4 mintSelector, uint24 compositionFee) = hook.beforeMint(address(liquidityHelper), key, mp, ZERO_BYTES);
            assertEq(mintSelector, IBinHooks.beforeMint.selector);
            assertEq(
                compositionFee,
                _expectedFee(uint256(at[i]) - START_TIME) | LPFeeLibrary.OVERRIDE_FEE_FLAG,
                "the schedule, flagged"
            );
        }
        // Before the launch opens a mint is charged the opening fee.
        vm.warp(START_TIME - 60);
        vm.prank(address(poolManager));
        (, uint24 early) = hook.beforeMint(address(liquidityHelper), key, mp, ZERO_BYTES);
        assertEq(early, INITIAL_FEE | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    function test_feeAt_revertsForUnconfiguredPool() public {
        PoolId unknown = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 20).toId();
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.LaunchNotConfigured.selector, unknown));
        hook.feeAt(unknown, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                            DISABLED LAUNCH
    //////////////////////////////////////////////////////////////*/

    function test_disabled_appliesFinalFeeAndNoGate() public {
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
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
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.enabled = false;
        cfg.finalFeeBips = 500;
        hook.configureLaunch(key, cfg);

        vm.warp(START_TIME - 1);
        Charge memory c = _assertCharged(true, SWAP_AMOUNT, 500);
        assertEq(c.fee, 5, "0.05% of 10_000");
    }

    /*//////////////////////////////////////////////////////////////
             THE MINT ROUTE — BIN ONLY, AND THE REASON THIS
             HOOK IS NOT A LINE-FOR-LINE PORT OF THE CL ONE

        Adding liquidity to the ACTIVE bin at a ratio other than the
        bin's own is an implicit swap inside core, priced at the
        composition fee. If the hook does not override that fee, a
        dynamic-fee pool charges its STORED fee, which is zero.
    //////////////////////////////////////////////////////////////*/

    /// @dev The hole, demonstrated. Same hook code, same configuration, the ONLY difference is that
    /// the naive variant declares the CL permission set and therefore never gets asked for a fee on
    /// mint. Its composition fee is zero: a completely free swap around the launch tax, available
    /// even before `startTime`, when its own `beforeSwap` still reverts.
    function test_mint_naivePortWithoutBeforeMintLeavesAFreeSwapRoute() public {
        NaiveBinLaunchGuardHook naive = new NaiveBinLaunchGuardHook(poolManager);
        assertEq(naive.getHooksRegistrationBitmap(), uint16(65)); // exactly the CL hook's bitmap

        PoolKey memory k = _key(naive, LPFeeLibrary.DYNAMIC_FEE_FLAG, BIN_STEP);
        naive.configureLaunch(k, _defaultConfig());
        naive.configureFeeSplit(k, _defaultFeeSplit());
        poolManager.initialize(k, ACTIVE_ID);
        liquidityHelper.mint(k, _getSingleBinMintParams(ACTIVE_ID, 100 ether, 100 ether), ZERO_BYTES);

        // Trading is shut...
        vm.warp(START_TIME - 1);
        _expectHookRevert(
            address(naive),
            IBinHooks.beforeSwap.selector,
            abi.encodeWithSelector(
                BinLaunchGuardHook.TradingNotOpen.selector, k.toId(), uint256(START_TIME), uint256(START_TIME - 1)
            )
        );
        _swap(k, true, SWAP_AMOUNT);

        // ...but the mint route is wide open AND free.
        (uint128 feeX, uint128 feeY) = _lopsidedMintAndReadCompositionFee(k, 1 ether);
        assertEq(feeX, 0, "naive port charged a composition fee");
        assertEq(feeY, 0, "naive port charged a composition fee");
    }

    /// @dev The fix. Same scenario against the real hook: the composition fee is non-zero, and it
    /// is the decayed fee from the schedule.
    function test_mint_compositionSwapIsTaxed() public {
        vm.warp(START_TIME);
        (uint128 feeX, uint128 feeY) = _lopsidedMintAndReadCompositionFee(key, 1 ether);
        assertGt(feeX, 0, "composition swap went untaxed");
        assertEq(feeY, 0, "fee should be charged on the X side that was implicitly swapped");
    }

    /// @dev And it is EXACTLY the guard's fee: a hook-less pool with a STATIC LP fee equal to the
    /// schedule's value charges the same lopsided mint the same composition fee, to the wei. The
    /// mint route is the one place the schedule is still an LP fee, paid to liquidity providers in
    /// the token added; it never reaches the guard's ledger.
    function test_mint_compositionFeeIsExactlyTheGuardsFee() public {
        PoolKey memory control = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(0)),
            poolManager: poolManager,
            fee: INITIAL_FEE, // static, and equal to the schedule at the open
            parameters: bytes32(0).setBinStep(BIN_STEP)
        });
        poolManager.initialize(control, ACTIVE_ID);
        liquidityHelper.mint(control, _getSingleBinMintParams(ACTIVE_ID, 100 ether, 100 ether), ZERO_BYTES);

        vm.warp(START_TIME);
        (uint128 feeX, uint128 feeY) = _lopsidedMintAndReadCompositionFee(key, 1 ether);
        (uint128 controlX, uint128 controlY) = _lopsidedMintAndReadCompositionFee(control, 1 ether);
        assertGt(feeX, 0);
        assertEq(feeX, controlX, "composition fee != the schedule's, as an LP fee");
        assertEq(feeY, controlY);

        assertEq(hook.grossTaken(currency0) + hook.grossTaken(currency1), 0, "a mint pays the pool, not the guard");
        assertEq(vault.balanceOf(address(hook), currency0) + vault.balanceOf(address(hook), currency1), 0);
    }

    /// @dev The mint tax follows the same schedule as the swap tax, so neither route is cheaper.
    /// @dev Two IDENTICAL pools are used rather than two mints into one, because the first lopsided
    /// mint rebalances the active bin and would change the size of the second implicit swap. The
    /// only difference between the measurements is therefore the block, i.e. the schedule.
    function test_mint_compositionFeeDecaysWithTheSchedule() public {
        PoolKey memory poolA = _freshGuardedPool(30);
        PoolKey memory poolB = _freshGuardedPool(31);

        vm.warp(START_TIME);
        (uint128 feeAtOpen,) = _lopsidedMintAndReadCompositionFee(poolA, 1 ether);

        vm.warp(START_TIME + DECAY_SECONDS);
        (uint128 feeAfterWindow,) = _lopsidedMintAndReadCompositionFee(poolB, 1 ether);

        assertGt(feeAtOpen, feeAfterWindow, "mint tax did not decay");
        // The composition fee is monotonic in the LP fee, and the schedule falls from 8% to 0.3%,
        // so the opening charge must be many times the settled one.
        assertGt(feeAtOpen, feeAfterWindow * 10, "mint tax decayed by the wrong amount");
    }

    /// @dev Seeding is not penalised: a ratio-matched add charges no composition fee at all, so the
    /// launcher can seed the pool at any block despite the mint tax being live from block one.
    function test_mint_balancedSeedingIsUntaxed() public {
        vm.warp(START_TIME); // tax at its maximum
        vm.recordLogs();
        liquidityHelper.mint(key, _getSingleBinMintParams(ACTIVE_ID, 10 ether, 10 ether), ZERO_BYTES);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(poolManager) && logs[i].topics[0] == IBinPoolManager.Mint.selector) {
                (,,, bytes32 compositionFee,) =
                    abi.decode(logs[i].data, (uint256[], bytes32, bytes32[], bytes32, bytes32));
                assertEq(compositionFee.decodeX(), 0);
                assertEq(compositionFee.decodeY(), 0);
                return;
            }
        }
        revert("Mint event not found");
    }

    /// @dev RESIDUAL RISK, DELIBERATELY CAPTURED AND NOT FIXED. Mints are taxed, not gated. They
    /// have to be: `sender` is the router, so the hook cannot tell the launcher seeding the pool
    /// from a sniper extracting from it. A sniper can therefore acquire the launch token before
    /// `startTime` by minting lopsided and burning - paying `initialFeeBips` on the way, but
    /// bypassing the trading gate that stops ordinary swaps in the same block.
    function test_mint_isTaxedButNotGatedBeforeStartBlock_residualRisk() public {
        vm.warp(START_TIME - 1);

        // A swap in this block is impossible.
        _expectHookRevert(
            address(hook),
            IBinHooks.beforeSwap.selector,
            abi.encodeWithSelector(
                BinLaunchGuardHook.TradingNotOpen.selector, poolId, uint256(START_TIME), uint256(START_TIME - 1)
            )
        );
        _swap(key, true, SWAP_AMOUNT);

        // A composition swap in the same block is not, but it is charged the OPENING rate.
        assertEq(hook.currentFee(poolId), INITIAL_FEE);
        (uint128 feeX,) = _lopsidedMintAndReadCompositionFee(key, 1 ether);
        assertGt(feeX, 0, "pre-launch mint route was free");
    }

    function test_mint_disabledLaunchStillOverridesCompositionFee() public {
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.enabled = false;
        hook.configureLaunch(key, cfg);

        vm.warp(START_TIME - 1);
        (uint128 feeX,) = _lopsidedMintAndReadCompositionFee(key, 1 ether);
        assertGt(feeX, 0, "disabled launch left the mint route fee-free");
    }

    /*//////////////////////////////////////////////////////////////
                       PER-TRANSACTION BUY CAP

        NOTE: this is a per-TRANSACTION cap on the SWAP path and
        nothing more. See `test_maxBuy_doesNotStopSplittingAcross-
        Transactions` and `test_maxBuy_doesNotConstrainTheMintRoute`.
    //////////////////////////////////////////////////////////////*/

    function _configureWithCap(uint128 cap) internal {
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.maxBuyPerTx = cap;
        hook.configureLaunch(key, cfg);
    }

    function test_maxBuy_allowsBuyAtExactlyTheCap() public {
        _configureWithCap(5_000);
        vm.warp(START_TIME);
        Charge memory c = _assertCharged(true, -5_000, INITIAL_FEE); // exactly at the cap
        assertEq(c.poolQuote, -4_600, "of which 4_600 reached the pool");
    }

    /// @dev THE CAP IS ON WHAT THE TRADER SENDS, before the guard's take. A buy of 5_001 hands the
    /// pool only 4_601 at the opening fee, under the cap of 5_000, and is refused all the same; so
    /// is every larger buy whose net would still fit. The amount reported is the gross.
    /// MUTATION-CHECKED (e): checking the cap against the net amount lets all three through.
    function test_maxBuy_isCheckedOnTheGrossAmountBeforeTheTake() public {
        _configureWithCap(5_000);
        vm.warp(START_TIME);
        uint256[3] memory gross = [uint256(5_001), 5_200, 5_434]; // net of 8%: 4_601, 4_784, 5_000
        for (uint256 i; i < gross.length; ++i) {
            assertLe(gross[i] - gross[i] * INITIAL_FEE / 1_000_000, 5_000, "the net would have fitted");
            _expectHookRevert(
                address(hook),
                IBinHooks.beforeSwap.selector,
                abi.encodeWithSelector(BinLaunchGuardHook.BuyExceedsMaxPerTx.selector, gross[i], uint128(5_000))
            );
            // forge-lint: disable-next-line(unsafe-typecast)
            _swap(key, true, -int128(uint128(gross[i])));
        }
        assertEq(hook.grossTaken(currency0), 0, "a refused buy is charged nothing");
    }

    /// @dev The same with a creator tax on top: at both caps the pool receives 80% of a buy, and
    /// the cap still counts all of it.
    function test_maxBuy_isCheckedOnTheGrossAmountWithATaxLive() public {
        // A pool seeded either side of the active bin, which a live tax closes to mints.
        PoolKey memory k = _key(hook, LPFeeLibrary.DYNAMIC_FEE_FLAG, 40);
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.maxBuyPerTx = 5_000;
        cfg.initialFeeBips = hook.MAX_INITIAL_FEE();
        hook.configureLaunch(k, cfg);
        hook.configureFeeSplit(k, _defaultFeeSplit());
        hook.configureTax(
            k,
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
        poolManager.initialize(k, ACTIVE_ID);
        (IBinPoolManager.MintParams memory around,) = _getMultipleBinMintParams(ACTIVE_ID - 2, 0, 100 ether, 0, 2);
        liquidityHelper.mint(k, around, ZERO_BYTES);
        vm.warp(START_TIME);

        _expectHookRevert(
            address(hook),
            IBinHooks.beforeSwap.selector,
            abi.encodeWithSelector(BinLaunchGuardHook.BuyExceedsMaxPerTx.selector, uint256(5_001), uint128(5_000))
        );
        _swap(k, true, -5_001); // 4_001 would have reached the pool

        uint256 quoteBefore = token0.balanceOf(address(this));
        _swap(k, true, -5_000);
        assertEq(quoteBefore - token0.balanceOf(address(this)), 5_000);
        assertEq(hook.pendingFee(k.toId(), currency0), 500);
        assertEq(hook.pendingTax(k.toId(), currency0), 500);
        assertEq(vault.balanceOf(address(hook), currency1), 0);
    }

    function test_maxBuy_rejectsBuyOneWeiOverTheCap() public {
        _configureWithCap(5_000);
        vm.warp(START_TIME);
        _expectHookRevert(
            address(hook),
            IBinHooks.beforeSwap.selector,
            abi.encodeWithSelector(BinLaunchGuardHook.BuyExceedsMaxPerTx.selector, uint256(5_001), uint128(5_000))
        );
        _swap(key, true, -5_001);
    }

    function test_maxBuy_doesNotConstrainSells() public {
        _configureWithCap(5_000);
        vm.warp(START_TIME);
        // currency1 (Y) is the launch token, so a Y-for-X swap is a SELL and is uncapped by design.
        _assertCharged(false, -50_000, INITIAL_FEE);
        // However large, and whichever side of the sell is named.
        _assertCharged(false, -1 ether, INITIAL_FEE);
        _assertCharged(false, 1 ether, INITIAL_FEE);
    }

    function test_maxBuy_directionFollowsLaunchTokenSide() public {
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.maxBuyPerTx = 5_000;
        cfg.launchTokenIsCurrency0 = true; // now the Y-for-X direction is the buy
        hook.configureLaunch(key, cfg);
        vm.warp(START_TIME);

        _swap(key, true, -50_000); // swapForY is now a sell: uncapped

        _expectHookRevert(
            address(hook),
            IBinHooks.beforeSwap.selector,
            abi.encodeWithSelector(BinLaunchGuardHook.BuyExceedsMaxPerTx.selector, uint256(5_001), uint128(5_000))
        );
        _swap(key, false, -5_001);
    }

    function test_maxBuy_blocksExactOutputBuysWhileCapIsLive() public {
        _configureWithCap(5_000);
        vm.warp(START_TIME);
        _expectHookRevert(
            address(hook),
            IBinHooks.beforeSwap.selector,
            abi.encodeWithSelector(BinLaunchGuardHook.ExactOutputBuyBlockedDuringLaunch.selector)
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
    /// size.
    function test_maxBuy_blocksExactOutputBuysToTheLastSecondOfTheWindow() public {
        _configureWithCap(5_000);
        vm.warp(START_TIME + DECAY_SECONDS - 1);
        _expectHookRevert(
            address(hook),
            IBinHooks.beforeSwap.selector,
            abi.encodeWithSelector(BinLaunchGuardHook.ExactOutputBuyBlockedDuringLaunch.selector)
        );
        _swap(key, true, 1);
        _expectHookRevert(
            address(hook),
            IBinHooks.beforeSwap.selector,
            abi.encodeWithSelector(BinLaunchGuardHook.BuyExceedsMaxPerTx.selector, uint256(5_001), uint128(5_000))
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
            token0.mint(buyer, 1 ether);
            _approveAll(buyer);
            vm.prank(buyer);
            _swap(key, true, -5_000);
        }
        assertEq(block.timestamp, START_TIME); // all in one block
    }

    /// @dev And the cap does not reach the mint route at all: `beforeMint` sees `liquidityConfigs`
    /// and a packed `amountIn`, not the size of the implicit swap core will compute from the bin's
    /// live reserves. A capped buyer can move far more than the cap through mint+burn, paying only
    /// the composition fee. Bin-specific, and not removable at this layer.
    function test_maxBuy_doesNotConstrainTheMintRoute() public {
        _configureWithCap(5_000);
        vm.warp(START_TIME);

        _expectHookRevert(
            address(hook),
            IBinHooks.beforeSwap.selector,
            abi.encodeWithSelector(BinLaunchGuardHook.BuyExceedsMaxPerTx.selector, uint256(1 ether), uint128(5_000))
        );
        _swap(key, true, -1 ether);

        // The same size goes through the mint route without touching the cap.
        (uint128 feeX,) = _lopsidedMintAndReadCompositionFee(key, 1 ether);
        assertGt(feeX, 0); // taxed, but not capped
    }

    /*//////////////////////////////////////////////////////////////
                          onlyPoolManager GUARD
    //////////////////////////////////////////////////////////////*/

    function test_onlyPoolManager_beforeSwapIsUnreachableDirectly() public {
        vm.warp(START_TIME);
        vm.expectRevert(BaseBinHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, true, SWAP_AMOUNT, ZERO_BYTES);
    }

    function test_onlyPoolManager_beforeMintIsUnreachableDirectly() public {
        vm.expectRevert(BaseBinHook.NotPoolManager.selector);
        hook.beforeMint(address(this), key, _getSingleBinMintParams(ACTIVE_ID, 1 ether, 1 ether), ZERO_BYTES);
    }

    function test_onlyPoolManager_beforeInitializeIsUnreachableDirectly() public {
        vm.expectRevert(BaseBinHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, ACTIVE_ID);
    }

    function test_onlyPoolManager_alsoBlocksTheLaunchOwner() public {
        // The gate is on the caller, not on privilege: even the launch owner cannot fake a swap
        // and flip the `launched` flag or drive the hook's accounting.
        vm.warp(START_TIME);
        assertEq(hook.launchOwner(poolId), address(this));
        vm.expectRevert(BaseBinHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, true, SWAP_AMOUNT, ZERO_BYTES);
        assertFalse(hook.getLaunch(poolId).launched);
    }

    /// @dev The guard runs BEFORE the not-implemented check, so an outsider learns nothing about
    /// which callbacks a hook implements, and cannot reach unimplemented ones either.
    function test_onlyPoolManager_unimplementedCallbacksStillRevertForOutsiders() public {
        IBinPoolManager.BurnParams memory bp =
            _getSingleBinBurnLiquidityParams(key, poolManager, ACTIVE_ID, address(this), 100);

        vm.expectRevert(BaseBinHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, ACTIVE_ID);
        vm.expectRevert(BaseBinHook.NotPoolManager.selector);
        hook.beforeBurn(address(this), key, bp, ZERO_BYTES);
        vm.expectRevert(BaseBinHook.NotPoolManager.selector);
        hook.afterBurn(address(this), key, bp, BalanceDelta.wrap(0), ZERO_BYTES);
        vm.expectRevert(BaseBinHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, true, SWAP_AMOUNT, BalanceDelta.wrap(0), ZERO_BYTES);
        vm.expectRevert(BaseBinHook.NotPoolManager.selector);
        hook.beforeDonate(address(this), key, 1, 1, ZERO_BYTES);
        vm.expectRevert(BaseBinHook.NotPoolManager.selector);
        hook.afterDonate(address(this), key, 1, 1, ZERO_BYTES);
    }

    /*//////////////////////////////////////////////////////////////
        THE `sender` CONSTRAINT — CAPTURED IN THE SUITE ON PURPOSE

        `BinHooks.beforeSwap` calls the hook with `msg.sender` of `BinPoolManager.swap`, which is
        whoever locked the Vault: the ROUTER. It is never the buyer. Any per-wallet rule keyed on
        this argument would be consumed by the first buyer on everyone's behalf, which is why this
        hook taxes time instead of identity. `BinHooks.beforeMint` behaves identically.
    //////////////////////////////////////////////////////////////*/

    function _deploySpyPool() internal returns (SenderRecordingBinLaunchGuardHook spy, PoolKey memory k) {
        spy = new SenderRecordingBinLaunchGuardHook(poolManager);
        k = _key(spy, LPFeeLibrary.DYNAMIC_FEE_FLAG, BIN_STEP);
        spy.configureLaunch(k, _defaultConfig());
        spy.configureFeeSplit(k, _defaultFeeSplit());
        poolManager.initialize(k, ACTIVE_ID);
        liquidityHelper.mint(k, _getSingleBinMintParams(ACTIVE_ID, 100 ether, 100 ether), ZERO_BYTES);
    }

    function test_sender_isTheLockerNotTheBuyer() public {
        (SenderRecordingBinLaunchGuardHook spy, PoolKey memory k) = _deploySpyPool();

        vm.warp(START_TIME);

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        token0.mint(alice, 1 ether);
        token0.mint(bob, 1 ether);
        _approveAll(alice);
        _approveAll(bob);

        vm.prank(alice);
        _swap(k, true, SWAP_AMOUNT);
        address senderSeenForAlice = spy.lastSwapSender();

        vm.prank(bob);
        _swap(k, true, SWAP_AMOUNT);
        address senderSeenForBob = spy.lastSwapSender();

        assertEq(spy.swapCount(), 2);

        // The hook saw the router both times, never the buyer.
        assertEq(senderSeenForAlice, address(swapHelper));
        assertEq(senderSeenForBob, address(swapHelper));
        assertEq(senderSeenForAlice, senderSeenForBob);
        assertTrue(senderSeenForAlice != alice);
        assertTrue(senderSeenForBob != bob);
    }

    /// @dev Second half of the same constraint: a caller who bypasses the router and locks the
    /// Vault himself presents whatever `sender` he likes (his own contract) and whatever
    /// `hookData` he likes. Neither can be used as an identity.
    function test_sender_aSecondRouterPresentsADifferentSenderEntirely() public {
        (SenderRecordingBinLaunchGuardHook spy, PoolKey memory k) = _deploySpyPool();

        BinSwapHelper rogue = new BinSwapHelper(poolManager, vault);
        token0.approve(address(rogue), type(uint256).max);
        token1.approve(address(rogue), type(uint256).max);

        vm.warp(START_TIME);

        _swap(k, true, SWAP_AMOUNT);
        assertEq(spy.lastSwapSender(), address(swapHelper));

        rogue.swap(
            k,
            true,
            SWAP_AMOUNT,
            BinSwapHelper.TestSettings(true, true),
            // arbitrary attacker-chosen hookData naming a victim: unverifiable, hence unused
            abi.encode(makeAddr("someVictim"))
        );
        assertEq(spy.lastSwapSender(), address(rogue));
    }

    /// @dev The bin-specific half: the mint callback has the same blindness, which is precisely why
    /// mints cannot be gated to the launcher and must be taxed instead.
    function test_sender_mintCallbackAlsoSeesTheLockerNotTheMinter() public {
        (SenderRecordingBinLaunchGuardHook spy, PoolKey memory k) = _deploySpyPool();

        address carol = makeAddr("carol");
        token0.mint(carol, 10 ether);
        token1.mint(carol, 10 ether);
        _approveAll(carol);

        vm.prank(carol);
        liquidityHelper.mint(k, _getSingleBinMintParams(ACTIVE_ID, 1 ether, 1 ether), ZERO_BYTES);

        assertEq(spy.lastMintSender(), address(liquidityHelper));
        assertTrue(spy.lastMintSender() != carol);
    }

    /*//////////////////////////////////////////////////////////////
                                 FUZZ
    //////////////////////////////////////////////////////////////*/

    /// @dev Reconfigures the pool's schedule and returns the (frozen) start block. Safe to call
    /// repeatedly because the fuzz tests never roll past `START_TIME` before configuring.
    function _fuzzConfigure(uint24 initialFee, uint24 finalFee, uint32 decaySeconds)
        internal
        returns (uint24, uint24, uint32)
    {
        finalFee = uint24(bound(finalFee, 0, hook.MAX_FINAL_FEE()));
        initialFee = uint24(bound(initialFee, finalFee, hook.MAX_INITIAL_FEE()));
        decaySeconds = uint32(bound(decaySeconds, hook.MIN_DECAY_SECONDS(), hook.MAX_DECAY_SECONDS()));

        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
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
            // Never exceeds what core will accept for a BIN pool - one tenth of the CL ceiling.
            assertLe(fee, LPFeeLibrary.TEN_PERCENT_FEE, "fee above core's bin max");
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
        bool swapForY,
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

        // forge-lint: disable-next-line(unsafe-typecast)
        int128 specified = exactIn ? -int128(uint128(amount)) : int128(uint128(amount));
        Charge memory c = _assertCharged(swapForY, specified, expected);
        assertLe(c.fee, c.base / 10, "never more than the 10% cap");
    }

    /// @dev The mint route reads the SAME schedule as the swap route at every block, so there is
    /// never a block in which minting is the cheaper way through the tax.
    function testFuzz_mintAndSwapReadTheSameSchedule(
        uint24 initialFee,
        uint24 finalFee,
        uint32 decaySeconds,
        uint16 elapsed
    ) public {
        decaySeconds = uint32(bound(decaySeconds, hook.MIN_DECAY_SECONDS(), 5_000));
        (initialFee, finalFee, decaySeconds) = _fuzzConfigure(initialFee, finalFee, decaySeconds);

        uint256 offset = bound(elapsed, 0, uint256(decaySeconds) + 10);
        vm.warp(uint256(START_TIME) + offset);

        uint24 scheduled = hook.currentFee(poolId);

        // The swap path is charged exactly `scheduled` by the guard...
        _assertCharged(true, SWAP_AMOUNT, scheduled);

        // ...and the mint path is non-zero whenever `scheduled` is, i.e. the composition route is
        // never free while swaps are taxed.
        (uint128 feeX,) = _lopsidedMintAndReadCompositionFee(key, 1 ether);
        if (scheduled > 0) assertGt(feeX, 0, "mint route free while swaps are taxed");
        assertLe(scheduled, LPFeeLibrary.TEN_PERCENT_FEE);
        assertLe(initialFee, LPFeeLibrary.TEN_PERCENT_FEE);
        assertLe(finalFee, scheduled);
    }

    /*//////////////////////////////////////////////////////////////
       THE CLOCK IS block.timestamp NOW, AND ONLY block.timestamp

       Same migration as `LaunchGuardHook`. This hook was never deployed, so it
       moves with the CL hook rather than being left as the one DeepCore contract
       whose windows still depend on a declared block time.

       FAILING-FIRST: every `test_CLOCK_*` below fails against the block-numbered
       source, where `vm.roll` opened trading and `vm.warp` did nothing.
    //////////////////////////////////////////////////////////////*/

    function test_CLOCK_modeIsTimestamp() public {
        assertEq(hook.CLOCK_MODE(), "mode=timestamp");
        vm.warp(1_790_000_000);
        assertEq(hook.clock(), 1_790_000_000);
    }

    function test_CLOCK_blocksAloneNeverOpenTrading() public {
        vm.roll(block.number + 100_000_000);
        assertLt(block.timestamp, START_TIME);
        _expectHookRevert(
            address(hook),
            IBinHooks.beforeSwap.selector,
            abi.encodeWithSelector(BinLaunchGuardHook.TradingNotOpen.selector, poolId, uint256(START_TIME), block.timestamp)
        );
        _swap(key, true, SWAP_AMOUNT);
    }

    /// @dev The mint route prices off the same clock: rolling blocks before the open must leave
    /// the composition fee at `initialFeeBips`, and warping past the window must drop it.
    function test_CLOCK_mintRouteFollowsTimeNotBlocks() public {
        vm.roll(block.number + 100_000_000);
        assertEq(hook.currentFee(poolId), INITIAL_FEE);
        vm.warp(START_TIME + DECAY_SECONDS);
        assertEq(hook.currentFee(poolId), FINAL_FEE);
    }

    function test_CLOCK_timeAloneOpensTrading() public {
        uint256 blockBefore = block.number;
        vm.warp(START_TIME);
        assertEq(block.number, blockBefore, "no block was rolled");
        _assertCharged(true, SWAP_AMOUNT, INITIAL_FEE);
    }

    /*//////////////////////////////////////////////////////////////
       MINIMUM WINDOW AND THE "NO PERMANENT TAX" ENVELOPE
    //////////////////////////////////////////////////////////////*/

    function test_MINWINDOW_floorMatchesTheCLHook() public view {
        assertEq(hook.MIN_DECAY_SECONDS(), 60);
        assertEq(hook.MAX_DECAY_SECONDS(), 30 days);
        assertEq(uint256(hook.MAX_START_DELAY_SECONDS()), 30 days);
        assertGe(uint256(hook.MAX_DECAY_SECONDS()), hook.MIN_LAUNCH_WINDOW_SECONDS());
        assertLe(
            uint256(hook.MAX_START_DELAY_SECONDS()) + hook.MAX_DECAY_SECONDS(), hook.MAX_LAUNCH_WINDOW_SECONDS()
        );
    }

    /// @dev MUTATION-CHECKED alongside the CL hook's floor.
    function test_MINWINDOW_rejectsOneSecondBelowTheFloor() public {
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.decaySeconds = hook.MIN_DECAY_SECONDS() - 1;
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.InvalidDecaySeconds.selector, uint32(59)));
        hook.configureLaunch(key, cfg);

        cfg.decaySeconds = hook.MIN_DECAY_SECONDS();
        hook.configureLaunch(key, cfg);
        assertEq(hook.getLaunch(poolId).decaySeconds, 60);
    }

    function test_MINWINDOW_appliesToDisabledLaunchesToo() public {
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.enabled = false;
        cfg.decaySeconds = 1;
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.InvalidDecaySeconds.selector, uint32(1)));
        hook.configureLaunch(key, cfg);
    }

    function test_ENVELOPE_worstCaseTaxIsGoneWithinSixtyDays() public {
        uint256 t = block.timestamp;
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.startTime = uint40(t + hook.MAX_START_DELAY_SECONDS());
        cfg.decaySeconds = hook.MAX_DECAY_SECONDS();
        hook.configureLaunch(key, cfg);
        vm.warp(t + 60 days);
        assertEq(hook.currentFee(poolId), FINAL_FEE);
    }

    /*//////////////////////////////////////////////////////////////
       POOL-ID RESERVATION (ported from LaunchGuardHook, 2026-09-14)

       Closes the open LOW "the CL guard reserves launch pools, the Bin guard
       does not". FAILING-FIRST: against the pre-port hook every front-runner
       below claimed the pool and the kit's own claim reverted NotLaunchOwner.
       MUTATION-CHECKED: deleting the two `_requireMayClaim` calls in
       `configureLaunch` turns test_RESERVE_frontRunnerCannotClaimAFactoryTokenPool,
       test_RESERVE_creatorMayDelegateTheClaimToAKit, test_RESERVE_claimerCanBeRevoked,
       test_RESERVE_noClaimOnACurrencyWithoutCode and
       test_RESERVE_noCodeRuleHoldsWithoutAFactory red (run 2026-09-14: 5 failed).
    //////////////////////////////////////////////////////////////*/

    address constant KIT = address(0x6B17);
    address constant CREATOR = address(0xC4EA);
    address constant FRONT_RUNNER = address(0xF4A7);

    function _reservingHook()
        internal
        returns (BinLaunchGuardHook rh, MockBinLaunchTokenOrigin origin, PoolKey memory k)
    {
        origin = new MockBinLaunchTokenOrigin();
        rh = new BinLaunchGuardHook(poolManager, ILaunchTokenOrigin(address(origin)), TAX_PROTOCOL, 0);
        k = _key(rh, LPFeeLibrary.DYNAMIC_FEE_FLAG, BIN_STEP);
    }

    function test_RESERVE_bitmapUnchangedByThePort() public {
        (BinLaunchGuardHook rh,,) = _reservingHook();
        assertEq(
            rh.getHooksRegistrationBitmap(),
            0x0CC5,
            "beforeInitialize | beforeMint | beforeSwap | afterSwap | beforeSwapReturnsDelta | afterSwapReturnsDelta"
        );
        assertEq(rh.getHooksRegistrationBitmap(), hook.getHooksRegistrationBitmap());
    }

    function test_RESERVE_frontRunnerCannotClaimAFactoryTokenPool() public {
        (BinLaunchGuardHook rh, MockBinLaunchTokenOrigin origin, PoolKey memory k) = _reservingHook();
        address token = Currency.unwrap(k.currency1);
        origin.set(token, KIT); // the kit created the launch token

        vm.prank(FRONT_RUNNER);
        vm.expectRevert(
            abi.encodeWithSelector(BinLaunchGuardHook.LaunchPoolReserved.selector, token, KIT, FRONT_RUNNER)
        );
        rh.configureLaunch(k, _defaultConfig());
        assertEq(rh.launchOwner(k.toId()), address(0), "nobody claimed it");

        // ...and without a claim nobody can initialize it either.
        _expectHookRevert(
            address(rh),
            IBinHooks.beforeInitialize.selector,
            abi.encodeWithSelector(BinLaunchGuardHook.LaunchNotConfigured.selector, k.toId())
        );
        vm.prank(FRONT_RUNNER);
        poolManager.initialize(k, ACTIVE_ID);

        // Nor can the front-runner write the fee split of a pool it could not claim.
        vm.prank(FRONT_RUNNER);
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.LaunchNotConfigured.selector, k.toId()));
        rh.configureFeeSplit(k, _defaultFeeSplit());

        // The kit path succeeds: claim, split, initialize.
        vm.prank(KIT);
        rh.configureLaunch(k, _defaultConfig());
        assertEq(rh.launchOwner(k.toId()), KIT);
        vm.prank(FRONT_RUNNER);
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.NotLaunchOwner.selector, k.toId(), FRONT_RUNNER));
        rh.configureFeeSplit(k, _defaultFeeSplit());
        vm.prank(KIT);
        rh.configureFeeSplit(k, _defaultFeeSplit());
        poolManager.initialize(k, ACTIVE_ID);
    }

    function test_RESERVE_creatorMayDelegateTheClaimToAKit() public {
        (BinLaunchGuardHook rh, MockBinLaunchTokenOrigin origin, PoolKey memory k) = _reservingHook();
        address token = Currency.unwrap(k.currency0);
        origin.set(token, CREATOR);

        vm.prank(KIT);
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.LaunchPoolReserved.selector, token, CREATOR, KIT));
        rh.configureLaunch(k, _defaultConfig());

        vm.prank(FRONT_RUNNER);
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.NotTokenCreator.selector, token, FRONT_RUNNER));
        rh.setLaunchClaimer(token, FRONT_RUNNER);

        vm.prank(CREATOR);
        rh.setLaunchClaimer(token, KIT);
        assertEq(rh.launchClaimerOf(token), KIT);

        vm.prank(FRONT_RUNNER);
        vm.expectRevert(
            abi.encodeWithSelector(BinLaunchGuardHook.LaunchPoolReserved.selector, token, CREATOR, FRONT_RUNNER)
        );
        rh.configureLaunch(k, _defaultConfig());

        vm.prank(KIT);
        rh.configureLaunch(k, _defaultConfig());
        assertEq(rh.launchOwner(k.toId()), KIT);
    }

    function test_RESERVE_claimerCanBeRevoked() public {
        (BinLaunchGuardHook rh, MockBinLaunchTokenOrigin origin, PoolKey memory k) = _reservingHook();
        address token = Currency.unwrap(k.currency0);
        origin.set(token, CREATOR);
        vm.startPrank(CREATOR);
        rh.setLaunchClaimer(token, KIT);
        rh.setLaunchClaimer(token, address(0));
        vm.stopPrank();
        vm.prank(KIT);
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.LaunchPoolReserved.selector, token, CREATOR, KIT));
        rh.configureLaunch(k, _defaultConfig());
    }

    function test_RESERVE_creatorItselfMayClaim() public {
        (BinLaunchGuardHook rh, MockBinLaunchTokenOrigin origin, PoolKey memory k) = _reservingHook();
        origin.set(Currency.unwrap(k.currency1), CREATOR);
        vm.prank(CREATOR);
        rh.configureLaunch(k, _defaultConfig());
        assertEq(rh.launchOwner(k.toId()), CREATOR);
    }

    /// @dev Rule 1: a token that does not exist YET cannot have its pool squatted.
    function test_RESERVE_noClaimOnACurrencyWithoutCode() public {
        (BinLaunchGuardHook rh,, PoolKey memory k) = _reservingHook();
        address notYetDeployed = address(uint160(0xDEAD0001));
        k.currency1 = Currency.wrap(notYetDeployed);
        vm.prank(FRONT_RUNNER);
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.CurrencyHasNoCode.selector, notYetDeployed));
        rh.configureLaunch(k, _defaultConfig());
    }

    /// @dev Rule 1 applies on the hook with no factory too - it needs no factory to be meaningful.
    function test_RESERVE_noCodeRuleHoldsWithoutAFactory() public {
        BinLaunchGuardHook plain = new BinLaunchGuardHook(poolManager, ILaunchTokenOrigin(address(0)), TAX_PROTOCOL, 0);
        PoolKey memory k = _key(plain, LPFeeLibrary.DYNAMIC_FEE_FLAG, BIN_STEP);
        address notYetDeployed = address(uint160(0xDEAD0002));
        k.currency1 = Currency.wrap(notYetDeployed);
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.CurrencyHasNoCode.selector, notYetDeployed));
        plain.configureLaunch(k, _defaultConfig());
    }

    /// @dev Non-factory tokens: first claim, exactly as before - including on the hook with no factory.
    function test_RESERVE_nonFactoryPoolsAreUnaffected() public {
        (BinLaunchGuardHook rh,, PoolKey memory k) = _reservingHook();
        vm.prank(FRONT_RUNNER);
        rh.configureLaunch(k, _defaultConfig());
        assertEq(rh.launchOwner(k.toId()), FRONT_RUNNER, "first claim, as before");

        BinLaunchGuardHook plain = new BinLaunchGuardHook(poolManager, ILaunchTokenOrigin(address(0)), TAX_PROTOCOL, 0);
        PoolKey memory pk = _key(plain, LPFeeLibrary.DYNAMIC_FEE_FLAG, BIN_STEP);
        vm.prank(FRONT_RUNNER);
        plain.configureLaunch(pk, _defaultConfig());
        assertEq(plain.launchOwner(pk.toId()), FRONT_RUNNER);
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.NotTokenCreator.selector, address(1), address(this)));
        plain.setLaunchClaimer(address(1), KIT);
    }

    /// @dev The native asset is never "a currency without code".
    function test_RESERVE_nativeQuoteIsAllowed() public {
        (BinLaunchGuardHook rh,, PoolKey memory k) = _reservingHook();
        k.currency0 = Currency.wrap(address(0));
        rh.configureLaunch(k, _defaultConfig());
        assertEq(rh.launchOwner(k.toId()), address(this));
    }

    /// @dev Reconfiguration by the owner is not a first claim, so the reservation never locks an
    /// owner out of its own pool (e.g. after the creator revokes the claimer it used).
    function test_RESERVE_ownerReconfigurationIsNotReChecked() public {
        (BinLaunchGuardHook rh, MockBinLaunchTokenOrigin origin, PoolKey memory k) = _reservingHook();
        address token = Currency.unwrap(k.currency0);
        origin.set(token, CREATOR);
        vm.prank(CREATOR);
        rh.setLaunchClaimer(token, KIT);
        vm.prank(KIT);
        rh.configureLaunch(k, _defaultConfig());
        vm.prank(CREATOR);
        rh.setLaunchClaimer(token, address(0));
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.decaySeconds = 120;
        vm.prank(KIT);
        rh.configureLaunch(k, cfg);
        assertEq(rh.getLaunch(k.toId()).decaySeconds, 120);
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
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.enabled = false;
        hook.configureLaunch(key, cfg);

        // Trades before `startTime`, and the first trade is recorded.
        vm.warp(START_TIME - 50);
        vm.expectEmit(true, false, false, true, address(hook));
        emit LaunchStarted(poolId, START_TIME - 50);
        _swap(key, true, SWAP_AMOUNT);
        assertTrue(hook.getLaunch(poolId).launched, "first swap recorded");

        // The rug: re-enable with the maximum fee and an open 30 days out. Refused.
        BinLaunchGuardHook.LaunchConfig memory rug = _defaultConfig();
        rug.enabled = true;
        rug.initialFeeBips = hook.MAX_INITIAL_FEE();
        rug.finalFeeBips = hook.MAX_FINAL_FEE();
        rug.startTime = uint40(block.timestamp + 30 days);
        vm.expectRevert(
            abi.encodeWithSelector(BinLaunchGuardHook.LaunchAlreadyStarted.selector, poolId, uint256(START_TIME))
        );
        hook.configureLaunch(key, rug);

        // A holder can still sell at the fee they bought under.
        _assertCharged(false, SWAP_AMOUNT, FINAL_FEE);
        // The fee split and the tax are under the same freeze.
        vm.expectRevert(
            abi.encodeWithSelector(BinLaunchGuardHook.LaunchAlreadyStarted.selector, poolId, uint256(START_TIME))
        );
        hook.configureFeeSplit(key, _defaultFeeSplit());
    }

    function test_FIX_disabledLaunchStaysReconfigurableUntilSomebodyTrades() public {
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
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
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
        cfg.enabled = false;
        hook.configureLaunch(key, cfg); // allowed: nobody has traded

        _swap(key, true, SWAP_AMOUNT); // somebody buys the open pool

        cfg.enabled = true;
        cfg.startTime = uint40(block.timestamp + 30 days);
        vm.expectRevert(
            abi.encodeWithSelector(BinLaunchGuardHook.LaunchAlreadyStarted.selector, poolId, uint256(START_TIME))
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
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();
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
        BinLaunchGuardHook.LaunchConfig memory cfg = _defaultConfig();

        vm.warp(START_TIME - 1);
        cfg.startTime = uint40(deadline + 1); // within 30 days of now, past the deadline
        vm.expectRevert(
            abi.encodeWithSelector(BinLaunchGuardHook.StartTimeAfterOpenDeadline.selector, poolId, deadline + 1, deadline)
        );
        hook.configureLaunch(key, cfg);

        cfg.startTime = uint40(deadline); // exactly the deadline is allowed
        hook.configureLaunch(key, cfg);

        vm.warp(deadline - 1); // the last moment a write is possible: every later open is refused
        cfg.startTime = uint40(block.timestamp + 30 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                BinLaunchGuardHook.StartTimeAfterOpenDeadline.selector, poolId, uint256(cfg.startTime), deadline
            )
        );
        hook.configureLaunch(key, cfg);

        vm.warp(deadline); // and it opens
        _swap(key, true, SWAP_AMOUNT);
        assertTrue(hook.getLaunch(poolId).launched, "the launch traded at its deadline");
    }
}
