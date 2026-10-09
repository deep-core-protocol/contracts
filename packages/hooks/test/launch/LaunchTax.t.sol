// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IBinHooks} from "infinity-core/src/pool-bin/interfaces/IBinHooks.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {LiquidityConfigurations} from "infinity-core/src/pool-bin/libraries/math/LiquidityConfigurations.sol";
import {PackedUint128Math} from "infinity-core/src/pool-bin/libraries/math/PackedUint128Math.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {SafeCast as BinSafeCast} from "infinity-core/src/pool-bin/libraries/math/SafeCast.sol";

import {TokenFixture} from "infinity-core/test/helpers/TokenFixture.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {BinTestHelper} from "infinity-core/test/pool-bin/helpers/BinTestHelper.sol";
import {BinSwapHelper} from "infinity-core/test/pool-bin/helpers/BinSwapHelper.sol";
import {BinLiquidityHelper} from "infinity-core/test/pool-bin/helpers/BinLiquidityHelper.sol";

import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "infinity-core/src/types/BeforeSwapDelta.sol";

import {BaseCLHook} from "../../src/base/BaseCLHook.sol";
import {BaseBinHook} from "../../src/base/BaseBinHook.sol";
import {LaunchGuardHook, ILaunchTokenOrigin} from "../../src/launch/LaunchGuardHook.sol";
import {BinLaunchGuardHook} from "../../src/launch/BinLaunchGuardHook.sol";
import {LaunchTaxModule} from "../../src/launch/LaunchTaxModule.sol";

/*//////////////////////////////////////////////////////////////
    EVERY FEE IN THE QUOTE CURRENCY (owner decision, 2026-09-28)

    What this file proves, for the CL guard and the Bin guard alike:

      * the guard hands core an LP fee of ZERO and takes its own fee schedule, and the creator
        tax, as a hook delta in the pool's QUOTE currency, on whichever side of the swap the
        quote is (`beforeSwap` when it is the specified side, `afterSwap` when it is not);
      * both are rates on ONE base, the swap's quote amount, and neither is charged on the other;
      * the launch token is never taken, in any of the four swap shapes, whichever side of the
        pool it sits on;
      * the fee has its own pot and its own split, written once, and the same money path as the
        tax (settle, claim, claimFrom, redeem, skim);
      * the fee split's creator, and only the creator, can hand its bucket over in two steps.

    HOW THE EXPECTED NUMBERS ARE OBTAINED. Every pool under test has a CONTROL pool beside it:
    same currencies, same price, same liquidity, NO hook and a static LP fee of zero. A swap on
    the guarded pool must leave the pool exactly what the control pool is left by the same trade
    less the guard's take, so the control is swapped first and the guarded swap is compared with
    it to the wei. That is an expectation core computed, not one this file re-derived.
//////////////////////////////////////////////////////////////*/

/*//////////////////////////////////////////////////////////////
                             MOCKS
//////////////////////////////////////////////////////////////*/

/// @dev An ERC-20 whose `transfer` hands control to the recipient when the recipient asks for it.
/// Used to prove a claimant cannot re-enter the ledger from inside its own payout.
contract ReenteringERC20 is MockERC20 {
    address public target;

    constructor() MockERC20("Reenter", "RE", 18) {}

    function setTarget(address t) external {
        target = t;
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        bool ok = super.transfer(to, amount);
        if (to == target) ReentrantClaimant(payable(to)).onTransfer();
        return ok;
    }
}

/// @dev A fee and tax recipient that re-enters the hook from inside `transfer`, in a chosen way.
contract ReentrantClaimant {
    enum Mode {
        None,
        Claim,
        ClaimFrom,
        Redeem,
        Skim,
        Settle,
        SettleFee
    }

    LaunchTaxModule public hook;
    Currency public currency;
    PoolId public poolId;
    Mode public mode;
    uint256 public reentered;

    constructor(LaunchTaxModule hook_, Currency currency_, PoolId poolId_) {
        hook = hook_;
        currency = currency_;
        poolId = poolId_;
    }

    function setMode(Mode m) external {
        mode = m;
    }

    function claim() external returns (uint256) {
        return hook.claim(currency, address(this));
    }

    function onTransfer() external {
        reentered++;
        if (mode == Mode.Claim) hook.claim(currency, address(this));
        else if (mode == Mode.ClaimFrom) {
            PoolId[] memory ids = new PoolId[](1);
            ids[0] = poolId;
            hook.claimFrom(ids, currency, address(this));
        } else if (mode == Mode.Redeem) hook.redeem(currency);
        else if (mode == Mode.Skim) hook.skim(currency);
        else if (mode == Mode.Settle) hook.settleTax(poolId, currency);
        else if (mode == Mode.SettleFee) hook.settleFee(poolId, currency);
    }

    receive() external payable {}
}

/// @dev The guard under the bitmap it carried BEFORE the fee moved into the quote currency: 0x08C1,
/// everything but bit 10 (`beforeSwapReturnsDelta`). `BaseCLHook._validatePermissions` accepts it;
/// used to show that bit 10 is load-bearing rather than decorative.
contract PreFeeBitmapHook is LaunchGuardHook {
    constructor(ICLPoolManager pm) LaunchGuardHook(pm, ILaunchTokenOrigin(address(0)), address(0xFEE), 0) {}

    function getHooksRegistrationBitmap() public pure override returns (uint16) {
        return BEFORE_INITIALIZE | BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA;
    }
}

/// @dev The Bin twin of `PreFeeBitmapHook`: 0x08C5.
contract PreFeeBitmapBinHook is BinLaunchGuardHook {
    constructor(IBinPoolManager pm) BinLaunchGuardHook(pm, ILaunchTokenOrigin(address(0)), address(0xFEE), 0) {}

    function getHooksRegistrationBitmap() public pure override returns (uint16) {
        return BEFORE_INITIALIZE | BEFORE_MINT | BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA;
    }
}

/// @dev The two calls a deployed `DeepCoreSplit` makes on whatever address holds a creator role for
/// it, declared here from their signatures alone (this package cannot import `packages/launchpad`,
/// which depends on it): `acceptCreator(uint256)` to take the role, `claim(Currency,address)` to
/// collect what the role earned.
interface ICreatorRoleLike {
    function acceptCreator(uint256 id) external;
}

interface IClaimLike {
    function claim(Currency currency, address to) external returns (uint256);
}

contract SplitLike {
    function accept(address roleHolder, uint256 id) external {
        ICreatorRoleLike(roleHolder).acceptCreator(id);
    }

    function collect(address roleHolder, Currency currency) external returns (uint256) {
        return IClaimLike(roleHolder).claim(currency, address(this));
    }

    receive() external payable {}
}

contract ForceSend {
    constructor() payable {}

    function boom(address payable to) external {
        selfdestruct(to);
    }
}

/*//////////////////////////////////////////////////////////////
                           CL GUARD
//////////////////////////////////////////////////////////////*/

/// @dev The control pool's hook when the guard leaves the pool a share of the fee. It does one thing:
/// the LP fee of the next swap is the number the test set, which the test computed for itself. It
/// takes nothing and holds nothing, so the control pool is still "the same pool without the guard".
contract ControlFeeHook is BaseCLHook {
    uint24 public lpFee;

    constructor(ICLPoolManager pm) BaseCLHook(pm) {}

    function set(uint24 lpFee_) external {
        lpFee = lpFee_;
    }

    function getHooksRegistrationBitmap() public pure override returns (uint16) {
        return BEFORE_SWAP;
    }

    function _beforeSwap(address, PoolKey calldata, ICLPoolManager.SwapParams calldata, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (ICLHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }
}

/// @dev The same, for a Bin pool.
contract ControlFeeBinHook is BaseBinHook {
    uint24 public lpFee;

    constructor(IBinPoolManager pm) BaseBinHook(pm) {}

    function set(uint24 lpFee_) external {
        lpFee = lpFee_;
    }

    function getHooksRegistrationBitmap() public pure override returns (uint16) {
        return BEFORE_SWAP;
    }

    function _beforeSwap(address, PoolKey calldata, bool, int128, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IBinHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, lpFee | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }
}

contract LaunchTaxCLTest is Test, Deployers, TokenFixture {
    using LPFeeLibrary for uint24;
    using CurrencyLibrary for Currency;

    Vault vault;
    CLPoolManager poolManager;
    LaunchGuardHook hook;
    /// @dev Zero while the share is zero: the control pool then has no hook at all.
    ControlFeeHook controlHook;
    CLPoolManagerRouter router;

    /// @dev The suite's default pool: currency1 is the launch token, currency0 the QUOTE.
    PoolKey key;
    PoolKey control;
    PoolId poolId;

    address constant PROTOCOL = address(0xFEE);
    /// @dev The TAX's buckets.
    address creator = makeAddr("creator");
    address integrator = makeAddr("integrator");
    /// @dev The FEE's buckets. Different addresses AND different shares from the tax's, so a pot
    /// settled by the wrong split credits the wrong party by the wrong amount and cannot pass.
    address feeCreator = makeAddr("feeCreator");
    address feeIntegrator = makeAddr("feeIntegrator");

    uint40 constant START_TIME = 101;
    uint32 constant DECAY_SECONDS = 100;
    uint24 constant INITIAL_FEE = 30_000; // 3%
    uint24 constant FINAL_FEE = 3_000; // 0.30%
    uint40 constant EXPIRES_AT = START_TIME + 1000;
    uint16 constant BUY_BPS = 500; // 5%
    uint16 constant SELL_BPS = 300; // 3%

    uint16 constant FEE_CREATOR_BPS = 6_500;
    uint16 constant FEE_PROTOCOL_BPS = 2_000; // exactly the fee's floor
    uint16 constant FEE_INTEGRATOR_BPS = 1_500;

    int256 constant AMOUNT = -1 ether; // exact input

    int24 constant TICK_LOWER = -120;
    int24 constant TICK_UPPER = 120;

    /// @dev Pools on one hook and one currency pair are told apart by their tick spacing.
    uint256 _cursor;

    /// @dev A guarded pool and the hook-less, fee-less pool that mirrors it.
    struct Pool {
        PoolKey key;
        PoolKey control;
        PoolId id;
        bool tokenIs0;
        Currency quote;
        Currency token;
    }

    /// @dev Everything a swap may move, read before and after it.
    struct Reading {
        uint256 traderQuote;
        uint256 traderToken;
        uint256 feeQuote;
        uint256 taxQuote;
        uint256 feeToken;
        uint256 taxToken;
        uint256 claimsQuote;
        uint256 claimsToken;
        uint256 heldQuote;
        uint256 heldToken;
        uint256 owedQuote;
        uint256 owedToken;
        uint256 grossQuote;
        uint256 grossToken;
    }

    /// @dev What one swap did. Amounts are from the trader's side: negative is paid.
    struct Outcome {
        uint24 lpFee; // the fee CORE applied, out of its own Swap event
        int256 poolQuote; // what the pool itself traded, before the guard's delta
        int256 poolToken;
        int256 traderQuote; // the trader's real balance change
        int256 traderToken;
        uint256 fee; // growth of the pool's fee pot, in the quote
        uint256 tax; // growth of the pool's tax pot, in the quote
        uint256 claimsQuote; // growth of the guard's vault claims
        uint256 owedQuote;
        uint256 grossQuote;
        uint256 launchTokenTaken; // every launch-token counter and balance of the guard, summed
    }

    struct Expected {
        uint256 base;
        uint24 lpFee; // what the POOL charges: the liquidity providers' share of a buy's fee
        uint256 fee; // what the GUARD takes of the fee
        uint256 tax;
        int256 poolQuote;
        int256 poolToken;
        int256 traderQuote;
        int256 traderToken;
    }

    /// @dev The share of the trade fee the guard under test leaves the pool, on buys. The whole
    /// suite runs again under each share a derived contract names (the foot of this file).
    function _lpShareBps() internal pure virtual returns (uint16) {
        return 0;
    }

    /// @dev The pool's part of a fee of `feePips`, written independently of the contract's.
    function _lpPips(uint24 feePips, bool isBuy) internal pure returns (uint24) {
        return isBuy ? uint24(uint256(feePips) * _lpShareBps() / 10_000) : 0;
    }

    /// @dev The guard's part: the rest.
    function _guardPips(uint24 feePips, bool isBuy) internal pure returns (uint24) {
        return feePips - _lpPips(feePips, isBuy);
    }

    /// @dev The guard's take of a fee of `feePips` on `base`, floored as the guard floors it.
    function _guardFee(uint256 base, uint24 feePips, bool isBuy) internal pure returns (uint256) {
        return base * _guardPips(feePips, isBuy) / 1_000_000;
    }

    /// @dev A BUY's fee as the guard takes it under the share being tested. `atNoShare` is the figure
    /// with nothing left to the pool: the literal the test was written with, checked when the share
    /// is zero, so the literal still pins the arithmetic and the share's runs state their own.
    function _buyFee(uint256 atNoShare, uint256 base, uint24 feePips) internal pure returns (uint256 fee) {
        fee = _guardFee(base, feePips, true);
        if (_lpShareBps() == 0) require(fee == atNoShare, "the literal is not the fee at no share");
    }

    function _setControlFee(uint24 lpFee) internal {
        if (address(controlHook) != address(0)) controlHook.set(lpFee);
    }

    function setUp() public {
        (vault, poolManager) = createFreshManager();
        hook = new LaunchGuardHook(poolManager, ILaunchTokenOrigin(address(0)), PROTOCOL, _lpShareBps());
        if (_lpShareBps() != 0) controlHook = new ControlFeeHook(poolManager);
        router = new CLPoolManagerRouter(vault, poolManager);

        initializeTokens();
        IERC20(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);

        Pool memory p = _reserve(currency0, currency1, false);
        _open(p, _defaultConfig(), _defaultFeeSplit(), _defaultTax());
        key = p.key;
        control = p.control;
        poolId = p.id;

        vm.warp(START_TIME + DECAY_SECONDS); // decay over: the fee is FINAL_FEE from here
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _key(Currency c0, Currency c1, IHooks h, int24 tickSpacing) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: c0,
            currency1: c1,
            hooks: h,
            poolManager: poolManager,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: CLPoolParametersHelper.setTickSpacing(bytes32(uint256(h.getHooksRegistrationBitmap())), tickSpacing)
        });
    }

    function _spacing(uint256 i) internal pure returns (int24) {
        // Divisors of 120, so the seeded range [-120, 120] is valid on every one of them.
        int24[16] memory s =
            [int24(1), 2, 3, 4, 5, 6, 8, 10, 12, 15, 20, 24, 30, 40, 60, 120];
        return s[i];
    }

    /// @dev The next unused pool on `(c0, c1)`, with its control. Nothing is written on chain.
    function _reserve(Currency c0, Currency c1, bool tokenIs0) internal returns (Pool memory p) {
        int24 spacing = _spacing(_cursor++);
        p.key = _key(c0, c1, hook, spacing);
        // Without a share: no hook, no fee. With one: the hook that charges the LP fee it is told to.
        p.control = address(controlHook) == address(0)
            ? PoolKey({
                currency0: c0,
                currency1: c1,
                hooks: IHooks(address(0)),
                poolManager: poolManager,
                fee: 0,
                parameters: CLPoolParametersHelper.setTickSpacing(bytes32(0), spacing)
            })
            : _key(c0, c1, controlHook, spacing);
        p.id = p.key.toId();
        p.tokenIs0 = tokenIs0;
        (p.quote, p.token) = tokenIs0 ? (c1, c0) : (c0, c1);
    }

    /// @dev Claim, write the split and the tax (when it has a rate), initialize and seed `p` and its
    /// control identically.
    function _open(
        Pool memory p,
        LaunchGuardHook.LaunchConfig memory cfg,
        LaunchTaxModule.FeeSplit memory split,
        LaunchTaxModule.TaxConfig memory tax
    ) internal {
        cfg.launchTokenIsCurrency0 = p.tokenIs0;
        hook.configureLaunch(p.key, cfg);
        hook.configureFeeSplit(p.key, split);
        if (tax.buyBps != 0 || tax.sellBps != 0) hook.configureTax(p.key, tax);
        poolManager.initialize(p.key, SQRT_RATIO_1_1);
        poolManager.initialize(p.control, SQRT_RATIO_1_1);
        uint256 value = p.key.currency0.isNative() ? 20 ether : 0;
        _seed(p.key, value);
        _seed(p.control, value);
    }

    /// @dev A pool on the fixture pair that opens in ten seconds, with the default split.
    function _launch(bool tokenIs0, LaunchGuardHook.LaunchConfig memory cfg, LaunchTaxModule.TaxConfig memory tax)
        internal
        returns (Pool memory p)
    {
        p = _reserve(currency0, currency1, tokenIs0);
        _open(p, cfg, _defaultFeeSplit(), tax);
    }

    function _default() internal view returns (Pool memory p) {
        p.key = key;
        p.control = control;
        p.id = poolId;
        p.tokenIs0 = false;
        p.quote = currency0;
        p.token = currency1;
    }

    function _defaultConfig() internal pure returns (LaunchGuardHook.LaunchConfig memory) {
        return LaunchGuardHook.LaunchConfig({
            startTime: START_TIME,
            decaySeconds: DECAY_SECONDS,
            initialFeeBips: INITIAL_FEE,
            finalFeeBips: FINAL_FEE,
            maxBuyPerTx: 0,
            launchTokenIsCurrency0: false, // currency1 is the launch token => a buy is zeroForOne
            enabled: true
        });
    }

    function _defaultConfigAt(uint40 start) internal pure returns (LaunchGuardHook.LaunchConfig memory c) {
        c = _defaultConfig();
        c.startTime = start;
    }

    function _defaultTax() internal view returns (LaunchTaxModule.TaxConfig memory) {
        return LaunchTaxModule.TaxConfig({
            buyBps: BUY_BPS,
            sellBps: SELL_BPS,
            expiresAt: EXPIRES_AT,
            creator: creator,
            integrator: integrator,
            creatorBps: 7_000,
            protocolBps: 1_000, // exactly the tax's floor
            integratorBps: 2_000 // exactly the cap
        });
    }

    function _validTax() internal view returns (LaunchTaxModule.TaxConfig memory t) {
        t = _defaultTax();
        t.expiresAt = uint40(vm.getBlockTimestamp() + 7 days);
    }

    function _zeroTax() internal pure returns (LaunchTaxModule.TaxConfig memory t) {}

    function _defaultFeeSplit() internal view returns (LaunchTaxModule.FeeSplit memory) {
        return LaunchTaxModule.FeeSplit({
            creator: feeCreator,
            creatorBps: FEE_CREATOR_BPS,
            protocolBps: FEE_PROTOCOL_BPS,
            integratorBps: FEE_INTEGRATOR_BPS,
            integrator: feeIntegrator
        });
    }

    /// @dev A fresh, claimed, not-yet-open pool for configuration tests. No split, not initialized.
    function _freshPool() internal returns (PoolKey memory k, PoolId id) {
        Pool memory p = _reserve(currency0, currency1, false);
        k = p.key;
        id = p.id;
        hook.configureLaunch(k, _defaultConfigAt(uint40(vm.getBlockTimestamp() + 10)));
    }

    function _seed(PoolKey memory k, uint256 value) internal {
        router.modifyPosition{value: value}(
            k,
            ICLPoolManager.ModifyLiquidityParams({
                tickLower: TICK_LOWER, tickUpper: TICK_UPPER, liquidityDelta: 1_000 ether, salt: 0
            }),
            ZERO_BYTES
        );
    }

    function _params(bool zeroForOne, int256 amountSpecified) internal pure returns (ICLPoolManager.SwapParams memory) {
        return ICLPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
        });
    }

    function _swap(PoolKey memory k, bool zeroForOne, int256 amountSpecified, uint256 value)
        internal
        returns (BalanceDelta)
    {
        return router.swap{value: value}(
            k,
            _params(zeroForOne, amountSpecified),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ZERO_BYTES
        );
    }

    /// @dev A buy is quote in, launch token out.
    function _zeroForOne(Pool memory p, bool isBuy) internal pure returns (bool) {
        return isBuy ? !p.tokenIs0 : p.tokenIs0;
    }

    /// @dev Native sent with a swap whose input is the native asset. The router refunds the rest.
    function _value(PoolKey memory k, bool zeroForOne) internal pure returns (uint256) {
        return (zeroForOne ? k.currency0 : k.currency1).isNative() ? 100 ether : 0;
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    function _read(Pool memory p) internal view returns (Reading memory r) {
        r.traderQuote = p.quote.balanceOf(address(this));
        r.traderToken = p.token.balanceOf(address(this));
        r.feeQuote = hook.feeTaken(p.id, p.quote);
        r.taxQuote = hook.totalTaken(p.id, p.quote);
        r.feeToken = hook.feeTaken(p.id, p.token);
        r.taxToken = hook.totalTaken(p.id, p.token);
        r.claimsQuote = vault.balanceOf(address(hook), p.quote);
        r.claimsToken = vault.balanceOf(address(hook), p.token);
        r.heldQuote = p.quote.balanceOf(address(hook));
        r.heldToken = p.token.balanceOf(address(hook));
        r.owedQuote = hook.totalOwed(p.quote);
        r.owedToken = hook.totalOwed(p.token);
        r.grossQuote = hook.grossTaken(p.quote);
        r.grossToken = hook.grossTaken(p.token);
    }

    /// @dev One swap on the guarded pool, measured from outside: the trader's balances, the guard's
    /// counters and vault claims, and what core itself reported in its `Swap` event (which it emits
    /// before `afterSwap`, so it carries the pool's own amounts and the LP fee it applied).
    function _trade(Pool memory p, bool isBuy, bool exactIn, uint256 amount) internal returns (Outcome memory) {
        return this.measureTrade(p, isBuy, exactIn, amount);
    }

    /// @dev Behind an EXTERNAL call to this contract on purpose. Decoding `Vm.Log[]` takes a dozen
    /// stack slots, and via-IR inlines an internal helper into whichever test calls it: with the
    /// test's own structs live that is one slot too many ("too deep in the stack"). The router's
    /// caller is this contract either way, and `vm.expectEmit` sees the events of nested calls.
    function measureTrade(Pool memory p, bool isBuy, bool exactIn, uint256 amount)
        external
        returns (Outcome memory o)
    {
        Reading memory a = _read(p);
        bool zeroForOne = _zeroForOne(p, isBuy);

        vm.recordLogs();
        _swap(p.key, zeroForOne, exactIn ? -int256(amount) : int256(amount), _value(p.key, zeroForOne));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(poolManager) && logs[i].topics[0] == ICLPoolManager.Swap.selector) {
                (int128 g0, int128 g1,,,, uint24 fee,) =
                    abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24, uint16));
                (o.poolQuote, o.poolToken) = p.tokenIs0 ? (int256(g1), int256(g0)) : (int256(g0), int256(g1));
                o.lpFee = fee;
                seen = true;
            }
        }
        require(seen, "Swap event not found");

        Reading memory b = _read(p);
        o.traderQuote = int256(b.traderQuote) - int256(a.traderQuote);
        o.traderToken = int256(b.traderToken) - int256(a.traderToken);
        o.fee = b.feeQuote - a.feeQuote;
        o.tax = b.taxQuote - a.taxQuote;
        o.claimsQuote = b.claimsQuote - a.claimsQuote;
        o.owedQuote = b.owedQuote - a.owedQuote;
        o.grossQuote = b.grossQuote - a.grossQuote;
        // None of these may move at all, so their differences are summed: any growth shows.
        o.launchTokenTaken = (b.feeToken - a.feeToken) + (b.taxToken - a.taxToken) + (b.claimsToken - a.claimsToken)
            + (b.heldToken - a.heldToken) + (b.owedToken - a.owedToken) + (b.grossToken - a.grossToken);
        assertEq(b.heldQuote, a.heldQuote, "a swap moves vault claims, never real tokens, into the guard");
    }

    /// @dev What the same trade must do, from the control pool. `feePips` and `taxBps` are the
    /// caller's own expectation of the rates, never read back from the guard.
    function _predict(Pool memory p, bool isBuy, bool exactIn, uint256 amount, uint24 feePips, uint16 taxBps)
        internal
        returns (Expected memory e)
    {
        bool zeroForOne = _zeroForOne(p, isBuy);
        // The quote is the specified side of an exact-input buy and of an exact-output sell.
        bool quoteSpecified = exactIn == isBuy;
        // `feePips` is the WHOLE trade fee. The pool charges its share of a buy's; the guard the rest.
        e.lpFee = _lpPips(feePips, isBuy);
        _setControlFee(e.lpFee);
        feePips = feePips - e.lpFee;

        uint256 poolAmount = amount;
        if (quoteSpecified) {
            e.base = amount;
            e.fee = amount * feePips / 1_000_000;
            e.tax = amount * taxBps / 10_000;
            // Exact input: the pool is handed what is left. Exact output: it must pay out the take too.
            poolAmount = exactIn ? amount - e.fee - e.tax : amount + e.fee + e.tax;
        }

        BalanceDelta c =
            _swap(p.control, zeroForOne, exactIn ? -int256(poolAmount) : int256(poolAmount), _value(p.control, zeroForOne));
        (e.poolQuote, e.poolToken) =
            p.tokenIs0 ? (int256(c.amount1()), int256(c.amount0())) : (int256(c.amount0()), int256(c.amount1()));

        if (!quoteSpecified) {
            e.base = _abs(e.poolQuote);
            e.fee = e.base * feePips / 1_000_000;
            e.tax = e.base * taxBps / 10_000;
        }
        e.traderQuote = e.poolQuote - int256(e.fee + e.tax);
        e.traderToken = e.poolToken;
    }

    function _assertMatches(Pool memory p, Expected memory e, Outcome memory o) internal view {
        assertEq(o.lpFee, e.lpFee, "the LP fee core applied");
        assertEq(o.poolQuote, e.poolQuote, "pool quote amount != control");
        assertEq(o.poolToken, e.poolToken, "pool token amount != control");
        assertEq(o.fee, e.fee, "fee pot");
        assertEq(o.tax, e.tax, "tax pot");
        assertEq(o.claimsQuote, e.fee + e.tax, "vault claims in the quote");
        assertEq(o.owedQuote, e.fee + e.tax, "totalOwed in the quote");
        assertEq(o.grossQuote, e.fee + e.tax, "grossTaken in the quote");
        assertEq(o.launchTokenTaken, 0, "the guard took launch token");
        assertEq(o.traderQuote, e.traderQuote, "trader quote");
        assertEq(o.traderToken, e.traderToken, "trader launch token");
        _assertSolvent(p.quote);
        _assertSolvent(p.token);
    }

    function _assertShape(Pool memory p, bool isBuy, bool exactIn, uint256 amount, uint24 feePips, uint16 taxBps)
        internal
        returns (Expected memory e, Outcome memory o)
    {
        e = _predict(p, isBuy, exactIn, amount, feePips, taxBps);
        o = _trade(p, isBuy, exactIn, amount);
        _assertMatches(p, e, o);
    }

    /// @dev A bucket's floor share of a pot.
    function _share(uint256 pot, uint256 bps) internal pure returns (uint256) {
        return pot * bps / 10_000;
    }

    /// @dev The pool id as the number the rotation takes: the lockers' signature.
    function _id(PoolId id) internal pure returns (uint256) {
        return uint256(PoolId.unwrap(id));
    }

    function _assertSolvent(Currency c) internal view {
        assertGe(hook.backing(c), hook.totalOwed(c), "backing < totalOwed");
    }

    /// @dev The linear decay, written independently of the contract's.
    function _decayed(uint24 initialFee, uint24 finalFee, uint256 elapsed, uint256 window)
        internal
        pure
        returns (uint24)
    {
        if (elapsed >= window) return finalFee;
        return uint24(uint256(initialFee) - (uint256(initialFee - finalFee) * elapsed) / window);
    }

    /// @dev The routers refund leftover native to the caller.
    receive() external payable {}

    function _expectHookRevert(bytes4 hookFn, bytes memory inner) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                hookFn,
                inner,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    /// @dev Whether the guard emitted an event with `topic0` in the logs recorded since `vm.recordLogs`.
    function _guardEmitted(bytes32 topic0) internal returns (bool) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(hook) && logs[i].topics[0] == topic0) return true;
        }
        return false;
    }

    /*//////////////////////////////////////////////////////////////
                       CONFIGURATION: THE TAX
    //////////////////////////////////////////////////////////////*/

    function test_configureTax_storesAndEmits() public {
        (PoolKey memory k, PoolId id) = _freshPool();

        LaunchTaxModule.TaxConfig memory t = _defaultTax();
        t.expiresAt = uint40(vm.getBlockTimestamp() + 7 days);
        vm.expectEmit(true, false, false, true, address(hook));
        emit LaunchTaxModule.TaxConfigured(id, BUY_BPS, SELL_BPS, t.expiresAt, creator, integrator, 7_000, 1_000, 2_000);
        hook.configureTax(k, t);

        LaunchTaxModule.Tax memory s = hook.getTax(id);
        assertEq(s.buyBps, BUY_BPS);
        assertEq(s.sellBps, SELL_BPS);
        assertEq(s.expiresAt, t.expiresAt);
        assertEq(s.creator, creator);
        assertEq(s.integrator, integrator);
        assertEq(s.creatorBps, 7_000);
        assertEq(s.protocolBps, 1_000);
        assertEq(s.integratorBps, 2_000);
        (uint16 b, uint16 sl) = hook.currentTaxRates(id);
        assertEq(b, BUY_BPS);
        assertEq(sl, SELL_BPS);
    }

    function test_configureTax_revertsForStranger() public {
        (PoolKey memory k, PoolId id) = _freshPool();
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.NotLaunchOwner.selector, id, makeAddr("stranger")));
        hook.configureTax(k, _validTax());
    }

    function test_configureTax_revertsOnUnclaimedPool() public {
        PoolKey memory k = _reserve(currency0, currency1, false).key;
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.LaunchNotConfigured.selector, k.toId()));
        hook.configureTax(k, _validTax());
    }

    function test_configureTax_revertsOnForeignKey() public {
        (PoolKey memory k,) = _freshPool();
        PoolKey memory bad = k;
        bad.hooks = IHooks(makeAddr("other"));
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.HookMismatch.selector, address(bad.hooks)));
        hook.configureTax(bad, _validTax());
        bad.hooks = hook;
        bad.poolManager = ICLPoolManager(makeAddr("otherPM"));
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.PoolManagerMismatch.selector, address(bad.poolManager)));
        hook.configureTax(bad, _validTax());
    }

    function test_configureTax_frozenFromStartTime() public {
        (PoolKey memory k, PoolId id) = _freshPool();
        uint256 start = vm.getBlockTimestamp() + 10;
        vm.warp(start - 1);
        hook.configureTax(k, _validTax()); // one second before: still open
        vm.warp(start + 1);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.LaunchAlreadyStarted.selector, id, start));
        hook.configureTax(k, _validTax());
        // The freeze holds for the pool that is trading in this suite too.
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.LaunchAlreadyStarted.selector, poolId, uint256(START_TIME)));
        hook.configureTax(key, _validTax());
    }

    /// @dev The second trading opens is still writable (a kit claims and taxes in one transaction, and a launch
    /// may open at once), but only until somebody trades in it.
    function test_configureTax_writableAtStartTimeUntilTheFirstTrade() public {
        Pool memory p = _reserve(currency0, currency1, false);
        LaunchGuardHook.LaunchConfig memory c = _defaultConfigAt(uint40(vm.getBlockTimestamp()));
        hook.configureLaunch(p.key, c); // opens now
        hook.configureFeeSplit(p.key, _defaultFeeSplit()); // same second, no trade yet: allowed
        hook.configureTax(p.key, _validTax()); // and so is the tax
        poolManager.initialize(p.key, SQRT_RATIO_1_1);
        _seed(p.key, 0);
        _swap(p.key, true, AMOUNT, 0);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.LaunchAlreadyStarted.selector, p.id, uint256(c.startTime)));
        hook.configureTax(p.key, _validTax());
        vm.warp(vm.getBlockTimestamp() + 1);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.LaunchAlreadyStarted.selector, p.id, uint256(c.startTime)));
        hook.configureTax(p.key, _validTax());
    }

    function test_configureTax_frozenByTheFirstSwapOfADisabledLaunch() public {
        Pool memory p = _reserve(currency0, currency1, false);
        LaunchGuardHook.LaunchConfig memory c = _defaultConfigAt(uint40(vm.getBlockTimestamp() + 30 days));
        c.enabled = false;
        hook.configureLaunch(p.key, c);
        hook.configureFeeSplit(p.key, _defaultFeeSplit());
        hook.configureTax(p.key, _validTax());
        poolManager.initialize(p.key, SQRT_RATIO_1_1);
        _seed(p.key, 0);
        _swap(p.key, true, AMOUNT, 0); // trades at once: disabled schedules have no gate
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.LaunchAlreadyStarted.selector, p.id, uint256(c.startTime)));
        hook.configureTax(p.key, _validTax());
    }

    function test_configureTax_capsEachRate() public {
        (PoolKey memory k,) = _freshPool();
        LaunchTaxModule.TaxConfig memory t = _validTax();
        t.buyBps = 1_001;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxRateTooHigh.selector, uint16(1_001)));
        hook.configureTax(k, t);
        t = _validTax();
        t.sellBps = 1_001;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxRateTooHigh.selector, uint16(1_001)));
        hook.configureTax(k, t);
        t = _validTax();
        t.buyBps = 1_000;
        t.sellBps = 1_000;
        hook.configureTax(k, t); // the cap itself is allowed
        assertEq(hook.MAX_TAX_BPS(), 1_000);
    }

    function test_configureTax_expiryWindow() public {
        (PoolKey memory k,) = _freshPool();
        LaunchTaxModule.TaxConfig memory t = _validTax();
        t.expiresAt = uint40(vm.getBlockTimestamp());
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxExpiryOutOfRange.selector, t.expiresAt, vm.getBlockTimestamp()));
        hook.configureTax(k, t);
        t.expiresAt = uint40(vm.getBlockTimestamp() + 180 days + 1);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxExpiryOutOfRange.selector, t.expiresAt, vm.getBlockTimestamp()));
        hook.configureTax(k, t);
        t.expiresAt = uint40(vm.getBlockTimestamp() + 180 days);
        hook.configureTax(k, t);
        t.expiresAt = uint40(vm.getBlockTimestamp() + 1);
        hook.configureTax(k, t);
        assertEq(hook.MAX_TAX_DURATION_SECONDS(), 180 days);
    }

    function test_configureTax_splitMustSumToTenThousand() public {
        (PoolKey memory k,) = _freshPool();
        LaunchTaxModule.TaxConfig memory t = _validTax();
        t.creatorBps = 6_999;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxSplitDoesNotSum.selector, uint256(9_999)));
        hook.configureTax(k, t);
        t.creatorBps = 7_001;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxSplitDoesNotSum.selector, uint256(10_001)));
        hook.configureTax(k, t);
    }

    /// @dev THE FLOOR. The kit passes a split through; this is the only place it is enforced.
    function test_FLOOR_protocolBelowTenPercentIsRefused() public {
        (PoolKey memory k,) = _freshPool();
        LaunchTaxModule.TaxConfig memory t = _validTax();
        t.protocolBps = 999;
        t.creatorBps = 7_001;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxProtocolShareOutOfBounds.selector, uint16(999)));
        hook.configureTax(k, t);
        t.protocolBps = 0;
        t.creatorBps = 8_000;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxProtocolShareOutOfBounds.selector, uint16(0)));
        hook.configureTax(k, t);
        // and the cap
        t.protocolBps = 5_001;
        t.creatorBps = 2_999;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxProtocolShareOutOfBounds.selector, uint16(5_001)));
        hook.configureTax(k, t);
        t.protocolBps = 5_000;
        t.creatorBps = 3_000;
        hook.configureTax(k, t);
        assertEq(hook.MIN_PROTOCOL_BPS(), 1_000);
        assertEq(hook.MAX_PROTOCOL_BPS(), 5_000);
    }

    function testFuzz_FLOOR_everySplitBelowTheFloorIsRefused(uint16 protocolBps, uint16 integratorBps) public {
        protocolBps = uint16(bound(protocolBps, 0, 999));
        integratorBps = uint16(bound(integratorBps, 0, 2_000));
        (PoolKey memory k,) = _freshPool();
        LaunchTaxModule.TaxConfig memory t = _validTax();
        t.protocolBps = protocolBps;
        t.integratorBps = integratorBps;
        t.integrator = integratorBps == 0 ? address(0) : integrator;
        t.creatorBps = 10_000 - protocolBps - integratorBps;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxProtocolShareOutOfBounds.selector, protocolBps));
        hook.configureTax(k, t);
    }

    function test_configureTax_integratorCap() public {
        (PoolKey memory k,) = _freshPool();
        LaunchTaxModule.TaxConfig memory t = _validTax();
        t.integratorBps = 2_001;
        t.creatorBps = 6_999;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxIntegratorShareTooHigh.selector, uint16(2_001)));
        hook.configureTax(k, t);
        assertEq(hook.MAX_INTEGRATOR_BPS(), 2_000);
    }

    function test_configureTax_recipientRules() public {
        (PoolKey memory k,) = _freshPool();
        LaunchTaxModule.TaxConfig memory t = _validTax();
        t.creator = address(0);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxRecipientMismatch.selector, address(0), uint16(7_000)));
        hook.configureTax(k, t);
        t = _validTax();
        t.integratorBps = 0;
        t.creatorBps = 9_000;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxRecipientMismatch.selector, integrator, uint16(0)));
        hook.configureTax(k, t);
        t.integrator = address(0);
        hook.configureTax(k, t); // no integrator bucket: fine
        t = _validTax();
        t.creator = address(hook);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.InvalidTaxRecipient.selector, address(hook)));
        hook.configureTax(k, t);
        t = _validTax();
        t.integrator = address(hook);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.InvalidTaxRecipient.selector, address(hook)));
        hook.configureTax(k, t);
    }

    function test_configureTax_allZeroClearsAndPartialZeroIsRefused() public {
        (PoolKey memory k, PoolId id) = _freshPool();
        hook.configureTax(k, _validTax());
        assertEq(hook.getTax(id).buyBps, BUY_BPS);

        LaunchTaxModule.TaxConfig memory t; // all zero
        vm.expectEmit(true, false, false, true, address(hook));
        emit LaunchTaxModule.TaxConfigured(id, 0, 0, 0, address(0), address(0), 0, 0, 0);
        hook.configureTax(k, t);
        LaunchTaxModule.Tax memory s = hook.getTax(id);
        assertEq(s.expiresAt, 0);
        assertEq(s.creator, address(0));
        (uint16 b, uint16 sl) = hook.currentTaxRates(id);
        assertEq(b + sl, 0);

        t.protocolBps = 10_000; // rates zero but buckets set: not a clear, not a tax
        vm.expectRevert(LaunchTaxModule.TaxWithoutRate.selector);
        hook.configureTax(k, t);
        t = _validTax();
        t.buyBps = 0;
        t.sellBps = 0;
        vm.expectRevert(LaunchTaxModule.TaxWithoutRate.selector);
        hook.configureTax(k, t);
    }

    function test_configureTax_oneRateMayBeZero() public {
        (PoolKey memory k, PoolId id) = _freshPool();
        LaunchTaxModule.TaxConfig memory t = _validTax();
        t.sellBps = 0;
        hook.configureTax(k, t);
        (uint16 b, uint16 sl) = hook.currentTaxRates(id);
        assertEq(b, BUY_BPS);
        assertEq(sl, 0);
    }

    function test_construction_refusesZeroRecipient() public {
        vm.expectRevert(LaunchTaxModule.ZeroAddress.selector);
        new LaunchGuardHook(poolManager, ILaunchTokenOrigin(address(0)), address(0), 0);
        assertEq(hook.protocolRecipient(), PROTOCOL);
        assertEq(address(hook.vault()), address(vault));
    }

    /*//////////////////////////////////////////////////////////////
                     CONFIGURATION: THE FEE SPLIT

        Written ONCE, by the launch owner, before trading. A pool
        cannot be initialized without it. The protocol's floor on
        the fee is 20%, twice the tax's, because the fee replaces
        the locked position's LP fee, whose floor was 20%.
    //////////////////////////////////////////////////////////////*/

    function test_feeSplit_storesAndEmits() public {
        (PoolKey memory k, PoolId id) = _freshPool();
        LaunchTaxModule.FeeSplit memory none = hook.getFeeSplit(id);
        assertEq(none.protocolBps, 0, "unset reads all zero");
        assertEq(none.creator, address(0));

        vm.expectEmit(true, false, false, true, address(hook));
        emit LaunchTaxModule.FeeSplitConfigured(
            id, feeCreator, feeIntegrator, FEE_CREATOR_BPS, FEE_PROTOCOL_BPS, FEE_INTEGRATOR_BPS
        );
        hook.configureFeeSplit(k, _defaultFeeSplit());

        LaunchTaxModule.FeeSplit memory f = hook.getFeeSplit(id);
        assertEq(f.creator, feeCreator);
        assertEq(f.integrator, feeIntegrator);
        assertEq(f.creatorBps, FEE_CREATOR_BPS);
        assertEq(f.protocolBps, FEE_PROTOCOL_BPS);
        assertEq(f.integratorBps, FEE_INTEGRATOR_BPS);
        // The tax is a separate record and stays empty.
        assertEq(hook.getTax(id).creator, address(0));
    }

    /// @dev MUTATION-CHECKED (f): removing the `FeeSplitAlreadySet` check lets every write below land.
    function test_feeSplit_isWrittenOnce() public {
        (PoolKey memory k, PoolId id) = _freshPool();
        hook.configureFeeSplit(k, _defaultFeeSplit());

        // The identical split again, still before trading, by the owner: refused.
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.FeeSplitAlreadySet.selector, id));
        hook.configureFeeSplit(k, _defaultFeeSplit());

        // A different split: refused, and nothing moved.
        LaunchTaxModule.FeeSplit memory other = _defaultFeeSplit();
        other.creator = makeAddr("somebodyElse");
        other.creatorBps = 3_000;
        other.protocolBps = 5_000;
        other.integratorBps = 2_000;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.FeeSplitAlreadySet.selector, id));
        hook.configureFeeSplit(k, other);

        LaunchTaxModule.FeeSplit memory f = hook.getFeeSplit(id);
        assertEq(f.creator, feeCreator);
        assertEq(f.creatorBps, FEE_CREATOR_BPS);
        assertEq(f.protocolBps, FEE_PROTOCOL_BPS);
        assertEq(f.integratorBps, FEE_INTEGRATOR_BPS);
        assertEq(f.integrator, feeIntegrator);
    }

    function test_feeSplit_revertsForStranger() public {
        (PoolKey memory k, PoolId id) = _freshPool();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.NotLaunchOwner.selector, id, stranger));
        hook.configureFeeSplit(k, _defaultFeeSplit());
        // The parties the split would name have no say in it either.
        vm.prank(feeCreator);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.NotLaunchOwner.selector, id, feeCreator));
        hook.configureFeeSplit(k, _defaultFeeSplit());
        vm.prank(PROTOCOL);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.NotLaunchOwner.selector, id, PROTOCOL));
        hook.configureFeeSplit(k, _defaultFeeSplit());
        assertEq(hook.getFeeSplit(id).protocolBps, 0, "nothing was written");
    }

    function test_feeSplit_revertsOnUnclaimedPool() public {
        PoolKey memory k = _reserve(currency0, currency1, false).key;
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.LaunchNotConfigured.selector, k.toId()));
        hook.configureFeeSplit(k, _defaultFeeSplit());
    }

    function test_feeSplit_revertsOnForeignKey() public {
        (PoolKey memory k,) = _freshPool();
        PoolKey memory bad = k;
        bad.hooks = IHooks(makeAddr("other"));
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.HookMismatch.selector, address(bad.hooks)));
        hook.configureFeeSplit(bad, _defaultFeeSplit());
        bad.hooks = hook;
        bad.poolManager = ICLPoolManager(makeAddr("otherPM"));
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.PoolManagerMismatch.selector, address(bad.poolManager)));
        hook.configureFeeSplit(bad, _defaultFeeSplit());
    }

    /// @dev The freeze is the tax's: writable through the second trading opens, frozen after it.
    function test_feeSplit_frozenAfterStartTime() public {
        (PoolKey memory k, PoolId id) = _freshPool();
        uint256 start = vm.getBlockTimestamp() + 10;
        vm.warp(start + 1);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.LaunchAlreadyStarted.selector, id, start));
        hook.configureFeeSplit(k, _defaultFeeSplit());
        assertEq(hook.getFeeSplit(id).protocolBps, 0);

        (PoolKey memory k2, PoolId id2) = _freshPool();
        vm.warp(vm.getBlockTimestamp() + 10); // exactly its start, nobody has traded
        hook.configureFeeSplit(k2, _defaultFeeSplit());
        assertEq(hook.getFeeSplit(id2).protocolBps, FEE_PROTOCOL_BPS);
    }

    /// @dev On a pool that trades, the freeze answers before the write-once rule does.
    function test_feeSplit_frozenByTheFirstSwap() public {
        Pool memory p = _reserve(currency0, currency1, false);
        LaunchGuardHook.LaunchConfig memory c = _defaultConfigAt(uint40(vm.getBlockTimestamp() + 30 days));
        c.enabled = false; // trades before its start time
        _open(p, c, _defaultFeeSplit(), _zeroTax());
        _swap(p.key, true, AMOUNT, 0);
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.LaunchAlreadyStarted.selector, p.id, uint256(c.startTime)));
        hook.configureFeeSplit(p.key, _defaultFeeSplit());
        // And on the suite's pool, long open.
        vm.expectRevert(abi.encodeWithSelector(LaunchGuardHook.LaunchAlreadyStarted.selector, poolId, uint256(START_TIME)));
        hook.configureFeeSplit(key, _defaultFeeSplit());
    }

    function test_feeSplit_mustSumToTenThousand() public {
        (PoolKey memory k, PoolId id) = _freshPool();
        LaunchTaxModule.FeeSplit memory f = _defaultFeeSplit();
        f.creatorBps = FEE_CREATOR_BPS - 1;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxSplitDoesNotSum.selector, uint256(9_999)));
        hook.configureFeeSplit(k, f);
        f.creatorBps = FEE_CREATOR_BPS + 1;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxSplitDoesNotSum.selector, uint256(10_001)));
        hook.configureFeeSplit(k, f);
        LaunchTaxModule.FeeSplit memory zero;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxSplitDoesNotSum.selector, uint256(0)));
        hook.configureFeeSplit(k, zero);
        assertEq(hook.getFeeSplit(id).protocolBps, 0);
    }

    /// @dev THE FEE'S FLOOR: 20%, not the tax's 10%.
    /// MUTATION-CHECKED (h): with `MIN_FEE_PROTOCOL_BPS` at 1_000 the 1_999 and 1_000 writes land.
    function test_FEEFLOOR_protocolBelowTwentyPercentIsRefused() public {
        (PoolKey memory k, PoolId id) = _freshPool();
        LaunchTaxModule.FeeSplit memory f = _defaultFeeSplit();
        f.protocolBps = 1_999;
        f.creatorBps = 10_000 - 1_999 - FEE_INTEGRATOR_BPS;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxProtocolShareOutOfBounds.selector, uint16(1_999)));
        hook.configureFeeSplit(k, f);
        // What the TAX accepts as its floor is below the fee's.
        f.protocolBps = 1_000;
        f.creatorBps = 10_000 - 1_000 - FEE_INTEGRATOR_BPS;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxProtocolShareOutOfBounds.selector, uint16(1_000)));
        hook.configureFeeSplit(k, f);
        f.protocolBps = 0;
        f.creatorBps = 10_000 - FEE_INTEGRATOR_BPS;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxProtocolShareOutOfBounds.selector, uint16(0)));
        hook.configureFeeSplit(k, f);
        // and the cap
        f.protocolBps = 5_001;
        f.creatorBps = 10_000 - 5_001 - FEE_INTEGRATOR_BPS;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxProtocolShareOutOfBounds.selector, uint16(5_001)));
        hook.configureFeeSplit(k, f);
        assertEq(hook.getFeeSplit(id).protocolBps, 0, "nothing was written");

        // Exactly the floor, and exactly the cap, are accepted (one pool each: a split is written once).
        f.protocolBps = 2_000;
        f.creatorBps = 10_000 - 2_000 - FEE_INTEGRATOR_BPS;
        hook.configureFeeSplit(k, f);
        assertEq(hook.getFeeSplit(id).protocolBps, 2_000);
        (PoolKey memory k2, PoolId id2) = _freshPool();
        f.protocolBps = 5_000;
        f.creatorBps = 10_000 - 5_000 - FEE_INTEGRATOR_BPS;
        hook.configureFeeSplit(k2, f);
        assertEq(hook.getFeeSplit(id2).protocolBps, 5_000);

        assertEq(hook.MIN_FEE_PROTOCOL_BPS(), 2_000);
        assertEq(hook.MIN_PROTOCOL_BPS(), 1_000, "the tax keeps its own floor");
        assertEq(hook.MAX_PROTOCOL_BPS(), 5_000);
    }

    function testFuzz_FEEFLOOR_everySplitBelowTheFloorIsRefused(uint16 protocolBps, uint16 integratorBps) public {
        protocolBps = uint16(bound(protocolBps, 0, 1_999));
        integratorBps = uint16(bound(integratorBps, 0, 2_000));
        (PoolKey memory k, PoolId id) = _freshPool();
        LaunchTaxModule.FeeSplit memory f = _defaultFeeSplit();
        f.protocolBps = protocolBps;
        f.integratorBps = integratorBps;
        f.integrator = integratorBps == 0 ? address(0) : feeIntegrator;
        f.creatorBps = 10_000 - protocolBps - integratorBps;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxProtocolShareOutOfBounds.selector, protocolBps));
        hook.configureFeeSplit(k, f);
        assertEq(hook.getFeeSplit(id).protocolBps, 0);
    }

    /// @dev Every split inside the bounds is accepted and stored as given.
    function testFuzz_feeSplit_everySplitInsideTheBoundsIsStored(uint16 protocolBps, uint16 integratorBps) public {
        protocolBps = uint16(bound(protocolBps, 2_000, 5_000));
        integratorBps = uint16(bound(integratorBps, 0, 2_000));
        (PoolKey memory k, PoolId id) = _freshPool();
        LaunchTaxModule.FeeSplit memory f = _defaultFeeSplit();
        f.protocolBps = protocolBps;
        f.integratorBps = integratorBps;
        f.integrator = integratorBps == 0 ? address(0) : feeIntegrator;
        f.creatorBps = 10_000 - protocolBps - integratorBps;
        hook.configureFeeSplit(k, f);
        LaunchTaxModule.FeeSplit memory s = hook.getFeeSplit(id);
        assertEq(s.protocolBps, protocolBps);
        assertEq(s.integratorBps, integratorBps);
        assertEq(s.creatorBps, f.creatorBps);
        assertEq(s.integrator, f.integrator);
        assertEq(s.creator, feeCreator);
        // The bounds leave the creator at least 30%, so a configured split always names one.
        assertGe(s.creatorBps, 3_000);
    }

    function test_feeSplit_integratorCap() public {
        (PoolKey memory k,) = _freshPool();
        LaunchTaxModule.FeeSplit memory f = _defaultFeeSplit();
        f.integratorBps = 2_001;
        f.creatorBps = 10_000 - FEE_PROTOCOL_BPS - 2_001;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxIntegratorShareTooHigh.selector, uint16(2_001)));
        hook.configureFeeSplit(k, f);
        f.integratorBps = 2_000;
        f.creatorBps = 10_000 - FEE_PROTOCOL_BPS - 2_000;
        hook.configureFeeSplit(k, f); // the cap itself is allowed
    }

    function test_feeSplit_recipientRules() public {
        (PoolKey memory k, PoolId id) = _freshPool();
        LaunchTaxModule.FeeSplit memory f = _defaultFeeSplit();
        f.creator = address(0);
        vm.expectRevert(
            abi.encodeWithSelector(LaunchTaxModule.TaxRecipientMismatch.selector, address(0), FEE_CREATOR_BPS)
        );
        hook.configureFeeSplit(k, f);

        f = _defaultFeeSplit();
        f.integrator = address(0); // a share with nobody to pay
        vm.expectRevert(
            abi.encodeWithSelector(LaunchTaxModule.TaxRecipientMismatch.selector, address(0), FEE_INTEGRATOR_BPS)
        );
        hook.configureFeeSplit(k, f);

        f = _defaultFeeSplit();
        f.integratorBps = 0; // somebody to pay with no share
        f.creatorBps = 10_000 - FEE_PROTOCOL_BPS;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxRecipientMismatch.selector, feeIntegrator, uint16(0)));
        hook.configureFeeSplit(k, f);

        f = _defaultFeeSplit();
        f.creator = address(hook);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.InvalidTaxRecipient.selector, address(hook)));
        hook.configureFeeSplit(k, f);
        f = _defaultFeeSplit();
        f.integrator = address(hook);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.InvalidTaxRecipient.selector, address(hook)));
        hook.configureFeeSplit(k, f);
        assertEq(hook.getFeeSplit(id).protocolBps, 0, "nothing was written");

        // No integrator bucket at all is fine.
        f = _defaultFeeSplit();
        f.integratorBps = 0;
        f.integrator = address(0);
        f.creatorBps = 10_000 - FEE_PROTOCOL_BPS;
        hook.configureFeeSplit(k, f);
        assertEq(hook.getFeeSplit(id).integrator, address(0));
    }

    /// @dev The bounds make a creator-less split impossible: protocol <= 50% and integrator <= 20%
    /// leave the creator at least 30%. Every attempt at `creatorBps == 0` is refused by one of them.
    function test_feeSplit_aSplitWithNoCreatorShareCannotBeWritten() public {
        (PoolKey memory k, PoolId id) = _freshPool();
        LaunchTaxModule.FeeSplit memory f;
        f.integrator = feeIntegrator;
        f.protocolBps = 8_000;
        f.integratorBps = 2_000;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxProtocolShareOutOfBounds.selector, uint16(8_000)));
        hook.configureFeeSplit(k, f);
        f.protocolBps = 5_000;
        f.integratorBps = 5_000;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxIntegratorShareTooHigh.selector, uint16(5_000)));
        hook.configureFeeSplit(k, f);
        f.protocolBps = 5_000;
        f.integratorBps = 2_000;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxSplitDoesNotSum.selector, uint256(7_000)));
        hook.configureFeeSplit(k, f);
        assertEq(hook.getFeeSplit(id).protocolBps, 0);
    }

    /// @dev MUTATION-CHECKED (g): without the `FeeSplitNotConfigured` check the pool is created and
    /// every fee it takes lands in a pot with no split.
    function test_initialize_refusesAPoolWithoutAFeeSplit() public {
        (PoolKey memory k, PoolId id) = _freshPool();
        hook.configureTax(k, _validTax()); // a tax does not stand in for the split
        _expectHookRevert(
            ICLHooks.beforeInitialize.selector,
            abi.encodeWithSelector(LaunchTaxModule.FeeSplitNotConfigured.selector, id)
        );
        poolManager.initialize(k, SQRT_RATIO_1_1);

        hook.configureFeeSplit(k, _defaultFeeSplit());
        poolManager.initialize(k, SQRT_RATIO_1_1); // and with it, it is
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        assertEq(sqrtPriceX96, SQRT_RATIO_1_1);
    }

    /*//////////////////////////////////////////////////////////////
                   THE FEE SPLIT'S CREATOR CAN ROTATE

        Two steps, by the creator's own hand and the nominee's. Shares
        do not move, the integrator does not move, the tax's creator
        does not move, and what was credited stays where it was.
    //////////////////////////////////////////////////////////////*/

    address nominee = makeAddr("nominee");

    function test_feeCreator_twoStepHandover() public {
        assertEq(hook.pendingCreator(_id(poolId)), address(0));

        vm.expectEmit(true, true, true, true, address(hook));
        emit LaunchTaxModule.FeeCreatorTransferStarted(poolId, feeCreator, nominee);
        vm.prank(feeCreator);
        hook.transferCreator(_id(poolId), nominee);
        assertEq(hook.pendingCreator(_id(poolId)), nominee);
        assertEq(hook.getFeeSplit(poolId).creator, feeCreator, "nothing moves until the nominee accepts");

        vm.expectEmit(true, true, true, true, address(hook));
        emit LaunchTaxModule.FeeCreatorTransferred(poolId, feeCreator, nominee);
        vm.prank(nominee);
        hook.acceptCreator(_id(poolId));

        LaunchTaxModule.FeeSplit memory f = hook.getFeeSplit(poolId);
        assertEq(f.creator, nominee);
        assertEq(hook.pendingCreator(_id(poolId)), address(0), "the nomination is spent");
        // Shares and the integrator did not move.
        assertEq(f.creatorBps, FEE_CREATOR_BPS);
        assertEq(f.protocolBps, FEE_PROTOCOL_BPS);
        assertEq(f.integratorBps, FEE_INTEGRATOR_BPS);
        assertEq(f.integrator, feeIntegrator);
    }

    /// @dev It works on a pool whose configuration is frozen, which is the point: the fee is
    /// charged forever and a wallet is not.
    function test_feeCreator_rotatesOnAPoolThatIsTrading() public {
        _swap(key, true, AMOUNT, 0);
        assertTrue(hook.getLaunch(poolId).launched);
        vm.prank(feeCreator);
        hook.transferCreator(_id(poolId), nominee);
        vm.prank(nominee);
        hook.acceptCreator(_id(poolId));
        assertEq(hook.getFeeSplit(poolId).creator, nominee);
    }

    function test_feeCreator_onlyTheCreatorNominates() public {
        address[6] memory refused =
            [makeAddr("stranger"), feeIntegrator, PROTOCOL, creator, integrator, address(this)];
        for (uint256 i; i < refused.length; ++i) {
            vm.prank(refused[i]);
            vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.NotFeeCreator.selector, poolId, refused[i]));
            hook.transferCreator(_id(poolId), refused[i]);
        }
        assertEq(hook.launchOwner(poolId), address(this), "the launch owner is among the refused");
        assertEq(hook.pendingCreator(_id(poolId)), address(0));
        assertEq(hook.getFeeSplit(poolId).creator, feeCreator);

        // A nominee is nobody until it accepts.
        vm.prank(feeCreator);
        hook.transferCreator(_id(poolId), nominee);
        vm.prank(nominee);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.NotFeeCreator.selector, poolId, nominee));
        hook.transferCreator(_id(poolId), makeAddr("third"));
        assertEq(hook.pendingCreator(_id(poolId)), nominee);
    }

    function test_feeCreator_theGuardItselfCannotBeNominated() public {
        vm.prank(feeCreator);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.InvalidTaxRecipient.selector, address(hook)));
        hook.transferCreator(_id(poolId), address(hook));
        assertEq(hook.pendingCreator(_id(poolId)), address(0));
    }

    /// @dev MUTATION-CHECKED (j): without the nominee check a stranger completes the handover.
    function test_feeCreator_onlyTheNomineeAccepts() public {
        // Nothing pending: nobody accepts, the creator included.
        vm.prank(feeCreator);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.NotPendingFeeCreator.selector, poolId, feeCreator));
        hook.acceptCreator(_id(poolId));
        vm.prank(nominee);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.NotPendingFeeCreator.selector, poolId, nominee));
        hook.acceptCreator(_id(poolId));

        vm.prank(feeCreator);
        hook.transferCreator(_id(poolId), nominee);

        address[6] memory refused =
            [makeAddr("stranger"), feeCreator, feeIntegrator, PROTOCOL, creator, address(this)];
        for (uint256 i; i < refused.length; ++i) {
            vm.prank(refused[i]);
            vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.NotPendingFeeCreator.selector, poolId, refused[i]));
            hook.acceptCreator(_id(poolId));
        }
        assertEq(hook.getFeeSplit(poolId).creator, feeCreator, "nobody completed it for the nominee");
        assertEq(hook.pendingCreator(_id(poolId)), nominee);
    }

    function test_feeCreator_nominatingZeroWithdraws() public {
        vm.prank(feeCreator);
        hook.transferCreator(_id(poolId), nominee);

        vm.expectEmit(true, true, true, true, address(hook));
        emit LaunchTaxModule.FeeCreatorTransferStarted(poolId, feeCreator, address(0));
        vm.prank(feeCreator);
        hook.transferCreator(_id(poolId), address(0));
        assertEq(hook.pendingCreator(_id(poolId)), address(0));

        vm.prank(nominee);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.NotPendingFeeCreator.selector, poolId, nominee));
        hook.acceptCreator(_id(poolId));
        assertEq(hook.getFeeSplit(poolId).creator, feeCreator);
    }

    function test_feeCreator_aSecondNominationReplacesTheFirst() public {
        address second = makeAddr("second");
        vm.startPrank(feeCreator);
        hook.transferCreator(_id(poolId), nominee);
        hook.transferCreator(_id(poolId), second);
        vm.stopPrank();
        vm.prank(nominee);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.NotPendingFeeCreator.selector, poolId, nominee));
        hook.acceptCreator(_id(poolId));
        vm.prank(second);
        hook.acceptCreator(_id(poolId));
        assertEq(hook.getFeeSplit(poolId).creator, second);
    }

    function test_feeCreator_thePreviousCreatorHasNoPowerLeft() public {
        vm.prank(feeCreator);
        hook.transferCreator(_id(poolId), nominee);
        vm.prank(nominee);
        hook.acceptCreator(_id(poolId));

        vm.prank(feeCreator);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.NotFeeCreator.selector, poolId, feeCreator));
        hook.transferCreator(_id(poolId), feeCreator);
        // ...and the accepted nomination cannot be replayed.
        vm.prank(nominee);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.NotPendingFeeCreator.selector, poolId, nominee));
        hook.acceptCreator(_id(poolId));

        // The new creator can hand it on, back to the first one included.
        vm.prank(nominee);
        hook.transferCreator(_id(poolId), feeCreator);
        vm.prank(feeCreator);
        hook.acceptCreator(_id(poolId));
        assertEq(hook.getFeeSplit(poolId).creator, feeCreator);
    }

    /// @dev A pool with no split has no creator, so there is nobody who could call it: not the
    /// launch owner, and not even a caller that IS the zero address the record holds.
    function test_feeCreator_aPoolWithoutASplitHasNobodyToRotate() public {
        (, PoolId id) = _freshPool();
        assertEq(hook.getFeeSplit(id).creator, address(0));
        address[3] memory callers = [address(this), feeCreator, address(0)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.NotFeeCreator.selector, id, callers[i]));
            hook.transferCreator(_id(id), nominee);
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.NotPendingFeeCreator.selector, id, callers[i]));
            hook.acceptCreator(_id(id));
        }
        assertEq(hook.pendingCreator(_id(id)), address(0));
    }

    /// @dev The signatures are the lockers', which is what lets a contract written against a lock
    /// take the fee's creator role and collect it: accepted by `acceptCreator(uint256)`, collected
    /// by `claim(Currency,address)`.
    function test_feeCreator_aContractAcceptsAndCollectsThroughTheLockersSignatures() public {
        assertEq(hook.transferCreator.selector, bytes4(keccak256("transferCreator(uint256,address)")));
        assertEq(hook.acceptCreator.selector, bytes4(keccak256("acceptCreator(uint256)")));
        assertEq(hook.pendingCreator.selector, bytes4(keccak256("pendingCreator(uint256)")));
        assertEq(hook.claim.selector, bytes4(keccak256("claim(address,address)")), "Currency is an address");

        SplitLike split = new SplitLike();
        vm.prank(feeCreator);
        hook.transferCreator(_id(poolId), address(split));
        // Anybody may ask the split to accept; it is the split that calls, so it is the nominee.
        vm.prank(makeAddr("anybody"));
        split.accept(address(hook), _id(poolId));
        assertEq(hook.getFeeSplit(poolId).creator, address(split));

        _swap(key, true, AMOUNT, 0);
        hook.settleFee(poolId, currency0);
        uint256 due = _share(_buyFee(0.003 ether, 1 ether, FINAL_FEE), FEE_CREATOR_BPS);
        assertEq(hook.claimable(address(split), currency0), due);
        assertEq(split.collect(address(hook), currency0), due);
        assertEq(currency0.balanceOf(address(split)), due);
        _assertSolvent(currency0);
    }

    /// @dev The rotation takes the pool id as a NUMBER, so that a deployed `DeepCoreSplit` can accept
    /// it through the lockers' `acceptCreator(uint256)`. The number is the pool id, bit for bit:
    /// an id with its top bit set comes back as the same typed id in the events and the errors,
    /// and neither a neighbouring number nor the zero id reaches anybody's split.
    function test_feeCreator_theIdRoundTrips() public {
        // A claimed pool whose id has its top bit set (a pool id is a hash: every other one has).
        PoolKey memory k;
        PoolId id;
        for (int24 spacing = 200; spacing < 400; ++spacing) {
            k = _key(currency0, currency1, hook, spacing);
            id = k.toId();
            if (uint256(PoolId.unwrap(id)) >> 255 == 1) break;
        }
        uint256 n = uint256(PoolId.unwrap(id));
        assertEq(n >> 255, 1, "no pool id with its top bit set among two hundred");
        assertEq(PoolId.unwrap(PoolId.wrap(bytes32(n))), PoolId.unwrap(id));
        hook.configureLaunch(k, _defaultConfigAt(uint40(vm.getBlockTimestamp() + 10)));
        hook.configureFeeSplit(k, _defaultFeeSplit());

        // Refused for anybody but the creator, and the error names the pool by its typed id.
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.NotFeeCreator.selector, id, address(this)));
        hook.transferCreator(n, nominee);
        vm.prank(nominee);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.NotPendingFeeCreator.selector, id, nominee));
        hook.acceptCreator(n);

        vm.expectEmit(true, true, true, true, address(hook));
        emit LaunchTaxModule.FeeCreatorTransferStarted(id, feeCreator, nominee);
        vm.prank(feeCreator);
        hook.transferCreator(n, nominee);
        assertEq(hook.pendingCreator(n), nominee);

        // The same number without its top bit, and its neighbours, are other pools: no split there,
        // so no creator, no nominee, and nothing of this pool's within reach.
        uint256[3] memory others = [n & (type(uint256).max >> 1), n + 1, n - 1];
        for (uint256 i; i < others.length; ++i) {
            PoolId other = PoolId.wrap(bytes32(others[i]));
            assertEq(hook.pendingCreator(others[i]), address(0));
            vm.prank(feeCreator);
            vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.NotFeeCreator.selector, other, feeCreator));
            hook.transferCreator(others[i], nominee);
            vm.prank(nominee);
            vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.NotPendingFeeCreator.selector, other, nominee));
            hook.acceptCreator(others[i]);
        }

        vm.expectEmit(true, true, true, true, address(hook));
        emit LaunchTaxModule.FeeCreatorTransferred(id, feeCreator, nominee);
        vm.prank(nominee);
        hook.acceptCreator(n);
        assertEq(hook.getFeeSplit(id).creator, nominee);
        assertEq(hook.pendingCreator(n), address(0));
        // The suite's own pool, a different number, was not touched.
        assertEq(hook.getFeeSplit(poolId).creator, feeCreator);
        assertEq(hook.pendingCreator(_id(poolId)), address(0));
    }

    /// @dev The zero id is no pool: it has no split, so no creator and no nominee, whoever asks -
    /// the zero address included, which is what its empty record holds.
    function test_feeCreator_theZeroIdIsRefused() public {
        PoolId zero = PoolId.wrap(bytes32(0));
        assertEq(hook.getFeeSplit(zero).creator, address(0));
        assertEq(hook.pendingCreator(0), address(0));
        address[4] memory callers = [address(this), feeCreator, nominee, address(0)];
        for (uint256 i; i < callers.length; ++i) {
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.NotFeeCreator.selector, zero, callers[i]));
            hook.transferCreator(0, nominee);
            vm.prank(callers[i]);
            vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.NotPendingFeeCreator.selector, zero, callers[i]));
            hook.acceptCreator(0);
        }
        assertEq(hook.pendingCreator(0), address(0));
        assertEq(hook.getFeeSplit(zero).creator, address(0));
    }

    /// @dev A pot settled BEFORE the handover credits the previous creator; a pot settled AFTER it
    /// credits the new one, even though it was taken earlier; what was credited stays claimable.
    function test_feeCreator_settleBeforeAndAfterTheHandover() public {
        _swap(key, true, AMOUNT, 0);
        uint256 pot1 = hook.pendingFee(poolId, currency0);
        assertEq(pot1, _buyFee(0.003 ether, 1 ether, FINAL_FEE), "0.30% of one ether of quote");
        hook.settleFee(poolId, currency0);
        uint256 oldShare = pot1 * FEE_CREATOR_BPS / 10_000;
        assertEq(hook.claimable(feeCreator, currency0), oldShare);

        // A second pot is taken while the first creator is still the creator...
        _swap(key, true, AMOUNT, 0);
        uint256 pot2 = hook.pendingFee(poolId, currency0);
        assertEq(pot2, _buyFee(0.003 ether, 1 ether, FINAL_FEE));

        vm.prank(feeCreator);
        hook.transferCreator(_id(poolId), nominee);
        // (a nomination alone changes nothing about who is paid)
        assertEq(hook.claimable(nominee, currency0), 0);
        vm.prank(nominee);
        hook.acceptCreator(_id(poolId));

        // ...and is settled after the handover: it is the new creator's.
        uint256 owedBefore = hook.totalOwed(currency0);
        hook.settleFee(poolId, currency0);
        assertEq(hook.claimable(nominee, currency0), pot2 * FEE_CREATOR_BPS / 10_000, "settled for the creator of the moment");
        assertEq(hook.claimable(feeCreator, currency0), oldShare, "what was credited stays credited");
        assertEq(hook.totalOwed(currency0), owedBefore, "a handover moves no value");

        vm.prank(feeCreator);
        assertEq(hook.claim(currency0, feeCreator), oldShare);
        assertEq(currency0.balanceOf(feeCreator), oldShare);
        vm.prank(nominee);
        hook.claim(currency0, nominee);
        assertEq(currency0.balanceOf(nominee), pot2 * FEE_CREATOR_BPS / 10_000);
        _assertSolvent(currency0);
        _assertLedgerSums(currency0);
    }

    /// @dev The tax has its own creator. Rotating the fee's does not touch it, even when the two
    /// were the same address to begin with.
    function test_feeCreator_theTaxCreatorIsNotAffected() public {
        Pool memory p = _reserve(currency0, currency1, false);
        LaunchTaxModule.FeeSplit memory f = _defaultFeeSplit();
        f.creator = creator; // the same wallet on both records
        _open(p, _defaultConfigAt(uint40(vm.getBlockTimestamp())), f, _validTax());

        vm.prank(creator);
        hook.transferCreator(_id(p.id), nominee);
        vm.prank(nominee);
        hook.acceptCreator(_id(p.id));
        assertEq(hook.getFeeSplit(p.id).creator, nominee);
        assertEq(hook.getTax(p.id).creator, creator, "the tax's creator did not move");

        vm.warp(vm.getBlockTimestamp() + DECAY_SECONDS);
        _swap(p.key, true, AMOUNT, 0);
        uint256 feePot = hook.pendingFee(p.id, currency0);
        uint256 taxPot = hook.pendingTax(p.id, currency0);
        assertEq(feePot, _buyFee(0.003 ether, 1 ether, FINAL_FEE));
        assertEq(taxPot, 0.05 ether);
        hook.settleFee(p.id, currency0);
        hook.settleTax(p.id, currency0);
        assertEq(hook.claimable(nominee, currency0), feePot * FEE_CREATOR_BPS / 10_000, "the fee follows the handover");
        assertEq(hook.claimable(creator, currency0), taxPot * 7_000 / 10_000, "the tax does not");

        // And the new fee creator has no say over the tax.
        assertEq(hook.getTax(p.id).creatorBps, 7_000);
    }

    /*//////////////////////////////////////////////////////////////
                              THE BITMAP
    //////////////////////////////////////////////////////////////*/

    function test_bitmap() public view {
        // bit 0 | bit 6 | bit 7 | bit 10 (beforeSwapReturnsDelta) | bit 11 (afterSwapReturnsDelta)
        assertEq(hook.getHooksRegistrationBitmap(), 0x0CC1);
    }

    /// @dev Bit 10 is what makes core honour the delta `beforeSwap` returns. Under the bitmap the
    /// guard carried before (0x08C1) the constructor still validates, but core ignores the delta of
    /// an exact-input buy while the guard has already minted itself the claim. The pool then trades
    /// the whole amount named, not the amount less the take, and the guard's own `afterSwap` check
    /// refuses it (without that check the vault lock could not settle: `CurrencyNotSettled`). The
    /// two shapes charged in `afterSwap` still trade.
    function test_bitmap_withoutBit10ABuyCannotSettle() public {
        PreFeeBitmapHook old = new PreFeeBitmapHook(poolManager); // `_validatePermissions` passed
        assertEq(old.getHooksRegistrationBitmap(), 0x08C1);
        PoolKey memory k = _key(currency0, currency1, old, 1);
        LaunchGuardHook.LaunchConfig memory c = _defaultConfigAt(uint40(vm.getBlockTimestamp()));
        old.configureLaunch(k, c);
        old.configureFeeSplit(k, _defaultFeeSplit());
        poolManager.initialize(k, SQRT_RATIO_1_1);
        _seed(k, 0);

        // No tax on this pool, and the launch opens now: INITIAL_FEE, 3% of 1 ether. Core traded
        // the 1 ether named.
        _expectRevertFrom(address(old), abi.encodeWithSelector(LaunchTaxModule.SwapNotFilled.selector, 0.97 ether, 1 ether));
        _swap(k, true, -1 ether, 0); // exact-input buy: charged in beforeSwap
        _expectRevertFrom(address(old), abi.encodeWithSelector(LaunchTaxModule.SwapNotFilled.selector, 1.03 ether, 1 ether));
        _swap(k, false, 1 ether, 0); // exact-output sell: charged in beforeSwap

        _swap(k, false, AMOUNT, 0); // exact-input sell: afterSwap, bit 11
        _swap(k, true, 1 ether, 0); // exact-output buy: afterSwap, bit 11
        assertGt(old.pendingFee(k.toId(), currency0), 0);
    }

    /*//////////////////////////////////////////////////////////////
                              THE SWAP PATH

        swap                 quote is         taken in      base of fee and tax
        buy,  exact input    specified (in)   beforeSwap    the quote the trader sends
        sell, exact input    unspecified      afterSwap     the quote the pool pays out
        buy,  exact output   unspecified      afterSwap     the quote the pool asks for
        sell, exact output   specified (out)  beforeSwap    the quote the trader asked for
    //////////////////////////////////////////////////////////////*/

    /// @dev Buy, exact input, with the numbers written out. One ether of quote in: 0.30% fee and 5%
    /// buy tax, both of that one ether; the pool is handed the remaining 0.947.
    function test_swap_exactInBuy_isChargedInTheQuoteItSends() public {
        Pool memory p = _default();
        Expected memory e = _predict(p, true, true, 1 ether, FINAL_FEE, BUY_BPS);
        assertEq(e.fee, _buyFee(0.003 ether, 1 ether, FINAL_FEE));
        assertEq(e.tax, 0.05 ether);
        assertEq(e.poolQuote, -int256(1 ether - e.fee - 0.05 ether), "the pool is handed the amount less the take");

        vm.expectEmit(true, true, false, true, address(hook));
        emit LaunchTaxModule.FeeTaken(poolId, currency0, true, e.fee);
        vm.expectEmit(true, true, false, true, address(hook));
        emit LaunchTaxModule.TaxTaken(poolId, currency0, true, 0.05 ether);
        Outcome memory o = _trade(p, true, true, 1 ether);
        _assertMatches(p, e, o);

        assertEq(o.traderQuote, -1 ether, "the trader pays exactly what it named");
        assertEq(hook.pendingFee(poolId, currency0), e.fee);
        assertEq(hook.pendingTax(poolId, currency0), 0.05 ether);
        assertEq(vault.balanceOf(address(hook), currency0), e.fee + 0.05 ether, "held as vault claims");
        assertEq(vault.balanceOf(address(hook), currency1), 0, "and none in the launch token");
        assertEq(hook.pendingFee(poolId, currency1) + hook.pendingTax(poolId, currency1), 0);
    }

    /// @dev Sell, exact input: the quote is what the pool pays out, and the rates apply to that.
    function test_swap_exactInSell_isChargedInTheQuoteItReceives() public {
        Pool memory p = _default();
        Expected memory e = _predict(p, false, true, 1 ether, FINAL_FEE, SELL_BPS);
        assertGt(e.poolQuote, 0.99 ether, "a one-ether sell at ~1:1 with no LP fee");
        assertEq(e.fee, uint256(e.poolQuote) * 3_000 / 1_000_000);
        assertEq(e.tax, uint256(e.poolQuote) * 300 / 10_000, "the SELL rate");

        vm.expectEmit(true, true, false, true, address(hook));
        emit LaunchTaxModule.FeeTaken(poolId, currency0, false, e.fee);
        vm.expectEmit(true, true, false, true, address(hook));
        emit LaunchTaxModule.TaxTaken(poolId, currency0, false, e.tax);
        Outcome memory o = _trade(p, false, true, 1 ether);
        _assertMatches(p, e, o);

        assertEq(o.traderToken, -1 ether, "every launch token the seller sent reached the pool");
        assertEq(o.poolToken, -1 ether);
        assertEq(o.traderQuote, e.poolQuote - int256(e.fee + e.tax), "paid the pool's quote less fee and tax");
    }

    /// @dev Buy, exact output: the trader names the launch token it wants; the quote the pool asks
    /// for is the base, and the trader pays it plus fee and tax.
    function test_swap_exactOutBuy_isChargedOnTopOfTheQuoteThePoolAsksFor() public {
        Pool memory p = _default();
        (Expected memory e, Outcome memory o) = _assertShape(p, true, false, 1 ether, FINAL_FEE, BUY_BPS);
        assertEq(o.traderToken, 1 ether, "exactly the launch token asked for");
        assertLt(e.poolQuote, -1 ether);
        assertEq(e.fee, _guardFee(_abs(e.poolQuote), 3_000, true));
        assertEq(e.tax, _abs(e.poolQuote) * 500 / 10_000, "the BUY rate");
        assertEq(o.traderQuote, e.poolQuote - int256(e.fee + e.tax));
    }

    /// @dev Sell, exact output: the trader names the quote it wants and receives exactly that; the
    /// pool pays out the take on top, and asks for the launch token that costs.
    function test_swap_exactOutSell_receivesExactlyTheQuoteItAskedFor() public {
        Pool memory p = _default();
        Expected memory e = _predict(p, false, false, 1 ether, FINAL_FEE, SELL_BPS);
        assertEq(e.fee, 0.003 ether);
        assertEq(e.tax, 0.03 ether, "the SELL rate");
        assertEq(e.poolQuote, 1.033 ether, "the pool pays out the amount plus the take");
        Outcome memory o = _trade(p, false, false, 1 ether);
        _assertMatches(p, e, o);
        assertEq(o.traderQuote, 1 ether);
        assertLt(o.traderToken, -1.033 ether, "and the seller funds all of it in launch token");
    }

    /// @dev The same four shapes with the launch token as currency0: every direction flips, and
    /// the quote is currency1. MUTATION-CHECKED (a, b, d): a take on the wrong side, in the launch
    /// token, or skipped on one shape each fail here and in the four tests above.
    function test_swap_fourShapes_launchTokenIsCurrency0() public {
        Pool memory p = _launch(true, _defaultConfigAt(uint40(vm.getBlockTimestamp())), _validTax());
        assertEq(Currency.unwrap(p.quote), Currency.unwrap(currency1));
        vm.warp(vm.getBlockTimestamp() + DECAY_SECONDS);

        (Expected memory e, Outcome memory o) = _assertShape(p, true, true, 1 ether, FINAL_FEE, BUY_BPS);
        assertEq(e.fee + e.tax, _buyFee(0.003 ether, 1 ether, FINAL_FEE) + 0.05 ether);
        assertEq(o.traderQuote, -1 ether);

        (e, o) = _assertShape(p, false, true, 1 ether, FINAL_FEE, SELL_BPS);
        assertEq(o.traderToken, -1 ether);
        assertGt(e.fee, 0);
        assertGt(e.tax, 0);

        (e, o) = _assertShape(p, true, false, 1 ether, FINAL_FEE, BUY_BPS);
        assertEq(o.traderToken, 1 ether);
        assertGt(e.fee, 0);

        (e, o) = _assertShape(p, false, false, 1 ether, FINAL_FEE, SELL_BPS);
        assertEq(e.fee + e.tax, 0.033 ether);
        assertEq(o.traderQuote, 1 ether);

        // Four swaps later the guard holds quote only.
        assertEq(vault.balanceOf(address(hook), currency0), 0, "currency0 is the launch token here");
        assertEq(hook.feeTaken(p.id, currency0) + hook.totalTaken(p.id, currency0), 0);
        assertEq(hook.grossTaken(currency0), 0);
        assertGt(hook.feeTaken(p.id, currency1), 0);
    }

    function test_swap_fourShapes_launchTokenIsCurrency1() public {
        Pool memory p = _default();
        _assertShape(p, true, true, 0.37 ether, FINAL_FEE, BUY_BPS);
        _assertShape(p, false, true, 0.37 ether, FINAL_FEE, SELL_BPS);
        _assertShape(p, true, false, 0.37 ether, FINAL_FEE, BUY_BPS);
        _assertShape(p, false, false, 0.37 ether, FINAL_FEE, SELL_BPS);
        assertEq(vault.balanceOf(address(hook), currency1), 0, "currency1 is the launch token here");
        assertEq(hook.feeTaken(poolId, currency1) + hook.totalTaken(poolId, currency1), 0);
        assertEq(hook.grossTaken(currency1), 0);
    }

    /// @dev A pool with no tax still pays the fee, and writes nothing to the tax's ledger.
    function test_swap_untaxedPoolTakesTheFeeOnly() public {
        Pool memory p = _launch(false, _defaultConfigAt(uint40(vm.getBlockTimestamp())), _zeroTax());
        vm.warp(vm.getBlockTimestamp() + DECAY_SECONDS);
        bool[2] memory flags = [true, false];
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 2; ++j) {
                Expected memory e = _predict(p, flags[i], flags[j], 1 ether, FINAL_FEE, 0);
                vm.recordLogs();
                Outcome memory o = _trade(p, flags[i], flags[j], 1 ether);
                _assertMatches(p, e, o);
                assertGt(o.fee, 0);
                assertEq(o.tax, 0);
            }
        }
        assertEq(hook.totalTaken(p.id, currency0), 0);
        assertEq(hook.pendingTax(p.id, currency0), 0);
    }

    function test_swap_aPoolWithNoTaxEmitsNoTaxTaken() public {
        Pool memory p = _launch(false, _defaultConfigAt(uint40(vm.getBlockTimestamp())), _zeroTax());
        vm.recordLogs();
        _swap(p.key, true, AMOUNT, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool fee;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook)) continue;
            assertTrue(logs[i].topics[0] != LaunchTaxModule.TaxTaken.selector, "TaxTaken on an untaxed pool");
            if (logs[i].topics[0] == LaunchTaxModule.FeeTaken.selector) fee = true;
        }
        assertTrue(fee, "the fee was taken");
    }

    function test_expiry_taxStopsAtExpiresAtWithNoTransaction() public {
        Pool memory p = _default();
        vm.warp(EXPIRES_AT - 1);
        (, Outcome memory o) = _assertShape(p, true, true, 1 ether, FINAL_FEE, BUY_BPS);
        assertEq(o.tax, 0.05 ether, "the last taxed second");
        uint256 pot = hook.pendingTax(poolId, currency0);
        (uint16 b,) = hook.currentTaxRates(poolId);
        assertEq(b, BUY_BPS);

        vm.warp(EXPIRES_AT);
        (b,) = hook.currentTaxRates(poolId);
        assertEq(b, 0, "rates read zero at expiry");
        (uint16 bAt, uint16 sAt) = hook.taxRatesAt(poolId, EXPIRES_AT);
        assertEq(bAt + sAt, 0);

        // Every shape: the tax is gone, the fee is not.
        (, o) = _assertShape(p, true, true, 1 ether, FINAL_FEE, 0);
        assertEq(o.fee, _buyFee(0.003 ether, 1 ether, FINAL_FEE));
        _assertShape(p, false, true, 1 ether, FINAL_FEE, 0);
        _assertShape(p, true, false, 1 ether, FINAL_FEE, 0);
        _assertShape(p, false, false, 1 ether, FINAL_FEE, 0);
        assertEq(hook.pendingTax(poolId, currency0), pot, "pot unchanged after expiry");
        // The stored terms survive for readers; only their effect ends.
        assertEq(hook.getTax(poolId).buyBps, BUY_BPS);
    }

    /// @dev Fee and tax are each a rate on the SAME base and neither is charged on the other: at
    /// the opening a buy of one ether pays 3% + 5% = 8% of one ether, never 3% and then 5% of 0.97.
    function test_swap_feeAndTaxShareOneBase() public {
        uint40 start = uint40(vm.getBlockTimestamp() + 10);
        Pool memory p = _launch(false, _defaultConfigAt(start), _validTax());
        vm.warp(start);
        (Expected memory e, Outcome memory o) = _assertShape(p, true, true, 1 ether, INITIAL_FEE, BUY_BPS);
        assertEq(o.fee, _buyFee(0.03 ether, 1 ether, INITIAL_FEE), "the opening fee, on the whole amount");
        assertEq(o.tax, 0.05 ether, "the tax, on the whole amount");
        assertEq(e.poolQuote, -int256(1 ether - o.fee - o.tax));

        // The afterSwap shapes behave the same: both rates on the pool's quote amount.
        (e, o) = _assertShape(p, false, true, 1 ether, INITIAL_FEE, SELL_BPS);
        assertEq(o.fee, uint256(e.poolQuote) * 30_000 / 1_000_000);
        assertEq(o.tax, uint256(e.poolQuote) * 300 / 10_000);
    }

    /// @dev The fee decays; the tax rate does not. Mid-window and at the two ends of it.
    function test_swap_feeDecaysUnderAConstantTax() public {
        uint40 start = uint40(vm.getBlockTimestamp() + 10);
        Pool memory p = _launch(false, _defaultConfigAt(start), _validTax());

        vm.warp(start + 50);
        assertEq(_decayed(INITIAL_FEE, FINAL_FEE, 50, DECAY_SECONDS), 16_500);
        (, Outcome memory o) = _assertShape(p, true, true, 1 ether, 16_500, BUY_BPS);
        assertEq(o.fee, _buyFee(0.0165 ether, 1 ether, 16_500));
        assertEq(o.tax, 0.05 ether);

        vm.warp(start + DECAY_SECONDS - 1); // the last second of the window
        assertEq(_decayed(INITIAL_FEE, FINAL_FEE, DECAY_SECONDS - 1, DECAY_SECONDS), 3_270);
        (, o) = _assertShape(p, true, true, 1 ether, 3_270, BUY_BPS);
        assertEq(o.fee, _buyFee(0.00327 ether, 1 ether, 3_270));

        vm.warp(start + DECAY_SECONDS);
        (, o) = _assertShape(p, true, true, 1 ether, FINAL_FEE, BUY_BPS);
        assertEq(o.fee, _buyFee(0.003 ether, 1 ether, FINAL_FEE));
        assertEq(o.tax, 0.05 ether);
    }

    /*//////////////////////////////////////////////////////////////
                    THE CAPS: 50% FEE + 10% TAX = 60%

        Core reverts `HookDeltaExceedsSwapAmount` when a hook's
        specified delta exceeds the swap. At both caps the guard takes
        60% of the quote amount, on every shape, and nothing reverts.
    //////////////////////////////////////////////////////////////*/

    function _capsPool(bool tokenIs0) internal returns (Pool memory p) {
        LaunchGuardHook.LaunchConfig memory c = _defaultConfigAt(uint40(vm.getBlockTimestamp()));
        c.initialFeeBips = hook.MAX_INITIAL_FEE();
        c.finalFeeBips = hook.MAX_FINAL_FEE();
        LaunchTaxModule.TaxConfig memory t = _validTax();
        t.buyBps = hook.MAX_TAX_BPS();
        t.sellBps = hook.MAX_TAX_BPS();
        p = _launch(tokenIs0, c, t);
    }

    function test_CAPS_sixtyPercentAtTheOpening_everyShape() public {
        assertEq(hook.MAX_INITIAL_FEE(), 500_000);
        assertEq(hook.MAX_TAX_BPS(), 1_000);
        for (uint256 side; side < 2; ++side) {
            Pool memory p = _capsPool(side == 1);
            // Opens this second: the fee is the opening fee.
            (Expected memory e, Outcome memory o) = _assertShape(p, true, true, 1 ether, 500_000, 1_000);
            assertEq(o.fee, _buyFee(0.5 ether, 1 ether, 500_000));
            assertEq(o.tax, 0.1 ether);
            assertEq(e.poolQuote, -int256(1 ether - o.fee - o.tax), "what is left of the buy reaches the pool: 40% with no share");
            assertEq(o.traderQuote, -1 ether);

            (e, o) = _assertShape(p, false, true, 1 ether, 500_000, 1_000);
            assertEq(o.fee + o.tax, uint256(e.poolQuote) * 5 / 10 + uint256(e.poolQuote) / 10);
            assertEq(o.traderQuote, e.poolQuote - int256(o.fee + o.tax), "the seller keeps 40% of the quote");

            (e, o) = _assertShape(p, true, false, 0.2 ether, 500_000, 1_000);
            assertEq(o.traderToken, 0.2 ether);
            assertEq(o.traderQuote, e.poolQuote - int256(o.fee + o.tax), "the buyer pays 160% of the pool's price");

            (e, o) = _assertShape(p, false, false, 1 ether, 500_000, 1_000);
            assertEq(o.fee, 0.5 ether);
            assertEq(o.tax, 0.1 ether);
            assertEq(e.poolQuote, 1.6 ether, "the pool pays out 160% of what was asked");
            assertEq(o.traderQuote, 1 ether);
        }
    }

    /// @dev After the window the permanent fee is at most 10%, and with the tax 20%.
    function test_CAPS_finalFeeCapWithTheTaxCap() public {
        Pool memory p = _capsPool(false);
        vm.warp(vm.getBlockTimestamp() + DECAY_SECONDS);
        (, Outcome memory o) = _assertShape(p, true, true, 1 ether, 100_000, 1_000);
        assertEq(o.fee + o.tax, _buyFee(0.1 ether, 1 ether, 100_000) + 0.1 ether);
        _assertShape(p, false, true, 1 ether, 100_000, 1_000);
        _assertShape(p, true, false, 1 ether, 100_000, 1_000);
        _assertShape(p, false, false, 1 ether, 100_000, 1_000);
    }

    /*//////////////////////////////////////////////////////////////
               DUST: ONE WEI, AND AMOUNTS THAT FLOOR TO ZERO

        Both rates floor, so the rounding wei stays with the trader.
        A take of zero writes nothing and emits nothing.
    //////////////////////////////////////////////////////////////*/

    function test_DUST_oneWeiSwaps() public {
        Pool memory p = _capsPool(false); // at both caps, so every wei that can be taken is

        // One wei of QUOTE named by the trader: floor(1 * 50%) + floor(1 * 10%) == 0. Nothing is
        // taken, nothing is written, and the whole wei reaches the pool.
        (Expected memory e, Outcome memory o) = _assertShape(p, true, true, 1, 500_000, 1_000);
        assertEq(o.fee + o.tax, 0, "a wei cannot be taxed");
        assertEq(e.poolQuote, -1);
        (e, o) = _assertShape(p, false, false, 1, 500_000, 1_000);
        assertEq(o.fee + o.tax, 0, "a wei cannot be taxed");
        assertEq(e.poolQuote, 1);
        assertEq(o.traderQuote, 1);
        assertEq(hook.grossTaken(currency0), 0);
        assertEq(vault.balanceOf(address(hook), currency0), 0);

        // One wei of LAUNCH TOKEN sold: the pool pays out nothing at all, so there is no base.
        (e, o) = _assertShape(p, false, true, 1, 500_000, 1_000);
        assertEq(e.base, 0);
        assertEq(o.fee + o.tax, 0);
        assertEq(hook.grossTaken(currency0), 0);

        // One wei of LAUNCH TOKEN bought: core rounds the price UP to two wei of quote, and that is
        // the base. 50% of two is one; 10% of two floors to zero. The buyer pays three.
        (e, o) = _assertShape(p, true, false, 1, 500_000, 1_000);
        // (With a share the pool charges its own part on top of the two wei, and core rounds that up
        // into the base as well.)
        if (_lpShareBps() == 0) {
            assertEq(e.base, 2);
            assertEq(o.fee, 1);
            assertEq(o.traderQuote, -3);
        }
        assertEq(o.fee, _guardFee(e.base, 500_000, true));
        assertEq(o.tax, e.base * 1_000 / 10_000);
        assertEq(o.traderQuote, -int256(e.base + o.fee + o.tax));
        assertEq(o.traderToken, 1);
    }

    /// @dev The largest amounts on which each rate still floors to zero, and the first on which it
    /// does not: 0.30% needs 334 wei of quote to take one, 5% needs 20.
    function test_DUST_eachRateFloorsOnItsOwn() public {
        Pool memory p = _default();
        (, Outcome memory o) = _assertShape(p, true, true, 19, FINAL_FEE, BUY_BPS);
        assertEq(o.fee + o.tax, 0, "19 wei: both floor to zero");
        assertEq(o.traderQuote, -19);

        (, o) = _assertShape(p, true, true, 20, FINAL_FEE, BUY_BPS);
        assertEq(o.fee, 0);
        assertEq(o.tax, 1, "20 wei: the tax takes its first wei, the fee still none");

        (, o) = _assertShape(p, true, true, 333, FINAL_FEE, BUY_BPS);
        assertEq(o.fee, 0);
        assertEq(o.tax, 16);

        (, o) = _assertShape(p, true, true, 334, FINAL_FEE, BUY_BPS);
        assertEq(o.fee, _buyFee(1, 334, FINAL_FEE), "334 wei: the fee takes its first");
        assertEq(o.tax, 16);

        // The same on the quote the trader asks for.
        (, o) = _assertShape(p, false, false, 33, FINAL_FEE, SELL_BPS);
        assertEq(o.fee + o.tax, 0, "3% of 33 floors to zero");
        assertEq(o.traderQuote, 33);
        (, o) = _assertShape(p, false, false, 34, FINAL_FEE, SELL_BPS);
        assertEq(o.tax, 1);
    }

    function test_DUST_aZeroTakeEmitsNothing() public {
        vm.recordLogs();
        _swap(key, true, -19, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(hook)) continue;
            // `LaunchStarted` is the guard's, on the pool's first swap. No take, no take event.
            assertTrue(logs[i].topics[0] != LaunchTaxModule.FeeTaken.selector, "FeeTaken on a zero take");
            assertTrue(logs[i].topics[0] != LaunchTaxModule.TaxTaken.selector, "TaxTaken on a zero take");
        }
        assertEq(hook.feeTaken(poolId, currency0) + hook.totalTaken(poolId, currency0), 0);
        assertEq(hook.grossTaken(currency0), 0);
    }

    /*//////////////////////////////////////////////////////////////
                    SETTLEMENT AND CLAIMS: THE TAX POT
    //////////////////////////////////////////////////////////////*/

    function test_settle_splitsByBucketsWithRemainderToProtocol() public {
        _swap(key, true, AMOUNT, 0);
        uint256 pot = hook.pendingTax(poolId, currency0);
        uint256 feePot = hook.pendingFee(poolId, currency0);
        assertEq(pot, 0.05 ether);
        uint256 toCreator = pot * 7_000 / 10_000;
        uint256 toIntegrator = pot * 2_000 / 10_000;
        uint256 toProtocol = pot - toCreator - toIntegrator;

        vm.expectEmit(true, true, false, true, address(hook));
        emit LaunchTaxModule.TaxSettled(poolId, currency0, toCreator, toProtocol, toIntegrator);
        hook.settleTax(poolId, currency0);
        assertEq(hook.pendingTax(poolId, currency0), 0, "drained");
        assertEq(hook.claimable(creator, currency0), toCreator);
        assertEq(hook.claimable(integrator, currency0), toIntegrator);
        assertEq(hook.claimable(PROTOCOL, currency0), toProtocol);
        assertEq(hook.totalOwed(currency0), pot + feePot, "settlement moves nothing in or out");
        assertGe(toProtocol, pot / 10, "the floor is worth at least 10%");
        // The fee pot is a different pot, and the fee's parties were paid nothing by this.
        assertEq(hook.pendingFee(poolId, currency0), feePot);
        assertEq(hook.claimable(feeCreator, currency0) + hook.claimable(feeIntegrator, currency0), 0);
        _assertSolvent(currency0);
        _assertLedgerSums(currency0);

        hook.settleTax(poolId, currency0); // nothing to do: quiet
        assertEq(hook.claimable(PROTOCOL, currency0), toProtocol);
    }

    function test_settle_remainderNeverStrands() public {
        _swap(key, true, -12345678901, 0);
        uint256 pot = hook.pendingTax(poolId, currency0);
        assertEq(pot, 617283945); // floor(12345678901 * 5%)
        hook.settleTax(poolId, currency0);
        assertEq(
            hook.claimable(creator, currency0) + hook.claimable(integrator, currency0) + hook.claimable(PROTOCOL, currency0),
            pot
        );
        assertEq(hook.pendingTax(poolId, currency0), 0);
    }

    /*//////////////////////////////////////////////////////////////
                    SETTLEMENT AND CLAIMS: THE FEE POT

        The tax pot's tests, one for one, on the fee pot and by the
        fee split. MUTATION-CHECKED (i): `settleFee` reading the
        tax's split credits `creator` 70% instead of `feeCreator` 65%.
    //////////////////////////////////////////////////////////////*/

    function test_settleFee_splitsByTheFeeSplitWithRemainderToProtocol() public {
        _swap(key, true, AMOUNT, 0);
        uint256 pot = hook.pendingFee(poolId, currency0);
        uint256 taxPot = hook.pendingTax(poolId, currency0);
        assertEq(pot, _buyFee(0.003 ether, 1 ether, FINAL_FEE));
        uint256 toCreator = pot * FEE_CREATOR_BPS / 10_000;
        uint256 toIntegrator = pot * FEE_INTEGRATOR_BPS / 10_000;
        uint256 toProtocol = pot - toCreator - toIntegrator;
        if (_lpShareBps() == 0) {
            assertEq(toCreator, 0.00195 ether);
            assertEq(toIntegrator, 0.00045 ether);
            assertEq(toProtocol, 0.0006 ether);
        }

        vm.expectEmit(true, true, false, true, address(hook));
        emit LaunchTaxModule.FeeSettled(poolId, currency0, toCreator, toProtocol, toIntegrator);
        vm.prank(makeAddr("anybody")); // permissionless
        hook.settleFee(poolId, currency0);

        assertEq(hook.pendingFee(poolId, currency0), 0, "drained");
        assertEq(hook.feeSettled(poolId, currency0), pot);
        assertEq(hook.claimable(feeCreator, currency0), toCreator);
        assertEq(hook.claimable(feeIntegrator, currency0), toIntegrator);
        assertEq(hook.claimable(PROTOCOL, currency0), toProtocol);
        assertEq(hook.totalOwed(currency0), pot + taxPot, "settlement moves nothing in or out");
        assertGe(toProtocol, pot / 5, "the fee's floor is worth at least 20%");
        // The tax pot is a different pot, and the tax's parties were paid nothing by this.
        assertEq(hook.pendingTax(poolId, currency0), taxPot);
        assertEq(hook.claimable(creator, currency0) + hook.claimable(integrator, currency0), 0);
        _assertSolvent(currency0);
        _assertLedgerSums(currency0);

        hook.settleFee(poolId, currency0); // nothing to do: quiet
        assertEq(hook.claimable(PROTOCOL, currency0), toProtocol);
        assertEq(hook.feeSettled(poolId, currency0), pot);
    }

    function test_settleFee_remainderNeverStrands() public {
        _swap(key, true, -12345678901, 0);
        uint256 pot = hook.pendingFee(poolId, currency0);
        assertEq(pot, _buyFee(37037036, 12345678901, FINAL_FEE)); // floor(12345678901 * 0.30%) with no share
        hook.settleFee(poolId, currency0);
        uint256 toCreator = hook.claimable(feeCreator, currency0);
        uint256 toIntegrator = hook.claimable(feeIntegrator, currency0);
        assertEq(toCreator, _share(pot, FEE_CREATOR_BPS));
        assertEq(toIntegrator, _share(pot, FEE_INTEGRATOR_BPS));
        if (_lpShareBps() == 0) {
            assertEq(toCreator, 24074073); // floor(pot * 65%)
            assertEq(toIntegrator, 5555555); // floor(pot * 15%)
        }
        assertEq(hook.claimable(PROTOCOL, currency0), pot - toCreator - toIntegrator, "the rounding goes to the protocol");
        assertEq(hook.pendingFee(poolId, currency0), 0);
    }

    /// @dev A split with no integrator pays two parties and still drains the pot.
    function test_settleFee_withNoIntegratorBucket() public {
        Pool memory p = _reserve(currency0, currency1, false);
        LaunchTaxModule.FeeSplit memory f = _defaultFeeSplit();
        f.integrator = address(0);
        f.integratorBps = 0;
        f.creatorBps = 8_000;
        _open(p, _defaultConfigAt(uint40(vm.getBlockTimestamp())), f, _zeroTax());
        vm.warp(vm.getBlockTimestamp() + DECAY_SECONDS);
        _swap(p.key, true, AMOUNT, 0);
        hook.settleFee(p.id, currency0);
        uint256 pot = _buyFee(0.003 ether, 1 ether, FINAL_FEE);
        assertEq(hook.claimable(feeCreator, currency0), _share(pot, 8_000));
        assertEq(hook.claimable(PROTOCOL, currency0), pot - _share(pot, 8_000));
        if (_lpShareBps() == 0) {
            assertEq(hook.claimable(feeCreator, currency0), 0.0024 ether);
            assertEq(hook.claimable(PROTOCOL, currency0), 0.0006 ether);
        }
        assertEq(hook.claimable(address(0), currency0), 0, "nothing is credited to nobody");
        assertEq(hook.pendingFee(p.id, currency0), 0);
    }

    function test_settle_theTwoPotsSettleIndependently() public {
        _swap(key, true, AMOUNT, 0);
        _swap(key, false, AMOUNT, 0);
        uint256 feePot = hook.pendingFee(poolId, currency0);
        uint256 taxPot = hook.pendingTax(poolId, currency0);
        uint256 owed = hook.totalOwed(currency0);
        assertEq(owed, feePot + taxPot);
        assertEq(hook.grossTaken(currency0), feePot + taxPot, "grossTaken sums both");

        hook.settleFee(poolId, currency0);
        assertEq(hook.pendingFee(poolId, currency0), 0);
        assertEq(hook.pendingTax(poolId, currency0), taxPot, "untouched by settleFee");
        _assertLedgerSums(currency0);

        hook.settleTax(poolId, currency0);
        assertEq(hook.pendingTax(poolId, currency0), 0);
        assertEq(hook.totalOwed(currency0), owed);
        // PROTOCOL is on both splits and holds the sum of its two remainders.
        uint256 feeToProtocol = feePot - feePot * FEE_CREATOR_BPS / 10_000 - feePot * FEE_INTEGRATOR_BPS / 10_000;
        uint256 taxToProtocol = taxPot - taxPot * 7_000 / 10_000 - taxPot * 2_000 / 10_000;
        assertEq(hook.claimable(PROTOCOL, currency0), feeToProtocol + taxToProtocol);
        _assertLedgerSums(currency0);
        // Nothing was ever owed in the launch token.
        assertEq(hook.totalOwed(currency1), 0);
    }

    function test_claim_eachBucketPullsItsOwnBalanceOnce() public {
        _swap(key, true, AMOUNT, 0);
        hook.settleTax(poolId, currency0);
        hook.settleFee(poolId, currency0);
        uint256 owed = hook.totalOwed(currency0);
        address[5] memory parties = [creator, integrator, feeCreator, feeIntegrator, PROTOCOL];
        uint256 sum;
        for (uint256 i; i < parties.length; ++i) {
            uint256 c = hook.claimable(parties[i], currency0);
            assertGt(c, 0);
            sum += c;
            vm.expectEmit(true, true, false, true, address(hook));
            emit LaunchTaxModule.TaxClaimed(parties[i], currency0, parties[i], c);
            vm.prank(parties[i]);
            assertEq(hook.claim(currency0, parties[i]), c);
            assertEq(currency0.balanceOf(parties[i]), c);
            assertEq(hook.claimable(parties[i], currency0), 0);
            assertEq(hook.totalOwed(currency0), owed - sum);
            _assertSolvent(currency0);
            _assertLedgerSums(currency0);
        }
        assertEq(sum, owed, "the five balances were the whole obligation");
        assertEq(hook.totalOwed(currency0), 0);
        assertEq(vault.balanceOf(address(hook), currency0), 0, "every claim redeemed");
        assertEq(currency0.balanceOf(address(hook)), 0);

        vm.prank(feeCreator);
        vm.expectRevert(LaunchTaxModule.NothingToClaim.selector);
        hook.claim(currency0, feeCreator);
    }

    function test_claim_paysAThirdAddress() public {
        _swap(key, true, AMOUNT, 0);
        hook.settleFee(poolId, currency0);
        uint256 c = hook.claimable(feeIntegrator, currency0);
        address sink = makeAddr("sink");
        vm.prank(feeIntegrator);
        hook.claim(currency0, sink);
        assertEq(currency0.balanceOf(sink), c);
        assertEq(currency0.balanceOf(feeIntegrator), 0);
    }

    function test_claim_refusals() public {
        _swap(key, true, AMOUNT, 0);
        hook.settleTax(poolId, currency0);
        hook.settleFee(poolId, currency0);
        vm.prank(creator);
        vm.expectRevert(LaunchTaxModule.InvalidRecipient.selector);
        hook.claim(currency0, address(0));
        // audit B: claiming to the guard itself would forfeit the balance to `skim`
        vm.prank(creator);
        vm.expectRevert(LaunchTaxModule.InvalidRecipient.selector);
        hook.claim(currency0, address(hook));
        vm.prank(feeCreator);
        vm.expectRevert(LaunchTaxModule.InvalidRecipient.selector);
        hook.claim(currency0, address(0));
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(LaunchTaxModule.NothingToClaim.selector);
        hook.claim(currency0, makeAddr("stranger"));
        // Nobody is ever owed the launch token.
        vm.prank(feeCreator);
        vm.expectRevert(LaunchTaxModule.NothingToClaim.selector);
        hook.claim(currency1, feeCreator);
        // Before settlement there is nothing claimable, however large the pot.
        vm.prank(feeCreator);
        hook.claim(currency0, feeCreator);
        _swap(key, false, AMOUNT, 0);
        assertGt(hook.pendingFee(poolId, currency0), 0);
        vm.prank(feeCreator);
        vm.expectRevert(LaunchTaxModule.NothingToClaim.selector);
        hook.claim(currency0, feeCreator);
    }

    /// @dev `claimFrom` settles BOTH pots of every pool it is given, then pays the caller.
    function test_claimFrom_settlesBothPotsThenClaims() public {
        _swap(key, true, AMOUNT, 0);
        _swap(key, true, AMOUNT, 0);
        uint256 taxPot = hook.pendingTax(poolId, currency0);
        uint256 feePot = hook.pendingFee(poolId, currency0);
        PoolId[] memory ids = new PoolId[](2);
        ids[0] = poolId;
        ids[1] = poolId; // a repeated id settles once and is then a no-op

        vm.prank(feeCreator);
        uint256 got = hook.claimFrom(ids, currency0, feeCreator);
        assertEq(got, feePot * FEE_CREATOR_BPS / 10_000);
        assertEq(currency0.balanceOf(feeCreator), got);
        assertEq(hook.pendingFee(poolId, currency0), 0);
        assertEq(hook.pendingTax(poolId, currency0), 0, "the tax pot was settled by the same call");
        assertEq(hook.claimable(creator, currency0), taxPot * 7_000 / 10_000, "and waits for its own party");

        vm.prank(creator);
        assertEq(hook.claimFrom(ids, currency0, creator), taxPot * 7_000 / 10_000);

        vm.prank(makeAddr("nobody"));
        vm.expectRevert(LaunchTaxModule.NothingToClaim.selector);
        hook.claimFrom(ids, currency0, makeAddr("nobody"));
        _assertLedgerSums(currency0);
    }

    /// @dev One wallet that is the fee's creator on two pools collects both in one call.
    function test_claimFrom_acrossPools() public {
        Pool memory p2 = _launch(false, _defaultConfigAt(uint40(vm.getBlockTimestamp())), _zeroTax());
        vm.warp(vm.getBlockTimestamp() + DECAY_SECONDS);
        _swap(key, true, AMOUNT, 0);
        _swap(p2.key, true, -2 ether, 0);
        PoolId[] memory ids = new PoolId[](2);
        ids[0] = poolId;
        ids[1] = p2.id;
        vm.prank(feeCreator);
        uint256 got = hook.claimFrom(ids, currency0, feeCreator);
        assertEq(got, _share(_buyFee(0.003 ether, 1 ether, FINAL_FEE), FEE_CREATOR_BPS) + _share(_buyFee(0.006 ether, 2 ether, FINAL_FEE), FEE_CREATOR_BPS));
    }

    function test_redeem_isPermissionlessAndPaysNobody() public {
        _swap(key, true, AMOUNT, 0);
        uint256 claims = vault.balanceOf(address(hook), currency0);
        assertEq(claims, _buyFee(0.003 ether, 1 ether, FINAL_FEE) + 0.05 ether, "fee and tax, as vault claims");
        vm.expectEmit(true, false, false, true, address(hook));
        emit LaunchTaxModule.TaxRedeemed(currency0, claims);
        vm.prank(makeAddr("keeper"));
        assertEq(hook.redeem(currency0), claims);
        assertEq(vault.balanceOf(address(hook), currency0), 0);
        assertEq(currency0.balanceOf(address(hook)), claims);
        assertEq(hook.totalOwed(currency0), claims, "obligations unchanged");
        assertEq(hook.redeem(currency0), 0, "nothing left: quiet");
        assertEq(hook.redeem(currency1), 0, "and never anything in the launch token");
        _assertSolvent(currency0);
        // The claims then pay from real tokens, no lock needed.
        hook.settleTax(poolId, currency0);
        hook.settleFee(poolId, currency0);
        vm.prank(creator);
        hook.claim(currency0, creator);
        vm.prank(feeCreator);
        hook.claim(currency0, feeCreator);
        _assertSolvent(currency0);
        _assertLedgerSums(currency0);
    }

    function test_skim_creditsOnlyTheProtocolAndOnlyTheSurplus() public {
        _swap(key, true, AMOUNT, 0);
        hook.settleTax(poolId, currency0);
        uint256 owed = hook.totalOwed(currency0);
        uint256 feePot = hook.pendingFee(poolId, currency0); // left unsettled on purpose
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.NothingToSkim.selector, currency0));
        hook.skim(currency0);

        // A misdirected ERC-20 counts as surplus.
        MockERC20(Currency.unwrap(currency0)).transfer(address(hook), 1 ether);
        uint256 before = hook.claimable(PROTOCOL, currency0);
        vm.expectEmit(true, true, false, true, address(hook));
        emit LaunchTaxModule.TaxSkimmed(currency0, makeAddr("anyone"), 1 ether);
        vm.prank(makeAddr("anyone"));
        assertEq(hook.skim(currency0), 1 ether);
        assertEq(hook.claimable(PROTOCOL, currency0), before + 1 ether);
        assertEq(hook.totalOwed(currency0), owed + 1 ether);
        assertEq(hook.backing(currency0), hook.totalOwed(currency0));
        // Nobody else's balance moved, and neither did the unsettled fee pot.
        assertEq(hook.claimable(creator, currency0), 0.05 ether * 7_000 / 10_000);
        assertEq(hook.pendingFee(poolId, currency0), feePot);
        assertEq(hook.claimable(feeCreator, currency0), 0);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.NothingToSkim.selector, currency0));
        hook.skim(currency0);

        vm.prank(PROTOCOL);
        hook.claim(currency0, PROTOCOL);
        assertEq(currency0.balanceOf(PROTOCOL), before + 1 ether);
        _assertSolvent(currency0);
        _assertLedgerSums(currency0);
    }

    /// @dev A launch token sent to the guard by mistake is surplus, never a fee: `skim` is its only
    /// way out and the protocol its only destination.
    function test_skim_aMisdirectedLaunchTokenIsSurplusNotAFee() public {
        _swap(key, true, AMOUNT, 0);
        MockERC20(Currency.unwrap(currency1)).transfer(address(hook), 7);
        assertEq(hook.totalOwed(currency1), 0);
        assertEq(hook.skim(currency1), 7);
        assertEq(hook.claimable(PROTOCOL, currency1), 7);
        assertEq(hook.pendingFee(poolId, currency1) + hook.pendingTax(poolId, currency1), 0);
        assertEq(hook.grossTaken(currency1), 0, "skimmed, not taken");
        assertEq(hook.grossSkimmed(currency1), 7);
    }

    function test_skim_currencyNobodyIsOwed() public {
        MockERC20 stray = new MockERC20("Stray", "S", 18);
        stray.mint(address(hook), 5);
        Currency c = Currency.wrap(address(stray));
        assertEq(hook.skim(c), 5);
        vm.prank(PROTOCOL);
        assertEq(hook.claim(c, PROTOCOL), 5);
        assertEq(stray.balanceOf(PROTOCOL), 5);
    }

    function test_receive_refusesEverybodyButTheVault() public {
        vm.deal(address(this), 1 ether);
        (bool ok, bytes memory why) = address(hook).call{value: 1}("");
        assertFalse(ok, "stray native refused");
        assertEq(bytes4(why), LaunchTaxModule.NativeNotAccepted.selector);
        vm.prank(address(vault));
        vm.deal(address(vault), 1);
        (ok,) = address(hook).call{value: 1}("");
        assertTrue(ok);
    }

    function test_lockAcquired_refusesStrangersAndTheVaultOutsideRedeem() public {
        vm.expectRevert(LaunchTaxModule.UnexpectedLockCallback.selector);
        hook.lockAcquired(abi.encode(currency0, uint256(1)));
        vm.prank(address(vault));
        vm.expectRevert(LaunchTaxModule.UnexpectedLockCallback.selector);
        hook.lockAcquired(abi.encode(currency0, uint256(1)));
    }

    /*//////////////////////////////////////////////////////////////
                              NATIVE QUOTE
    //////////////////////////////////////////////////////////////*/

    function _nativePool() internal returns (Pool memory p) {
        vm.deal(address(this), 10_000 ether);
        p = _reserve(CurrencyLibrary.NATIVE, currency1, false); // native sorts to currency0: the quote
        uint40 start = uint40(vm.getBlockTimestamp() + 10);
        _open(p, _defaultConfigAt(start), _defaultFeeSplit(), _validTax());
        vm.warp(start + DECAY_SECONDS);
    }

    function test_native_everyShapeIsChargedInNative() public {
        Pool memory p = _nativePool();
        (, Outcome memory o) = _assertShape(p, true, true, 1 ether, FINAL_FEE, BUY_BPS);
        assertEq(o.fee, _buyFee(0.003 ether, 1 ether, FINAL_FEE));
        assertEq(o.tax, 0.05 ether);
        assertEq(o.traderQuote, -1 ether, "one ether left the buyer, refund included");
        _assertShape(p, false, true, 1 ether, FINAL_FEE, SELL_BPS);
        _assertShape(p, true, false, 1 ether, FINAL_FEE, BUY_BPS);
        (, o) = _assertShape(p, false, false, 1 ether, FINAL_FEE, SELL_BPS);
        assertEq(o.traderQuote, 1 ether);
        assertEq(
            vault.balanceOf(address(hook), CurrencyLibrary.NATIVE),
            hook.totalOwed(CurrencyLibrary.NATIVE),
            "native held as vault claims"
        );
        assertEq(address(hook).balance, 0);
        assertEq(vault.balanceOf(address(hook), currency1), 0);
    }

    function test_native_settleClaimAndRedeemBothPots() public {
        Pool memory p = _nativePool();
        Currency n = CurrencyLibrary.NATIVE;
        _swap(p.key, true, 1 ether, 100 ether); // exact-out buy: charged on the native input
        _swap(p.key, false, AMOUNT, 0); // exact-in sell: charged on the native output
        uint256 feePot = hook.pendingFee(p.id, n);
        uint256 taxPot = hook.pendingTax(p.id, n);
        assertGt(feePot, 0);
        assertGt(taxPot, 0);
        assertEq(vault.balanceOf(address(hook), n), feePot + taxPot);
        _assertSolvent(n);

        hook.settleTax(p.id, n);
        hook.settleFee(p.id, n);
        uint256 c = hook.claimable(feeCreator, n);
        assertEq(c, feePot * FEE_CREATOR_BPS / 10_000);
        vm.prank(feeCreator);
        hook.claim(n, feeCreator); // redeems through the vault, pays ETH
        assertEq(feeCreator.balance, c);
        assertEq(address(hook).balance, feePot + taxPot - c, "the rest was redeemed alongside and stays backed");
        assertEq(vault.balanceOf(address(hook), n), 0);
        _assertSolvent(n);

        address[4] memory rest = [creator, integrator, feeIntegrator, PROTOCOL];
        for (uint256 i; i < rest.length; ++i) {
            uint256 due = hook.claimable(rest[i], n);
            uint256 had = rest[i].balance;
            vm.prank(rest[i]);
            hook.claim(n, rest[i]);
            assertEq(rest[i].balance - had, due);
        }
        assertEq(hook.totalOwed(n), 0);
        assertEq(address(hook).balance, 0);
    }

    function test_native_forcedNativeIsSkimmable() public {
        _nativePool();
        // `selfdestruct` forces native in past `receive`.
        ForceSend f = new ForceSend{value: 3}();
        f.boom(payable(address(hook)));
        assertEq(address(hook).balance, 3);
        assertEq(hook.skim(CurrencyLibrary.NATIVE), 3);
        vm.prank(PROTOCOL);
        hook.claim(CurrencyLibrary.NATIVE, PROTOCOL);
        assertEq(PROTOCOL.balance, 3);
    }

    /*//////////////////////////////////////////////////////////////
                              REENTRANCY
    //////////////////////////////////////////////////////////////*/

    /// @dev A pool whose QUOTE hands control to its recipient on transfer, and whose fee creator
    /// and tax creator are both that recipient: every unit the guard pays it is paid in that token.
    function _reenteringPool() internal returns (Pool memory p, ReenteringERC20 tok, ReentrantClaimant att) {
        tok = new ReenteringERC20();
        tok.mint(address(this), 1_000 ether);
        tok.approve(address(router), type(uint256).max);
        Currency ct = Currency.wrap(address(tok));
        bool tokFirst = address(tok) < Currency.unwrap(currency0);
        (Currency c0, Currency c1) = tokFirst ? (ct, currency0) : (currency0, ct);
        // The fixture's plain token is the launch token; the reentering one is the quote.
        p = _reserve(c0, c1, !tokFirst);
        assertEq(Currency.unwrap(p.quote), address(tok));
        att = new ReentrantClaimant(hook, ct, p.id);
        tok.setTarget(address(att));

        uint40 start = uint40(vm.getBlockTimestamp() + 10);
        LaunchTaxModule.TaxConfig memory t = _validTax();
        t.creator = address(att);
        LaunchTaxModule.FeeSplit memory f = _defaultFeeSplit();
        f.creator = address(att);
        _open(p, _defaultConfigAt(start), f, t);
        vm.warp(start + DECAY_SECONDS);
    }

    function _expectReentrancyRefused(address tok) internal {
        // The guard's `currency.transfer` wraps whatever the token reverted with (ERC-7751).
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                tok,
                IERC20.transfer.selector,
                abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector),
                abi.encodeWithSelector(CurrencyLibrary.ERC20TransferFailed.selector)
            )
        );
    }

    function test_REENTRANCY_claimCannotBeReenteredFromItsOwnPayout() public {
        (Pool memory p, ReenteringERC20 tok, ReentrantClaimant att) = _reenteringPool();
        Currency ct = Currency.wrap(address(tok));
        _swap(p.key, _zeroForOne(p, true), AMOUNT, 0);
        hook.settleTax(p.id, ct);
        hook.settleFee(p.id, ct);
        // A second pot of each kind, left unsettled for the re-entrant settle to find.
        _swap(p.key, _zeroForOne(p, true), AMOUNT, 0);

        uint256 owed = hook.claimable(address(att), ct);
        assertEq(owed, 0.05 ether * 7_000 / 10_000 + _share(_buyFee(0.003 ether, 1 ether, FINAL_FEE), FEE_CREATOR_BPS));
        uint256 totalBefore = hook.totalOwed(ct);

        ReentrantClaimant.Mode[4] memory guarded = [
            ReentrantClaimant.Mode.Claim,
            ReentrantClaimant.Mode.ClaimFrom,
            ReentrantClaimant.Mode.Redeem,
            ReentrantClaimant.Mode.Skim
        ];
        for (uint256 i; i < guarded.length; ++i) {
            att.setMode(guarded[i]);
            _expectReentrancyRefused(address(tok));
            att.claim();
            assertEq(hook.claimable(address(att), ct), owed, "nothing paid, nothing lost");
            assertEq(hook.totalOwed(ct), totalBefore);
            _assertSolvent(ct);
        }

        // `settleTax` and `settleFee` are not guarded (no calls in them) and re-entering them is
        // harmless: the outer claim pays the amount it zeroed, and what the settle credits stays
        // claimable afterwards.
        att.setMode(ReentrantClaimant.Mode.SettleFee);
        assertEq(att.claim(), owed);
        assertEq(tok.balanceOf(address(att)), owed);
        assertEq(att.reentered(), 1, "the reverted attempts rolled their counter back; only the harmless one stuck");
        assertEq(hook.pendingFee(p.id, ct), 0, "the re-entrant settle ran");
        uint256 fromFee = _share(_buyFee(0.003 ether, 1 ether, FINAL_FEE), FEE_CREATOR_BPS);
        assertEq(hook.claimable(address(att), ct), fromFee, "credited inside the payout, claimable after it");
        _assertSolvent(ct);

        att.setMode(ReentrantClaimant.Mode.Settle);
        assertEq(att.claim(), fromFee);
        assertEq(hook.pendingTax(p.id, ct), 0);
        assertEq(hook.claimable(address(att), ct), 0.05 ether * 7_000 / 10_000);
        _assertSolvent(ct);

        att.setMode(ReentrantClaimant.Mode.None);
        att.claim();
        vm.expectRevert(LaunchTaxModule.NothingToClaim.selector);
        att.claim();
        assertEq(tok.balanceOf(address(att)), 2 * owed, "two pots of each kind, paid once each");
        _assertSolvent(ct);
    }

    /*//////////////////////////////////////////////////////////////
                               SOLVENCY
    //////////////////////////////////////////////////////////////*/

    /// @dev A short random walk over every state-changing entry point and all four swap shapes,
    /// asserting after each step: backing >= totalOwed, pots + claimable == totalOwed, and the
    /// launch token never taken. The stateful version is `LaunchGuardInvariantCLTest`.
    function testFuzz_SOLVENCY_backingCoversObligationsAfterEveryStep(uint256 seed) public {
        address[5] memory parties = [creator, integrator, feeCreator, feeIntegrator, PROTOCOL];
        for (uint256 step; step < 24; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = r % 10;
            if (op == 0) _swap(key, true, -int256(1 + (r >> 8) % 0.05 ether), 0);
            else if (op == 1) _swap(key, false, -int256(1 + (r >> 8) % 0.05 ether), 0);
            else if (op == 2) _swap(key, true, int256(1 + (r >> 8) % 0.02 ether), 0);
            else if (op == 3) _swap(key, false, int256(1 + (r >> 8) % 0.02 ether), 0);
            else if (op == 4) hook.settleTax(poolId, (r >> 8) % 2 == 0 ? currency0 : currency1);
            else if (op == 5) hook.settleFee(poolId, (r >> 8) % 2 == 0 ? currency0 : currency1);
            else if (op == 6) {
                address who = parties[(r >> 8) % 5];
                Currency c = (r >> 16) % 2 == 0 ? currency0 : currency1;
                if (hook.claimable(who, c) != 0) {
                    vm.prank(who);
                    hook.claim(c, who);
                }
            } else if (op == 7) hook.redeem((r >> 8) % 2 == 0 ? currency0 : currency1);
            else if (op == 8) {
                MockERC20(Currency.unwrap(currency0)).transfer(address(hook), 1 + (r >> 8) % 1000);
                hook.skim(currency0);
            } else vm.warp(vm.getBlockTimestamp() + (r >> 8) % 400);
            _assertSolvent(currency0);
            _assertSolvent(currency1);
            _assertLedgerSums(currency0);
            _assertLedgerSums(currency1);
            assertEq(hook.grossTaken(currency1), 0, "the launch token was taken");
            assertEq(vault.balanceOf(address(hook), currency1), 0, "a launch-token claim appeared");
        }
    }

    function _assertLedgerSums(Currency c) internal view {
        uint256 ledger = hook.pendingFee(poolId, c) + hook.pendingTax(poolId, c) + hook.claimable(creator, c)
            + hook.claimable(integrator, c) + hook.claimable(feeCreator, c) + hook.claimable(feeIntegrator, c)
            + hook.claimable(nominee, c) + hook.claimable(PROTOCOL, c);
        assertEq(ledger, hook.totalOwed(c), "pots + claimable == totalOwed");
    }

    /*//////////////////////////////////////////////////////////////
                                  FUZZ
    //////////////////////////////////////////////////////////////*/

    struct FuzzIn {
        uint256 amount;
        bool tokenIs0;
        bool isBuy;
        bool exactIn;
        uint24 initialFee;
        uint24 finalFee;
        uint16 buyBps;
        uint16 sellBps;
        uint32 decaySeconds;
        uint32 elapsed;
        bool enabled;
    }

    /// @dev One swap of any shape, any size, either side, at any rates inside the caps, at any
    /// moment of the window or after it: the take is exactly the two floors on the quote amount,
    /// the pool trades what the control trades, and the launch token is never touched.
    function testFuzz_take_everyShapeEveryRate(FuzzIn memory f) public {
        f.amount = bound(f.amount, 1, 1 ether);
        f.finalFee = uint24(bound(f.finalFee, 0, hook.MAX_FINAL_FEE()));
        f.initialFee = uint24(bound(f.initialFee, f.finalFee, hook.MAX_INITIAL_FEE()));
        f.buyBps = uint16(bound(f.buyBps, 0, hook.MAX_TAX_BPS()));
        f.sellBps = uint16(bound(f.sellBps, 0, hook.MAX_TAX_BPS()));
        f.decaySeconds = uint32(bound(f.decaySeconds, hook.MIN_DECAY_SECONDS(), 5_000));
        f.elapsed = uint32(bound(f.elapsed, 0, uint256(f.decaySeconds) + 100));

        uint40 start = uint40(vm.getBlockTimestamp() + 10);
        LaunchGuardHook.LaunchConfig memory c = _defaultConfigAt(start);
        c.initialFeeBips = f.initialFee;
        c.finalFeeBips = f.finalFee;
        c.decaySeconds = f.decaySeconds;
        c.enabled = f.enabled;
        LaunchTaxModule.TaxConfig memory t = _validTax();
        t.buyBps = f.buyBps;
        t.sellBps = f.sellBps;
        t.expiresAt = uint40(uint256(start) + f.decaySeconds + 50); // expires inside the fuzzed range
        if (f.buyBps == 0 && f.sellBps == 0) t = _zeroTax();
        Pool memory p = _launch(f.tokenIs0, c, t);

        vm.warp(uint256(start) + f.elapsed);
        uint24 feePips = f.enabled ? _decayed(f.initialFee, f.finalFee, f.elapsed, f.decaySeconds) : f.finalFee;
        uint16 taxBps = vm.getBlockTimestamp() < t.expiresAt ? (f.isBuy ? f.buyBps : f.sellBps) : 0;
        assertEq(hook.currentFee(p.id), feePips, "the view agrees with the schedule");

        (Expected memory e, Outcome memory o) = _assertShape(p, f.isBuy, f.exactIn, f.amount, feePips, taxBps);
        assertLe(o.fee + o.tax, e.base * 6 / 10, "never more than 60% of the quote amount");
        if (f.exactIn == f.isBuy) assertEq(_abs(o.traderQuote), f.amount, "the trader moves exactly what it named");
        else assertEq(_abs(o.traderToken), f.amount, "the trader moves exactly what it named");
    }

    /*//////////////////////////////////////////////////////////////
        A PARTIAL FILL IS REFUSED on the two shapes charged in
        `beforeSwap`. Found 2026-09-28 by these tests, fixed the same
        day, before anything was deployed.

        `beforeSwap` runs before the pool has computed anything, so
        the base of fee and tax is the amount the trader NAMED. A CL
        swap that runs out of liquidity (or reaches its price limit)
        fills only in part and does not revert, and the take would
        stand on the whole amount: 5.3 ether against 6.02 traded in
        the first test below, at rates that sum to 5.3%. `afterSwap`
        can return a delta in the unspecified currency only, so there
        is no refund to give: the guard reverts `SwapNotFilled`.
    //////////////////////////////////////////////////////////////*/

    function _expectNotFilled(uint256 expected, uint256 traded) internal {
        _expectHookRevert(
            ICLHooks.afterSwap.selector,
            abi.encodeWithSelector(LaunchTaxModule.SwapNotFilled.selector, expected, traded)
        );
    }

    /// @dev The same, for an `afterSwap` revert of a guard other than `hook`.
    function _expectRevertFrom(address guard, bytes memory inner) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                guard,
                ICLHooks.afterSwap.selector,
                inner,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function test_FIX_aPartialFillOfAnExactInputBuyIsRefused() public {
        Pool memory p = _default();
        Reading memory a = _read(p);

        // A buy of 100 ether of quote into a range that can absorb about six. With no share left to
        // the pool, 0.30% + 5% of 100 is 5.3, so the pool had to take in 94.7 and took in 6.02.
        uint256 expected = 100 ether - _guardFee(100 ether, FINAL_FEE, true) - 5 ether;
        // What the pool takes in of it: the control pool, charging the same LP fee, asked the same.
        _setControlFee(_lpPips(FINAL_FEE, true));
        BalanceDelta c =
            _swap(p.control, _zeroForOne(p, true), -int256(expected), _value(p.control, _zeroForOne(p, true)));
        uint256 traded = _abs(p.tokenIs0 ? c.amount1() : c.amount0());
        assertLt(traded, expected, "the range cannot absorb it");
        if (_lpShareBps() == 0) {
            assertEq(expected, 94.7 ether);
            assertEq(traded, 6017734268818165223);
        }
        _expectNotFilled(expected, traded);
        _swap(p.key, _zeroForOne(p, true), -100 ether, _value(p.key, _zeroForOne(p, true)));

        _assertUntouched(p, a);
    }

    function test_FIX_aPartialFillOfAnExactOutputSellIsRefused() public {
        Pool memory p = _default();
        Reading memory a = _read(p);

        // A seller asks for 100 ether of quote from a pool that holds about six. 0.30% + 3% of 100
        // is 3.3, so the pool had to pay out 103.3 and paid out 5.98.
        _expectNotFilled(103.3 ether, 5981737760509662598);
        _swap(p.key, _zeroForOne(p, false), 100 ether, _value(p.key, _zeroForOne(p, false)));

        _assertUntouched(p, a);
    }

    /// @dev The other way to fill in part: the swap reaches its own price limit with liquidity left.
    function test_FIX_aBuyStoppedByItsPriceLimitIsRefused() public {
        Pool memory p = _default();
        bool zeroForOne = _zeroForOne(p, true);
        (uint160 sqrtPrice,,,) = poolManager.getSlot0(p.id);
        // One part in a thousand of the way: far less than a 1 ether buy moves this pool.
        uint160 limit = zeroForOne ? sqrtPrice - sqrtPrice / 1_000_000 : sqrtPrice + sqrtPrice / 1_000_000;

        vm.expectPartialRevert(CustomRevert.WrappedError.selector);
        router.swap{value: _value(p.key, zeroForOne)}(
            p.key,
            ICLPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -1 ether, sqrtPriceLimitX96: limit}),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ZERO_BYTES
        );
    }

    /// @dev The largest buy the range absorbs still fills, and is charged its rates: the check
    /// refuses a partial fill, not a large trade.
    function test_FIX_aBuyThatFillsIsNotRefused() public {
        Pool memory p = _default();
        (, Outcome memory o) = _assertShape(p, true, true, 6 ether, FINAL_FEE, BUY_BPS);
        uint256 taken = _guardFee(6 ether, FINAL_FEE, true) + 0.3 ether;
        if (_lpShareBps() == 0) assertEq(taken, 0.318 ether, "0.30% + 5% of the 6 ether named");
        assertEq(o.fee + o.tax, taken, "the guard's part of the fee, and the tax, of the 6 ether named");
        assertEq(o.poolQuote, -int256(6 ether - taken), "and the pool traded all the rest");
    }

    /// @dev The contrast: the same buy on the control pool, which no guard watches, fills in part
    /// and does not revert. The partial fill is core's behaviour; the refusal is the guard's.
    function test_FIX_theSameBuyOnAPoolWithoutTheGuardFillsInPart() public {
        Pool memory p = _default();
        BalanceDelta d =
            _swap(p.control, _zeroForOne(p, true), -100 ether, _value(p.control, _zeroForOne(p, true)));
        assertLt(_abs(p.tokenIs0 ? d.amount1() : d.amount0()), 100 ether, "the control pool filled in part");
    }

    function _assertUntouched(Pool memory p, Reading memory a) internal view {
        Reading memory b = _read(p);
        assertEq(b.feeQuote, a.feeQuote, "no fee was taken");
        assertEq(b.taxQuote, a.taxQuote, "no tax was taken");
        assertEq(b.claimsQuote, a.claimsQuote, "no claim was minted");
        assertEq(b.owedQuote, a.owedQuote, "nothing is owed");
    }

    /// @dev The contrast: the shapes charged in `afterSwap` take their rates on what the pool
    /// actually traded, however much was named.
    function test_partialFill_theAfterSwapShapesAreChargedOnWhatWasTraded() public {
        Pool memory p = _default();
        (, Outcome memory o) = _assertShape(p, false, true, 100 ether, FINAL_FEE, SELL_BPS);
        assertEq(o.poolQuote, 5981737760509662598, "the pool paid out what it had");
        assertEq(o.fee, uint256(o.poolQuote) * 3_000 / 1_000_000);
        assertEq(o.tax, uint256(o.poolQuote) * 300 / 10_000);
        assertLt(o.traderToken, 0);
        assertGt(o.traderToken, -7 ether, "and took in only the launch token that bought it");
    }

    /*//////////////////////////////////////////////////////////////
        THE LIQUIDITY PROVIDERS' SHARE (owner decision, 2026-09-28).
        Every test here holds under every share, zero included.
    //////////////////////////////////////////////////////////////*/

    function test_lpShare_isTheOneTheGuardWasBuiltWith() public view {
        assertEq(hook.LP_SHARE_BPS(), _lpShareBps());
        assertEq(hook.MAX_LP_SHARE_BPS(), 5_000);
    }

    function test_lpShare_aboveTheCapIsRefusedAtConstruction() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.LpShareTooHigh.selector, uint16(5_001)));
        new LaunchGuardHook(poolManager, ILaunchTokenOrigin(address(0)), PROTOCOL, 5_001);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.LpShareTooHigh.selector, type(uint16).max));
        new LaunchGuardHook(poolManager, ILaunchTokenOrigin(address(0)), PROTOCOL, type(uint16).max);

        LaunchGuardHook atCap = new LaunchGuardHook(poolManager, ILaunchTokenOrigin(address(0)), PROTOCOL, 5_000);
        assertEq(atCap.LP_SHARE_BPS(), 5_000);
        LaunchGuardHook none = new LaunchGuardHook(poolManager, ILaunchTokenOrigin(address(0)), PROTOCOL, 0);
        assertEq(none.LP_SHARE_BPS(), 0);
    }

    /// @dev The two parts of a buy's fee are the fee, at every second of the decay and after it; a
    /// sell's fee has one part.
    function test_lpShare_thePartsOfTheFeeSumToTheFeeAtEverySecond() public view {
        for (uint256 t = START_TIME; t <= uint256(START_TIME) + DECAY_SECONDS + 3; t++) {
            uint24 fee = _decayed(INITIAL_FEE, FINAL_FEE, t - START_TIME, DECAY_SECONDS);
            assertEq(hook.feeAt(poolId, t), fee, "the fee");
            (uint24 buyLp, uint24 buyGuard, uint24 sellGuard) = hook.feePartsAt(poolId, t);
            assertEq(buyLp, uint256(fee) * _lpShareBps() / 10_000, "the pool's part of a buy");
            assertEq(uint256(buyLp) + buyGuard, fee, "the two parts of a buy");
            assertEq(sellGuard, fee, "a sell has one part");
        }
        (uint24 lp, uint24 guard, uint24 sell) = hook.currentFeeParts(poolId);
        assertEq(lp, _lpPips(FINAL_FEE, true));
        assertEq(guard, _guardPips(FINAL_FEE, true));
        assertEq(sell, FINAL_FEE);
    }

    function _growth(PoolKey memory k, bool tokenIs0) internal view returns (uint256 quote, uint256 token) {
        (uint256 g0, uint256 g1) = poolManager.getFeeGrowthGlobals(k.toId());
        (quote, token) = tokenIs0 ? (g1, g0) : (g0, g1);
    }

    /// @dev What the pool's liquidity earns: the quote, on buys, exactly as much as the control
    /// pool's does at the same LP fee; nothing on sells; the launch token never.
    function test_lpShare_liquidityEarnsTheQuoteOnBuysAndNothingOnSells() public {
        for (uint256 i = 0; i < 2; i++) {
            Pool memory p = i == 0 ? _default() : _launch(true, _defaultConfigAt(uint40(vm.getBlockTimestamp())), _zeroTax());
            uint24 fee = i == 0 ? FINAL_FEE : INITIAL_FEE;
            uint16 buyTax = i == 0 ? BUY_BPS : 0;
            uint16 sellTax = i == 0 ? SELL_BPS : 0;

            _assertShape(p, true, true, 1 ether, fee, buyTax);
            _assertShape(p, true, false, 0.5 ether, fee, buyTax);
            (uint256 quote, uint256 token) = _growth(p.key, p.tokenIs0);
            (uint256 cQuote, uint256 cToken) = _growth(p.control, p.tokenIs0);
            assertEq(quote, cQuote, "the quote the liquidity earned on buys");
            assertEq(token, 0, "launch token earned on buys");
            assertEq(cToken, 0);
            if (_lpShareBps() == 0) assertEq(quote, 0, "no share, no LP fee");
            else assertGt(quote, 0, "a share, an LP fee");

            _assertShape(p, false, true, 0.5 ether, fee, sellTax);
            _assertShape(p, false, false, 0.2 ether, fee, sellTax);
            (uint256 quoteAfter, uint256 tokenAfter) = _growth(p.key, p.tokenIs0);
            assertEq(quoteAfter, quote, "sells pay the liquidity nothing");
            assertEq(tokenAfter, 0, "and never in the launch token");
        }
    }

    /// @dev Both parts together are never more than the fee on the quote the swap moved: the share
    /// divides the fee, it does not add to it.
    function test_lpShare_aBuyNeverPaysMoreThanTheFee() public {
        Pool memory p = _launch(false, _defaultConfigAt(uint40(vm.getBlockTimestamp())), _zeroTax());
        // At the open, where the fee is largest.
        (Expected memory e, Outcome memory o) = _assertShape(p, true, true, 1 ether, INITIAL_FEE, 0);
        uint256 lpPaid = (_abs(o.poolQuote) * e.lpFee + 999_999) / 1_000_000;
        assertLe(o.fee + lpPaid, uint256(1 ether) * INITIAL_FEE / 1_000_000, "exact input: never more than the fee of what was named");

        (e, o) = _assertShape(p, true, false, 0.5 ether, INITIAL_FEE, 0);
        lpPaid = (_abs(o.poolQuote) * e.lpFee + 999_999) / 1_000_000;
        assertLe(o.fee + lpPaid, _abs(o.poolQuote) * INITIAL_FEE / 1_000_000 + 1, "exact output: the fee of what the pool took in");
    }

    /*//////////////////////////////////////////////////////////////
                                  GAS
    //////////////////////////////////////////////////////////////*/

    /// @dev Reported, not asserted: run with -vv. Same pool shape and amount.
    function test_GAS_swapByShape() public {
        _setControlFee(0);
        _swap(key, true, AMOUNT, 0); // warm the quote's counters
        uint256 g = gasleft();
        _swap(key, true, AMOUNT, 0);
        uint256 buyIn = g - gasleft();
        g = gasleft();
        _swap(key, false, AMOUNT, 0);
        uint256 sellIn = g - gasleft();
        g = gasleft();
        _swap(key, true, 1 ether, 0);
        uint256 buyOut = g - gasleft();
        g = gasleft();
        _swap(key, false, 1 ether, 0);
        uint256 sellOut = g - gasleft();

        vm.warp(EXPIRES_AT);
        g = gasleft();
        _swap(key, true, AMOUNT, 0);
        uint256 expired = g - gasleft();

        _swap(control, true, AMOUNT, 0);
        g = gasleft();
        _swap(control, true, AMOUNT, 0);
        uint256 noHook = g - gasleft();

        console2.log("CL swap gas, fee + tax, buy exact-in   (beforeSwap):", buyIn);
        console2.log("CL swap gas, fee + tax, sell exact-in  (afterSwap): ", sellIn);
        console2.log("CL swap gas, fee + tax, buy exact-out  (afterSwap): ", buyOut);
        console2.log("CL swap gas, fee + tax, sell exact-out (beforeSwap):", sellOut);
        console2.log("CL swap gas, fee only (tax expired), buy exact-in:  ", expired);
        console2.log("CL swap gas, the same pool with no hook:            ", noHook);
    }
}

/*//////////////////////////////////////////////////////////////
                           BIN GUARD
//////////////////////////////////////////////////////////////*/

contract LaunchTaxBinTest is Test, BinTestHelper {
    using LPFeeLibrary for uint24;
    using CurrencyLibrary for Currency;
    using BinPoolParametersHelper for bytes32;
    using BinSafeCast for uint256;

    Vault vault;
    BinPoolManager poolManager;
    BinLaunchGuardHook hook;
    /// @dev Zero while the share is zero: the control pool then has no hook at all.
    ControlFeeBinHook controlHook;
    BinSwapHelper swapHelper;
    BinLiquidityHelper liquidityHelper;

    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;

    /// @dev The suite's default pool: currency1 (Y) is the launch token, currency0 (X) the QUOTE.
    PoolKey key;
    PoolKey control;
    PoolId poolId;

    address constant PROTOCOL = address(0xFEE);
    address creator = makeAddr("creator");
    address integrator = makeAddr("integrator");
    address feeCreator = makeAddr("feeCreator");
    address feeIntegrator = makeAddr("feeIntegrator");
    address nominee = makeAddr("nominee");

    uint24 constant ACTIVE_ID = 2 ** 23;
    uint40 constant START_TIME = 101;
    uint32 constant DECAY_SECONDS = 100;
    uint24 constant INITIAL_FEE = 30_000;
    uint24 constant FINAL_FEE = 3_000;
    uint40 constant EXPIRES_AT = START_TIME + 1000;
    uint16 constant BUY_BPS = 500;
    uint16 constant SELL_BPS = 300;
    uint16 constant FEE_CREATOR_BPS = 6_500;
    uint16 constant FEE_PROTOCOL_BPS = 2_000;
    uint16 constant FEE_INTEGRATOR_BPS = 1_500;
    int128 constant AMOUNT = -1 ether;
    bytes constant ZERO_BYTES = "";

    /// @dev Pools on one hook and one currency pair are told apart by their bin step.
    uint16 _nextBinStep = 10;

    struct Pool {
        PoolKey key;
        PoolKey control;
        PoolId id;
        bool tokenIs0;
        Currency quote;
        Currency token;
    }

    struct Reading {
        uint256 traderQuote;
        uint256 traderToken;
        uint256 feeQuote;
        uint256 taxQuote;
        uint256 feeToken;
        uint256 taxToken;
        uint256 claimsQuote;
        uint256 claimsToken;
        uint256 heldQuote;
        uint256 heldToken;
        uint256 owedQuote;
        uint256 owedToken;
        uint256 grossQuote;
        uint256 grossToken;
    }

    struct Outcome {
        uint24 lpFee;
        int256 poolQuote;
        int256 poolToken;
        int256 traderQuote;
        int256 traderToken;
        uint256 fee;
        uint256 tax;
        uint256 claimsQuote;
        uint256 owedQuote;
        uint256 grossQuote;
        uint256 launchTokenTaken;
    }

    struct Expected {
        uint256 base;
        uint24 lpFee; // what the POOL charges: the liquidity providers' share of a buy's fee
        uint256 fee; // what the GUARD takes of the fee
        uint256 tax;
        int256 poolQuote;
        int256 poolToken;
        int256 traderQuote;
        int256 traderToken;
    }

    /// @dev The share of the trade fee the guard under test leaves the pool, on buys.
    function _lpShareBps() internal pure virtual returns (uint16) {
        return 0;
    }

    /// @dev The pool's part of a fee of `feePips`, written independently of the contract's.
    function _lpPips(uint24 feePips, bool isBuy) internal pure returns (uint24) {
        return isBuy ? uint24(uint256(feePips) * _lpShareBps() / 10_000) : 0;
    }

    /// @dev The guard's part: the rest.
    function _guardPips(uint24 feePips, bool isBuy) internal pure returns (uint24) {
        return feePips - _lpPips(feePips, isBuy);
    }

    /// @dev The guard's take of a fee of `feePips` on `base`, floored as the guard floors it.
    function _guardFee(uint256 base, uint24 feePips, bool isBuy) internal pure returns (uint256) {
        return base * _guardPips(feePips, isBuy) / 1_000_000;
    }

    /// @dev A BUY's fee as the guard takes it under the share being tested. `atNoShare` is the figure
    /// with nothing left to the pool: the literal the test was written with, checked when the share
    /// is zero, so the literal still pins the arithmetic and the share's runs state their own.
    function _buyFee(uint256 atNoShare, uint256 base, uint24 feePips) internal pure returns (uint256 fee) {
        fee = _guardFee(base, feePips, true);
        if (_lpShareBps() == 0) require(fee == atNoShare, "the literal is not the fee at no share");
    }

    function _setControlFee(uint24 lpFee) internal {
        if (address(controlHook) != address(0)) controlHook.set(lpFee);
    }

    function setUp() public {
        vault = new Vault();
        poolManager = new BinPoolManager(IVault(address(vault)));
        vault.registerApp(address(poolManager));

        token0 = new MockERC20("TestA", "A", 18);
        token1 = new MockERC20("TestB", "B", 18);
        (token0, token1) = address(token0) < address(token1) ? (token0, token1) : (token1, token0);
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));
        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);

        swapHelper = new BinSwapHelper(poolManager, vault);
        liquidityHelper = new BinLiquidityHelper(poolManager, vault);
        token0.approve(address(swapHelper), type(uint256).max);
        token1.approve(address(swapHelper), type(uint256).max);
        token0.approve(address(liquidityHelper), type(uint256).max);
        token1.approve(address(liquidityHelper), type(uint256).max);

        hook = new BinLaunchGuardHook(poolManager, ILaunchTokenOrigin(address(0)), PROTOCOL, _lpShareBps());
        if (_lpShareBps() != 0) controlHook = new ControlFeeBinHook(poolManager);

        Pool memory p = _reserve(currency0, currency1, false);
        _open(p, _defaultConfig(), _defaultFeeSplit(), _defaultTax());
        key = p.key;
        control = p.control;
        poolId = p.id;

        vm.warp(START_TIME + DECAY_SECONDS);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _key(Currency c0, Currency c1, IHooks h, uint16 binStep) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: c0,
            currency1: c1,
            hooks: h,
            poolManager: poolManager,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            parameters: bytes32(uint256(h.getHooksRegistrationBitmap())).setBinStep(binStep)
        });
    }

    function _reserve(Currency c0, Currency c1, bool tokenIs0) internal returns (Pool memory p) {
        uint16 binStep = _nextBinStep++;
        p.key = _key(c0, c1, hook, binStep);
        // Without a share: no hook, no fee. With one: the hook that charges the LP fee it is told to.
        p.control = address(controlHook) == address(0)
            ? PoolKey({
                currency0: c0,
                currency1: c1,
                hooks: IHooks(address(0)),
                poolManager: poolManager,
                fee: 0,
                parameters: bytes32(0).setBinStep(binStep)
            })
            : _key(c0, c1, controlHook, binStep);
        p.id = p.key.toId();
        p.tokenIs0 = tokenIs0;
        (p.quote, p.token) = tokenIs0 ? (c1, c0) : (c0, c1);
    }

    /// @dev Claim, write the split and the tax (when it has a rate), initialize and seed `p` and its
    /// control identically. Seeded like the kit seeds while a tax is live: bins on each side of the
    /// active one, never the active bin itself (it is closed to mints while the tax is live).
    function _open(
        Pool memory p,
        BinLaunchGuardHook.LaunchConfig memory cfg,
        LaunchTaxModule.FeeSplit memory split,
        LaunchTaxModule.TaxConfig memory tax
    ) internal {
        cfg.launchTokenIsCurrency0 = p.tokenIs0;
        hook.configureLaunch(p.key, cfg);
        hook.configureFeeSplit(p.key, split);
        if (tax.buyBps != 0 || tax.sellBps != 0) hook.configureTax(p.key, tax);
        poolManager.initialize(p.key, ACTIVE_ID);
        poolManager.initialize(p.control, ACTIVE_ID);
        _seedAround(p.key, 100 ether, 100 ether);
        _seedAround(p.control, 100 ether, 100 ether);
    }

    function _launch(bool tokenIs0, BinLaunchGuardHook.LaunchConfig memory cfg, LaunchTaxModule.TaxConfig memory tax)
        internal
        returns (Pool memory p)
    {
        p = _reserve(currency0, currency1, tokenIs0);
        _open(p, cfg, _defaultFeeSplit(), tax);
    }

    function _default() internal view returns (Pool memory p) {
        p.key = key;
        p.control = control;
        p.id = poolId;
        p.tokenIs0 = false;
        p.quote = currency0;
        p.token = currency1;
    }

    function _defaultConfig() internal pure returns (BinLaunchGuardHook.LaunchConfig memory) {
        return BinLaunchGuardHook.LaunchConfig({
            startTime: START_TIME,
            decaySeconds: DECAY_SECONDS,
            initialFeeBips: INITIAL_FEE,
            finalFeeBips: FINAL_FEE,
            maxBuyPerTx: 0,
            launchTokenIsCurrency0: false, // Y is the launch token => a buy is swapForY
            enabled: true
        });
    }

    function _defaultConfigAt(uint40 start) internal pure returns (BinLaunchGuardHook.LaunchConfig memory c) {
        c = _defaultConfig();
        c.startTime = start;
    }

    function _defaultTax() internal view returns (LaunchTaxModule.TaxConfig memory) {
        return LaunchTaxModule.TaxConfig({
            buyBps: BUY_BPS,
            sellBps: SELL_BPS,
            expiresAt: EXPIRES_AT,
            creator: creator,
            integrator: integrator,
            creatorBps: 7_000,
            protocolBps: 1_000,
            integratorBps: 2_000
        });
    }

    function _validTax() internal view returns (LaunchTaxModule.TaxConfig memory t) {
        t = _defaultTax();
        t.expiresAt = uint40(vm.getBlockTimestamp() + 7 days);
    }

    function _zeroTax() internal pure returns (LaunchTaxModule.TaxConfig memory t) {}

    function _defaultFeeSplit() internal view returns (LaunchTaxModule.FeeSplit memory) {
        return LaunchTaxModule.FeeSplit({
            creator: feeCreator,
            creatorBps: FEE_CREATOR_BPS,
            protocolBps: FEE_PROTOCOL_BPS,
            integratorBps: FEE_INTEGRATOR_BPS,
            integrator: feeIntegrator
        });
    }

    function _freshPool() internal returns (PoolKey memory k, PoolId id) {
        Pool memory p = _reserve(currency0, currency1, false);
        k = p.key;
        id = p.id;
        hook.configureLaunch(k, _defaultConfigAt(uint40(vm.getBlockTimestamp() + 10)));
    }

    /// @dev X into the bins above active, Y into the bins below: no active bin, no composition swap.
    function _seedAround(PoolKey memory k, uint256 amountX, uint256 amountY) internal {
        bytes32[] memory cfgs = new bytes32[](4);
        cfgs[0] = LiquidityConfigurations.encodeParams(0, 0.5e18, ACTIVE_ID - 2);
        cfgs[1] = LiquidityConfigurations.encodeParams(0, 0.5e18, ACTIVE_ID - 1);
        cfgs[2] = LiquidityConfigurations.encodeParams(0.5e18, 0, ACTIVE_ID + 1);
        cfgs[3] = LiquidityConfigurations.encodeParams(0.5e18, 0, ACTIVE_ID + 2);
        liquidityHelper.mint{value: k.currency0.isNative() ? amountX : 0}(
            k,
            IBinPoolManager.MintParams({
                liquidityConfigs: cfgs, amountIn: PackedUint128Math.encode(amountX.safe128(), amountY.safe128()), salt: 0
            }),
            ZERO_BYTES
        );
    }

    function _swap(PoolKey memory k, bool swapForY, int128 amountSpecified) internal returns (BalanceDelta) {
        uint256 value = (swapForY ? k.currency0 : k.currency1).isNative() ? 100 ether : 0;
        return swapHelper.swap{value: value}(
            k, swapForY, amountSpecified, BinSwapHelper.TestSettings(true, true), ZERO_BYTES
        );
    }

    /// @dev A buy is quote in, launch token out. `swapForY` sells currency0 (X) for currency1 (Y).
    function _swapForY(Pool memory p, bool isBuy) internal pure returns (bool) {
        return isBuy ? !p.tokenIs0 : p.tokenIs0;
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    function _read(Pool memory p) internal view returns (Reading memory r) {
        r.traderQuote = p.quote.balanceOf(address(this));
        r.traderToken = p.token.balanceOf(address(this));
        r.feeQuote = hook.feeTaken(p.id, p.quote);
        r.taxQuote = hook.totalTaken(p.id, p.quote);
        r.feeToken = hook.feeTaken(p.id, p.token);
        r.taxToken = hook.totalTaken(p.id, p.token);
        r.claimsQuote = vault.balanceOf(address(hook), p.quote);
        r.claimsToken = vault.balanceOf(address(hook), p.token);
        r.heldQuote = p.quote.balanceOf(address(hook));
        r.heldToken = p.token.balanceOf(address(hook));
        r.owedQuote = hook.totalOwed(p.quote);
        r.owedToken = hook.totalOwed(p.token);
        r.grossQuote = hook.grossTaken(p.quote);
        r.grossToken = hook.grossTaken(p.token);
    }

    function _trade(Pool memory p, bool isBuy, bool exactIn, uint256 amount) internal returns (Outcome memory) {
        return this.measureTrade(p, isBuy, exactIn, amount);
    }

    /// @dev Behind an EXTERNAL call to this contract on purpose. Decoding `Vm.Log[]` takes a dozen
    /// stack slots, and via-IR inlines an internal helper into whichever test calls it: with the
    /// test's own structs live that is one slot too many ("too deep in the stack"). The router's
    /// caller is this contract either way, and `vm.expectEmit` sees the events of nested calls.
    function measureTrade(Pool memory p, bool isBuy, bool exactIn, uint256 amount)
        external
        returns (Outcome memory o)
    {
        Reading memory a = _read(p);

        vm.recordLogs();
        _swap(p.key, _swapForY(p, isBuy), exactIn ? -int128(uint128(amount)) : int128(uint128(amount)));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool seen;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(poolManager) && logs[i].topics[0] == IBinPoolManager.Swap.selector) {
                // Swap(PoolId indexed, address indexed, int128, int128, uint24 activeId, uint24 fee, uint16)
                (int128 g0, int128 g1,, uint24 fee,) = abi.decode(logs[i].data, (int128, int128, uint24, uint24, uint16));
                (o.poolQuote, o.poolToken) = p.tokenIs0 ? (int256(g1), int256(g0)) : (int256(g0), int256(g1));
                o.lpFee = fee;
                seen = true;
            }
        }
        require(seen, "Swap event not found");

        Reading memory b = _read(p);
        o.traderQuote = int256(b.traderQuote) - int256(a.traderQuote);
        o.traderToken = int256(b.traderToken) - int256(a.traderToken);
        o.fee = b.feeQuote - a.feeQuote;
        o.tax = b.taxQuote - a.taxQuote;
        o.claimsQuote = b.claimsQuote - a.claimsQuote;
        o.owedQuote = b.owedQuote - a.owedQuote;
        o.grossQuote = b.grossQuote - a.grossQuote;
        o.launchTokenTaken = (b.feeToken - a.feeToken) + (b.taxToken - a.taxToken) + (b.claimsToken - a.claimsToken)
            + (b.heldToken - a.heldToken) + (b.owedToken - a.owedToken) + (b.grossToken - a.grossToken);
        assertEq(b.heldQuote, a.heldQuote, "a swap moves vault claims, never real tokens, into the guard");
    }

    function _predict(Pool memory p, bool isBuy, bool exactIn, uint256 amount, uint24 feePips, uint16 taxBps)
        internal
        returns (Expected memory e)
    {
        bool quoteSpecified = exactIn == isBuy;
        // `feePips` is the WHOLE trade fee. The pool charges its share of a buy's; the guard the rest.
        e.lpFee = _lpPips(feePips, isBuy);
        _setControlFee(e.lpFee);
        feePips = feePips - e.lpFee;
        uint256 poolAmount = amount;
        if (quoteSpecified) {
            e.base = amount;
            e.fee = amount * feePips / 1_000_000;
            e.tax = amount * taxBps / 10_000;
            poolAmount = exactIn ? amount - e.fee - e.tax : amount + e.fee + e.tax;
        }

        BalanceDelta c = _swap(
            p.control, _swapForY(p, isBuy), exactIn ? -int128(uint128(poolAmount)) : int128(uint128(poolAmount))
        );
        (e.poolQuote, e.poolToken) =
            p.tokenIs0 ? (int256(c.amount1()), int256(c.amount0())) : (int256(c.amount0()), int256(c.amount1()));

        if (!quoteSpecified) {
            e.base = _abs(e.poolQuote);
            e.fee = e.base * feePips / 1_000_000;
            e.tax = e.base * taxBps / 10_000;
        }
        e.traderQuote = e.poolQuote - int256(e.fee + e.tax);
        e.traderToken = e.poolToken;
    }

    function _assertMatches(Pool memory p, Expected memory e, Outcome memory o) internal view {
        assertEq(o.lpFee, e.lpFee, "the LP fee core applied");
        assertEq(o.poolQuote, e.poolQuote, "pool quote amount != control");
        assertEq(o.poolToken, e.poolToken, "pool token amount != control");
        assertEq(o.fee, e.fee, "fee pot");
        assertEq(o.tax, e.tax, "tax pot");
        assertEq(o.claimsQuote, e.fee + e.tax, "vault claims in the quote");
        assertEq(o.owedQuote, e.fee + e.tax, "totalOwed in the quote");
        assertEq(o.grossQuote, e.fee + e.tax, "grossTaken in the quote");
        assertEq(o.launchTokenTaken, 0, "the guard took launch token");
        assertEq(o.traderQuote, e.traderQuote, "trader quote");
        assertEq(o.traderToken, e.traderToken, "trader launch token");
        _assertSolvent(p.quote);
        _assertSolvent(p.token);
    }

    function _assertShape(Pool memory p, bool isBuy, bool exactIn, uint256 amount, uint24 feePips, uint16 taxBps)
        internal
        returns (Expected memory e, Outcome memory o)
    {
        e = _predict(p, isBuy, exactIn, amount, feePips, taxBps);
        o = _trade(p, isBuy, exactIn, amount);
        _assertMatches(p, e, o);
    }

    /// @dev A bucket's floor share of a pot.
    function _share(uint256 pot, uint256 bps) internal pure returns (uint256) {
        return pot * bps / 10_000;
    }

    /// @dev The pool id as the number the rotation takes: the lockers' signature.
    function _id(PoolId id) internal pure returns (uint256) {
        return uint256(PoolId.unwrap(id));
    }

    function _assertSolvent(Currency c) internal view {
        assertGe(hook.backing(c), hook.totalOwed(c), "backing < totalOwed");
    }

    function _assertLedgerSums(Currency c) internal view {
        uint256 ledger = hook.pendingFee(poolId, c) + hook.pendingTax(poolId, c) + hook.claimable(creator, c)
            + hook.claimable(integrator, c) + hook.claimable(feeCreator, c) + hook.claimable(feeIntegrator, c)
            + hook.claimable(nominee, c) + hook.claimable(PROTOCOL, c);
        assertEq(ledger, hook.totalOwed(c), "pots + claimable == totalOwed");
    }

    function _decayed(uint24 initialFee, uint24 finalFee, uint256 elapsed, uint256 window)
        internal
        pure
        returns (uint24)
    {
        if (elapsed >= window) return finalFee;
        return uint24(uint256(initialFee) - (uint256(initialFee - finalFee) * elapsed) / window);
    }

    receive() external payable {}

    function _expectHookRevert(bytes4 hookFn, bytes memory inner) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                hookFn,
                inner,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                  THE BITMAP, AND THE TWO CONFIGURATION WRITES
    //////////////////////////////////////////////////////////////*/

    function test_bitmap() public view {
        // bit 0 | bit 2 (beforeMint) | bit 6 | bit 7 | bit 10 (beforeSwapReturnsDelta) | bit 11
        assertEq(hook.getHooksRegistrationBitmap(), 0x0CC5);
    }

    /// @dev The Bin twin of the CL test: under the old bitmap (0x08C5) the shapes charged in
    /// `beforeSwap` cannot settle.
    function test_bitmap_withoutBit10ABuyCannotSettle() public {
        PreFeeBitmapBinHook old = new PreFeeBitmapBinHook(poolManager); // `_validatePermissions` passed
        assertEq(old.getHooksRegistrationBitmap(), 0x08C5);
        PoolKey memory k = _key(currency0, currency1, old, 10);
        old.configureLaunch(k, _defaultConfigAt(uint40(vm.getBlockTimestamp())));
        old.configureFeeSplit(k, _defaultFeeSplit());
        poolManager.initialize(k, ACTIVE_ID);
        _seedAround(k, 100 ether, 100 ether);

        vm.expectRevert(IVault.CurrencyNotSettled.selector);
        _swap(k, true, AMOUNT);
        vm.expectRevert(IVault.CurrencyNotSettled.selector);
        _swap(k, false, 1 ether);

        _swap(k, false, AMOUNT);
        _swap(k, true, 1 ether);
        assertGt(old.pendingFee(k.toId(), currency0), 0);
    }

    function test_FLOOR_protocolBelowTenPercentIsRefusedOnBin() public {
        (PoolKey memory k, PoolId id) = _freshPool();
        uint256 start = vm.getBlockTimestamp() + 10;
        LaunchTaxModule.TaxConfig memory t = _validTax();
        t.protocolBps = 999;
        t.creatorBps = 7_001;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxProtocolShareOutOfBounds.selector, uint16(999)));
        hook.configureTax(k, t);
        t.protocolBps = 1_000;
        t.creatorBps = 7_000;
        hook.configureTax(k, t);
        vm.warp(start + 1);
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.LaunchAlreadyStarted.selector, id, start));
        hook.configureTax(k, t);
    }

    function test_feeSplit_storesAndEmits() public {
        (PoolKey memory k, PoolId id) = _freshPool();
        vm.expectEmit(true, false, false, true, address(hook));
        emit LaunchTaxModule.FeeSplitConfigured(
            id, feeCreator, feeIntegrator, FEE_CREATOR_BPS, FEE_PROTOCOL_BPS, FEE_INTEGRATOR_BPS
        );
        hook.configureFeeSplit(k, _defaultFeeSplit());
        LaunchTaxModule.FeeSplit memory f = hook.getFeeSplit(id);
        assertEq(f.creator, feeCreator);
        assertEq(f.integrator, feeIntegrator);
        assertEq(f.creatorBps, FEE_CREATOR_BPS);
        assertEq(f.protocolBps, FEE_PROTOCOL_BPS);
        assertEq(f.integratorBps, FEE_INTEGRATOR_BPS);
    }

    /// @dev MUTATION-CHECKED (f).
    function test_feeSplit_isWrittenOnce() public {
        (PoolKey memory k, PoolId id) = _freshPool();
        hook.configureFeeSplit(k, _defaultFeeSplit());
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.FeeSplitAlreadySet.selector, id));
        hook.configureFeeSplit(k, _defaultFeeSplit());
        LaunchTaxModule.FeeSplit memory other = _defaultFeeSplit();
        other.creator = makeAddr("somebodyElse");
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.FeeSplitAlreadySet.selector, id));
        hook.configureFeeSplit(k, other);
        assertEq(hook.getFeeSplit(id).creator, feeCreator);
    }

    function test_feeSplit_ownerOnlyAndOnlyOnItsOwnKey() public {
        (PoolKey memory k, PoolId id) = _freshPool();
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.NotLaunchOwner.selector, id, stranger));
        hook.configureFeeSplit(k, _defaultFeeSplit());

        PoolKey memory unclaimed = _reserve(currency0, currency1, false).key;
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.LaunchNotConfigured.selector, unclaimed.toId()));
        hook.configureFeeSplit(unclaimed, _defaultFeeSplit());

        PoolKey memory bad = k;
        bad.hooks = IHooks(makeAddr("other"));
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.HookMismatch.selector, address(bad.hooks)));
        hook.configureFeeSplit(bad, _defaultFeeSplit());
        bad.hooks = hook;
        bad.poolManager = IBinPoolManager(makeAddr("otherPM"));
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.PoolManagerMismatch.selector, address(bad.poolManager)));
        hook.configureFeeSplit(bad, _defaultFeeSplit());
        assertEq(hook.getFeeSplit(id).protocolBps, 0, "nothing was written");
    }

    function test_feeSplit_frozenAfterStartTimeAndByTheFirstSwap() public {
        (PoolKey memory k, PoolId id) = _freshPool();
        uint256 start = vm.getBlockTimestamp() + 10;
        vm.warp(start); // exactly the start, nobody has traded: still writable
        hook.configureFeeSplit(k, _defaultFeeSplit());

        (PoolKey memory k2, PoolId id2) = _freshPool();
        uint256 start2 = vm.getBlockTimestamp() + 10;
        vm.warp(start2 + 1);
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.LaunchAlreadyStarted.selector, id2, start2));
        hook.configureFeeSplit(k2, _defaultFeeSplit());
        assertEq(hook.getFeeSplit(id).protocolBps, FEE_PROTOCOL_BPS);

        // A disabled schedule trades before its start; its first swap freezes the split's write too.
        Pool memory p = _reserve(currency0, currency1, false);
        BinLaunchGuardHook.LaunchConfig memory c = _defaultConfigAt(uint40(vm.getBlockTimestamp() + 30 days));
        c.enabled = false;
        _open(p, c, _defaultFeeSplit(), _zeroTax());
        _swap(p.key, true, AMOUNT);
        vm.expectRevert(abi.encodeWithSelector(BinLaunchGuardHook.LaunchAlreadyStarted.selector, p.id, uint256(c.startTime)));
        hook.configureFeeSplit(p.key, _defaultFeeSplit());
    }

    /// @dev MUTATION-CHECKED (h).
    function test_FEEFLOOR_protocolBelowTwentyPercentIsRefusedOnBin() public {
        (PoolKey memory k, PoolId id) = _freshPool();
        LaunchTaxModule.FeeSplit memory f = _defaultFeeSplit();
        f.protocolBps = 1_999;
        f.creatorBps = 10_000 - 1_999 - FEE_INTEGRATOR_BPS;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxProtocolShareOutOfBounds.selector, uint16(1_999)));
        hook.configureFeeSplit(k, f);
        f.protocolBps = 1_000;
        f.creatorBps = 10_000 - 1_000 - FEE_INTEGRATOR_BPS;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxProtocolShareOutOfBounds.selector, uint16(1_000)));
        hook.configureFeeSplit(k, f);
        f.protocolBps = 5_001;
        f.creatorBps = 10_000 - 5_001 - FEE_INTEGRATOR_BPS;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxProtocolShareOutOfBounds.selector, uint16(5_001)));
        hook.configureFeeSplit(k, f);
        f.integratorBps = 2_001;
        f.protocolBps = 2_000;
        f.creatorBps = 10_000 - 2_000 - 2_001;
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.TaxIntegratorShareTooHigh.selector, uint16(2_001)));
        hook.configureFeeSplit(k, f);
        f = _defaultFeeSplit();
        f.creator = address(hook);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.InvalidTaxRecipient.selector, address(hook)));
        hook.configureFeeSplit(k, f);
        assertEq(hook.getFeeSplit(id).protocolBps, 0);
        assertEq(hook.MIN_FEE_PROTOCOL_BPS(), 2_000);
    }

    /// @dev MUTATION-CHECKED (g).
    function test_initialize_refusesAPoolWithoutAFeeSplit() public {
        (PoolKey memory k, PoolId id) = _freshPool();
        hook.configureTax(k, _validTax());
        _expectHookRevert(
            IBinHooks.beforeInitialize.selector,
            abi.encodeWithSelector(LaunchTaxModule.FeeSplitNotConfigured.selector, id)
        );
        poolManager.initialize(k, ACTIVE_ID);

        hook.configureFeeSplit(k, _defaultFeeSplit());
        poolManager.initialize(k, ACTIVE_ID);
        (uint24 activeId,,) = poolManager.getSlot0(id);
        assertEq(activeId, ACTIVE_ID);
    }

    /// @dev The rotation lives in the shared module; one pass on the Bin guard shows it is wired.
    /// MUTATION-CHECKED (j).
    function test_feeCreator_twoStepHandoverOnBin() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.NotFeeCreator.selector, poolId, stranger));
        hook.transferCreator(_id(poolId), stranger);
        vm.prank(feeCreator);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.InvalidTaxRecipient.selector, address(hook)));
        hook.transferCreator(_id(poolId), address(hook));

        _swap(key, true, AMOUNT);
        hook.settleFee(poolId, currency0); // settled for the first creator
        _swap(key, true, AMOUNT); // taken, not settled

        vm.prank(feeCreator);
        hook.transferCreator(_id(poolId), nominee);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.NotPendingFeeCreator.selector, poolId, stranger));
        hook.acceptCreator(_id(poolId));
        vm.prank(feeCreator);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.NotPendingFeeCreator.selector, poolId, feeCreator));
        hook.acceptCreator(_id(poolId));
        vm.prank(nominee);
        hook.acceptCreator(_id(poolId));

        LaunchTaxModule.FeeSplit memory f = hook.getFeeSplit(poolId);
        assertEq(f.creator, nominee);
        assertEq(f.creatorBps, FEE_CREATOR_BPS);
        assertEq(f.integrator, feeIntegrator);
        assertEq(hook.getTax(poolId).creator, creator, "the tax's creator did not move");

        hook.settleFee(poolId, currency0);
        hook.settleTax(poolId, currency0);
        assertEq(hook.claimable(feeCreator, currency0), _share(_buyFee(0.003 ether, 1 ether, FINAL_FEE), FEE_CREATOR_BPS));
        assertEq(hook.claimable(nominee, currency0), _share(_buyFee(0.003 ether, 1 ether, FINAL_FEE), FEE_CREATOR_BPS));
        assertEq(hook.claimable(creator, currency0), 0.1 ether * 7_000 / 10_000, "both swaps' tax, to the tax's creator");
        _assertLedgerSums(currency0);
    }

    /*//////////////////////////////////////////////////////////////
                              THE SWAP PATH
    //////////////////////////////////////////////////////////////*/

    function test_swap_exactInBuy_isChargedInTheQuoteItSends() public {
        Pool memory p = _default();
        Expected memory e = _predict(p, true, true, 1 ether, FINAL_FEE, BUY_BPS);
        assertEq(e.fee, _buyFee(0.003 ether, 1 ether, FINAL_FEE));
        assertEq(e.tax, 0.05 ether);
        assertEq(e.poolQuote, -int256(1 ether - e.fee - 0.05 ether));

        vm.expectEmit(true, true, false, true, address(hook));
        emit LaunchTaxModule.FeeTaken(poolId, currency0, true, e.fee);
        vm.expectEmit(true, true, false, true, address(hook));
        emit LaunchTaxModule.TaxTaken(poolId, currency0, true, 0.05 ether);
        Outcome memory o = _trade(p, true, true, 1 ether);
        _assertMatches(p, e, o);
        assertEq(o.traderQuote, -1 ether);
        assertEq(vault.balanceOf(address(hook), currency0), e.fee + 0.05 ether);
        assertEq(vault.balanceOf(address(hook), currency1), 0);
    }

    function test_swap_exactInSell_isChargedInTheQuoteItReceives() public {
        Pool memory p = _default();
        Expected memory e = _predict(p, false, true, 1 ether, FINAL_FEE, SELL_BPS);
        assertGt(e.poolQuote, 0.99 ether);
        assertEq(e.fee, uint256(e.poolQuote) * 3_000 / 1_000_000);
        assertEq(e.tax, uint256(e.poolQuote) * 300 / 10_000, "the SELL rate");
        vm.expectEmit(true, true, false, true, address(hook));
        emit LaunchTaxModule.FeeTaken(poolId, currency0, false, e.fee);
        vm.expectEmit(true, true, false, true, address(hook));
        emit LaunchTaxModule.TaxTaken(poolId, currency0, false, e.tax);
        Outcome memory o = _trade(p, false, true, 1 ether);
        _assertMatches(p, e, o);
        assertEq(o.traderToken, -1 ether);
    }

    function test_swap_exactOutBuy_isChargedOnTopOfTheQuoteThePoolAsksFor() public {
        Pool memory p = _default();
        (Expected memory e, Outcome memory o) = _assertShape(p, true, false, 1 ether, FINAL_FEE, BUY_BPS);
        assertEq(o.traderToken, 1 ether);
        assertEq(e.fee, _guardFee(_abs(e.poolQuote), 3_000, true));
        assertEq(e.tax, _abs(e.poolQuote) * 500 / 10_000, "the BUY rate");
        assertEq(o.traderQuote, e.poolQuote - int256(e.fee + e.tax));
    }

    function test_swap_exactOutSell_receivesExactlyTheQuoteItAskedFor() public {
        Pool memory p = _default();
        Expected memory e = _predict(p, false, false, 1 ether, FINAL_FEE, SELL_BPS);
        assertEq(e.fee, 0.003 ether);
        assertEq(e.tax, 0.03 ether);
        assertEq(e.poolQuote, 1.033 ether);
        Outcome memory o = _trade(p, false, false, 1 ether);
        _assertMatches(p, e, o);
        assertEq(o.traderQuote, 1 ether);
    }

    /// @dev MUTATION-CHECKED (a, b, d) on the Bin guard.
    function test_swap_fourShapes_launchTokenIsCurrency0() public {
        Pool memory p = _launch(true, _defaultConfigAt(uint40(vm.getBlockTimestamp())), _validTax());
        assertEq(Currency.unwrap(p.quote), Currency.unwrap(currency1));
        vm.warp(vm.getBlockTimestamp() + DECAY_SECONDS);

        (Expected memory e, Outcome memory o) = _assertShape(p, true, true, 1 ether, FINAL_FEE, BUY_BPS);
        assertEq(e.fee + e.tax, _buyFee(0.003 ether, 1 ether, FINAL_FEE) + 0.05 ether);
        assertEq(o.traderQuote, -1 ether);
        (e, o) = _assertShape(p, false, true, 1 ether, FINAL_FEE, SELL_BPS);
        assertEq(o.traderToken, -1 ether);
        assertGt(e.fee, 0);
        (e, o) = _assertShape(p, true, false, 1 ether, FINAL_FEE, BUY_BPS);
        assertEq(o.traderToken, 1 ether);
        (e, o) = _assertShape(p, false, false, 1 ether, FINAL_FEE, SELL_BPS);
        assertEq(e.fee + e.tax, 0.033 ether);
        assertEq(o.traderQuote, 1 ether);

        assertEq(vault.balanceOf(address(hook), currency0), 0, "currency0 is the launch token here");
        assertEq(hook.feeTaken(p.id, currency0) + hook.totalTaken(p.id, currency0), 0);
        assertEq(hook.grossTaken(currency0), 0);
    }

    function test_swap_fourShapes_launchTokenIsCurrency1() public {
        Pool memory p = _default();
        _assertShape(p, true, true, 0.37 ether, FINAL_FEE, BUY_BPS);
        _assertShape(p, false, true, 0.37 ether, FINAL_FEE, SELL_BPS);
        _assertShape(p, true, false, 0.37 ether, FINAL_FEE, BUY_BPS);
        _assertShape(p, false, false, 0.37 ether, FINAL_FEE, SELL_BPS);
        assertEq(vault.balanceOf(address(hook), currency1), 0, "currency1 is the launch token here");
        assertEq(hook.grossTaken(currency1), 0);
    }

    function test_swap_untaxedPoolTakesTheFeeOnly() public {
        Pool memory p = _launch(false, _defaultConfigAt(uint40(vm.getBlockTimestamp())), _zeroTax());
        vm.warp(vm.getBlockTimestamp() + DECAY_SECONDS);
        bool[2] memory flags = [true, false];
        for (uint256 i; i < 2; ++i) {
            for (uint256 j; j < 2; ++j) {
                (, Outcome memory o) = _assertShape(p, flags[i], flags[j], 1 ether, FINAL_FEE, 0);
                assertGt(o.fee, 0);
                assertEq(o.tax, 0);
            }
        }
        assertEq(hook.totalTaken(p.id, currency0), 0);
    }

    function test_expiry_stopsTheTaxWithoutATransaction() public {
        Pool memory p = _default();
        vm.warp(EXPIRES_AT - 1);
        (, Outcome memory o) = _assertShape(p, true, true, 1 ether, FINAL_FEE, BUY_BPS);
        assertEq(o.tax, 0.05 ether);
        uint256 pot = hook.pendingTax(poolId, currency0);
        vm.warp(EXPIRES_AT);
        (, o) = _assertShape(p, true, true, 1 ether, FINAL_FEE, 0);
        assertEq(o.fee, _buyFee(0.003 ether, 1 ether, FINAL_FEE), "the fee outlives the tax");
        _assertShape(p, false, true, 1 ether, FINAL_FEE, 0);
        _assertShape(p, true, false, 1 ether, FINAL_FEE, 0);
        _assertShape(p, false, false, 1 ether, FINAL_FEE, 0);
        assertEq(hook.pendingTax(poolId, currency0), pot);
    }

    function test_swap_feeDecaysUnderAConstantTax() public {
        uint40 start = uint40(vm.getBlockTimestamp() + 10);
        Pool memory p = _launch(false, _defaultConfigAt(start), _validTax());
        vm.warp(start);
        (Expected memory e, Outcome memory o) = _assertShape(p, true, true, 1 ether, INITIAL_FEE, BUY_BPS);
        assertEq(o.fee, _buyFee(0.03 ether, 1 ether, INITIAL_FEE), "the opening fee, on the whole amount");
        assertEq(o.tax, 0.05 ether, "the tax, on the whole amount, not on what the fee left");
        assertEq(e.poolQuote, -int256(1 ether - o.fee - o.tax));

        vm.warp(start + 50);
        (, o) = _assertShape(p, true, true, 1 ether, 16_500, BUY_BPS);
        assertEq(o.fee, _buyFee(0.0165 ether, 1 ether, 16_500));
        vm.warp(start + DECAY_SECONDS - 1);
        (, o) = _assertShape(p, false, false, 1 ether, 3_270, SELL_BPS);
        assertEq(o.fee, 0.00327 ether);
        vm.warp(start + DECAY_SECONDS);
        (, o) = _assertShape(p, true, true, 1 ether, FINAL_FEE, BUY_BPS);
        assertEq(o.fee, _buyFee(0.003 ether, 1 ether, FINAL_FEE));
    }

    /*//////////////////////////////////////////////////////////////
                THE CAPS: 10% FEE + 10% TAX = 20% ON BIN
    //////////////////////////////////////////////////////////////*/

    function _capsPool(bool tokenIs0) internal returns (Pool memory p) {
        BinLaunchGuardHook.LaunchConfig memory c = _defaultConfigAt(uint40(vm.getBlockTimestamp()));
        c.initialFeeBips = hook.MAX_INITIAL_FEE();
        c.finalFeeBips = hook.MAX_FINAL_FEE();
        LaunchTaxModule.TaxConfig memory t = _validTax();
        t.buyBps = hook.MAX_TAX_BPS();
        t.sellBps = hook.MAX_TAX_BPS();
        p = _launch(tokenIs0, c, t);
    }

    function test_CAPS_twentyPercentAtTheOpening_everyShape() public {
        assertEq(hook.MAX_INITIAL_FEE(), 100_000);
        assertEq(hook.MAX_TAX_BPS(), 1_000);
        for (uint256 side; side < 2; ++side) {
            Pool memory p = _capsPool(side == 1);
            (Expected memory e, Outcome memory o) = _assertShape(p, true, true, 1 ether, 100_000, 1_000);
            assertEq(o.fee, _buyFee(0.1 ether, 1 ether, 100_000));
            assertEq(o.tax, 0.1 ether);
            assertEq(e.poolQuote, -int256(1 ether - o.fee - o.tax));
            (e, o) = _assertShape(p, false, true, 1 ether, 100_000, 1_000);
            assertEq(o.fee + o.tax, 2 * (uint256(e.poolQuote) / 10));
            _assertShape(p, true, false, 1 ether, 100_000, 1_000);
            (e, o) = _assertShape(p, false, false, 1 ether, 100_000, 1_000);
            assertEq(e.poolQuote, 1.2 ether);
            assertEq(o.traderQuote, 1 ether);
        }
    }

    function test_CAPS_finalFeeCapWithTheTaxCap() public {
        Pool memory p = _capsPool(false);
        vm.warp(vm.getBlockTimestamp() + DECAY_SECONDS);
        (, Outcome memory o) = _assertShape(p, true, true, 1 ether, 20_000, 1_000);
        assertEq(o.fee + o.tax, _buyFee(0.02 ether, 1 ether, 20_000) + 0.1 ether);
        _assertShape(p, false, false, 1 ether, 20_000, 1_000);
    }

    /*//////////////////////////////////////////////////////////////
               DUST: ONE WEI, AND AMOUNTS THAT FLOOR TO ZERO
    //////////////////////////////////////////////////////////////*/

    /// @dev On Bin a swap whose unspecified amount rounds to zero is refused by CORE
    /// (`BinPool__InsufficientAmountUnSpecified`), with or without a hook, so the smallest swaps
    /// here are the smallest core lets through: two wei.
    function test_DUST_theSmallestSwapsTakeNothingAndWriteNothing() public {
        Pool memory p = _capsPool(false);
        // floor(2 * 10%) == 0 on both rates.
        Outcome memory o;
        // The two BUYS run with no share only: with one, the pool's own fee on two wei leaves core
        // nothing to trade and it refuses the swap (`BinPool__InsufficientAmountUnSpecified`).
        if (_lpShareBps() == 0) {
            (, o) = _assertShape(p, true, true, 2, 100_000, 1_000);
            assertEq(o.fee + o.tax, 0);
        }
        (, o) = _assertShape(p, false, true, 3, 100_000, 1_000);
        assertEq(o.fee + o.tax, 0);
        if (_lpShareBps() == 0) {
            (, o) = _assertShape(p, true, false, 2, 100_000, 1_000);
            assertEq(o.fee + o.tax, 0);
        }
        (, o) = _assertShape(p, false, false, 2, 100_000, 1_000);
        assertEq(o.fee + o.tax, 0);
        assertEq(hook.grossTaken(currency0), 0);
        assertEq(vault.balanceOf(address(hook), currency0), 0);
    }

    function test_DUST_eachRateFloorsOnItsOwn() public {
        Pool memory p = _default();
        (, Outcome memory o) = _assertShape(p, true, true, 19, FINAL_FEE, BUY_BPS);
        assertEq(o.fee + o.tax, 0);
        (, o) = _assertShape(p, true, true, 20, FINAL_FEE, BUY_BPS);
        assertEq(o.fee, 0);
        assertEq(o.tax, 1);
        (, o) = _assertShape(p, true, true, 334, FINAL_FEE, BUY_BPS);
        assertEq(o.fee, _buyFee(1, 334, FINAL_FEE));
        assertEq(o.tax, 16);
        (, o) = _assertShape(p, false, false, 33, FINAL_FEE, SELL_BPS);
        assertEq(o.fee + o.tax, 0);
        (, o) = _assertShape(p, false, false, 34, FINAL_FEE, SELL_BPS);
        assertEq(o.tax, 1);
    }

    /// @dev A Bin swap that runs out of liquidity REVERTS in core; it never fills in part. That is
    /// what keeps the Bin guard clear of the CL guard's open finding (a take in `beforeSwap` on an
    /// amount the pool then trades only part of), so it is pinned here: if core ever changes, this
    /// guard inherits the problem.
    function test_partialFill_coreRefusesASwapItCannotFill() public {
        vm.expectRevert(bytes4(keccak256("BinPool__OutOfLiquidity()")));
        _swap(key, true, -1_000 ether);
        vm.expectRevert(bytes4(keccak256("BinPool__OutOfLiquidity()")));
        _swap(key, false, 1_000 ether);
        assertEq(hook.grossTaken(currency0), 0, "the reverted take left nothing behind");
        assertEq(vault.balanceOf(address(hook), currency0), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            THE MINT ROUTE
    //////////////////////////////////////////////////////////////*/

    function test_MINT_activeBinIsClosedWhileTheTaxIsLive() public {
        // Lopsided X into the active bin: the implicit-swap route. Refused.
        IBinPoolManager.MintParams memory lopsided = _getCustomSingleSidedBinMintParam(ACTIVE_ID, 1 ether, false);
        _expectHookRevert(
            IBinHooks.beforeMint.selector,
            abi.encodeWithSelector(BinLaunchGuardHook.TaxedActiveBinMintBlocked.selector, poolId, ACTIVE_ID)
        );
        liquidityHelper.mint(key, lopsided, ZERO_BYTES);

        // A balanced multi-bin mint that includes the active bin is refused too (fail closed).
        (IBinPoolManager.MintParams memory spanning,) = _getMultipleBinMintParams(ACTIVE_ID, 1 ether, 1 ether, 2, 2);
        _expectHookRevert(
            IBinHooks.beforeMint.selector,
            abi.encodeWithSelector(BinLaunchGuardHook.TaxedActiveBinMintBlocked.selector, poolId, ACTIVE_ID)
        );
        liquidityHelper.mint(key, spanning, ZERO_BYTES);

        // Every other bin still accepts its own side: liquidity provision and seeding continue.
        _seedAround(key, 1 ether, 1 ether);

        // One second before expiry it is still closed; at expiry the active bin opens again.
        vm.warp(EXPIRES_AT - 1);
        _expectHookRevert(
            IBinHooks.beforeMint.selector,
            abi.encodeWithSelector(BinLaunchGuardHook.TaxedActiveBinMintBlocked.selector, poolId, ACTIVE_ID)
        );
        liquidityHelper.mint(key, lopsided, ZERO_BYTES);
        vm.warp(EXPIRES_AT);
        liquidityHelper.mint(key, lopsided, ZERO_BYTES);
    }

    /// @dev The active bin MOVES with trading, and the refusal follows it: the bin that is closed
    /// is the one core reports as active now, not the one the pool was born at.
    function test_MINT_theClosedBinIsTheOneThatIsActiveNow() public {
        _swap(key, true, -60 ether); // a buy large enough to empty the first bin below
        (uint24 activeNow,,) = poolManager.getSlot0(poolId);
        assertLt(activeNow, ACTIVE_ID, "the price moved down a bin");

        bytes32[] memory cfgs = new bytes32[](1);
        cfgs[0] = LiquidityConfigurations.encodeParams(1e18, 0, activeNow);
        IBinPoolManager.MintParams memory intoActive = IBinPoolManager.MintParams({
            liquidityConfigs: cfgs, amountIn: PackedUint128Math.encode(1 ether, 0), salt: 0
        });
        _expectHookRevert(
            IBinHooks.beforeMint.selector,
            abi.encodeWithSelector(BinLaunchGuardHook.TaxedActiveBinMintBlocked.selector, poolId, activeNow)
        );
        liquidityHelper.mint(key, intoActive, ZERO_BYTES);

        // The bin the pool was born at is an ordinary bin above the price now: X only, no swap.
        cfgs[0] = LiquidityConfigurations.encodeParams(1e18, 0, ACTIVE_ID);
        liquidityHelper.mint(
            key,
            IBinPoolManager.MintParams({
                liquidityConfigs: cfgs, amountIn: PackedUint128Math.encode(1 ether, 0), salt: 0
            }),
            ZERO_BYTES
        );
    }

    function test_MINT_untaxedPoolNeverGatesTheActiveBin() public {
        Pool memory p = _reserve(currency0, currency1, false);
        hook.configureLaunch(p.key, _defaultConfigAt(uint40(vm.getBlockTimestamp() + 10)));
        hook.configureFeeSplit(p.key, _defaultFeeSplit());
        poolManager.initialize(p.key, ACTIVE_ID);
        liquidityHelper.mint(p.key, _getSingleBinMintParams(ACTIVE_ID, 1 ether, 1 ether), ZERO_BYTES);
    }

    /// @dev `beforeMint` still hands core the guard's fee, with the override flag, as the
    /// composition fee: the swap path returns zero, the mint path does not.
    function test_MINT_beforeMintStillReturnsTheGuardsFee() public {
        uint40 start = uint40(vm.getBlockTimestamp() + 10);
        Pool memory p = _launch(false, _defaultConfigAt(start), _zeroTax());
        IBinPoolManager.MintParams memory mp = _getSingleBinMintParams(ACTIVE_ID, 1 ether, 1 ether);

        uint40[4] memory at = [start - 5, start, start + 50, start + DECAY_SECONDS];
        uint24[4] memory fee = [INITIAL_FEE, INITIAL_FEE, uint24(16_500), FINAL_FEE];
        for (uint256 i; i < at.length; ++i) {
            vm.warp(at[i]);
            vm.prank(address(poolManager));
            (bytes4 sel, uint24 returned) = hook.beforeMint(address(this), p.key, mp, ZERO_BYTES);
            assertEq(sel, IBinHooks.beforeMint.selector);
            assertEq(returned, fee[i] | LPFeeLibrary.OVERRIDE_FEE_FLAG, "the guard's fee, flagged");
        }
    }

    /*//////////////////////////////////////////////////////////////
                      SETTLEMENT, CLAIMS, REDEEM, SKIM
    //////////////////////////////////////////////////////////////*/

    /// @dev MUTATION-CHECKED (i) on the Bin guard.
    function test_settleFee_splitsByTheFeeSplitWithRemainderToProtocol() public {
        _swap(key, true, AMOUNT);
        uint256 pot = hook.pendingFee(poolId, currency0);
        uint256 taxPot = hook.pendingTax(poolId, currency0);
        assertEq(pot, _buyFee(0.003 ether, 1 ether, FINAL_FEE));
        assertEq(taxPot, 0.05 ether);
        uint256 toCreator = _share(pot, FEE_CREATOR_BPS);
        uint256 toIntegrator = _share(pot, FEE_INTEGRATOR_BPS);
        uint256 toProtocol = pot - toCreator - toIntegrator;
        if (_lpShareBps() == 0) {
            assertEq(toCreator, 0.00195 ether);
            assertEq(toIntegrator, 0.00045 ether);
            assertEq(toProtocol, 0.0006 ether);
        }

        vm.expectEmit(true, true, false, true, address(hook));
        emit LaunchTaxModule.FeeSettled(poolId, currency0, toCreator, toProtocol, toIntegrator);
        hook.settleFee(poolId, currency0);
        assertEq(hook.pendingFee(poolId, currency0), 0);
        assertEq(hook.claimable(feeCreator, currency0), toCreator);
        assertEq(hook.claimable(feeIntegrator, currency0), toIntegrator);
        assertEq(hook.claimable(PROTOCOL, currency0), toProtocol);
        assertEq(hook.claimable(creator, currency0) + hook.claimable(integrator, currency0), 0);
        assertEq(hook.pendingTax(poolId, currency0), taxPot);
        assertEq(hook.totalOwed(currency0), pot + taxPot);

        vm.expectEmit(true, true, false, true, address(hook));
        emit LaunchTaxModule.TaxSettled(poolId, currency0, 0.035 ether, 0.005 ether, 0.01 ether);
        hook.settleTax(poolId, currency0);
        assertEq(hook.claimable(creator, currency0), 0.035 ether);
        assertEq(hook.claimable(integrator, currency0), 0.01 ether);
        assertEq(hook.claimable(PROTOCOL, currency0), toProtocol + 0.005 ether);
        _assertLedgerSums(currency0);
        _assertSolvent(currency0);
    }

    function test_settleClaimSkim() public {
        _swap(key, true, AMOUNT);
        _swap(key, false, AMOUNT);
        _swap(key, true, 1 ether);
        _swap(key, false, 1 ether);
        assertEq(hook.totalOwed(currency1), 0, "four shapes, nothing in the launch token");
        uint256 owed = hook.totalOwed(currency0);
        assertEq(owed, hook.pendingFee(poolId, currency0) + hook.pendingTax(poolId, currency0));

        PoolId[] memory ids = new PoolId[](1);
        ids[0] = poolId;
        address[5] memory parties = [creator, integrator, feeCreator, feeIntegrator, PROTOCOL];
        uint256 paid;
        for (uint256 i; i < parties.length; ++i) {
            vm.prank(parties[i]);
            uint256 got = hook.claimFrom(ids, currency0, parties[i]);
            assertEq(token0.balanceOf(parties[i]), got);
            paid += got;
            _assertSolvent(currency0);
        }
        assertEq(paid, owed, "both pots, paid out to the wei");
        assertEq(hook.totalOwed(currency0), 0);
        assertEq(hook.backing(currency0), 0);

        token0.transfer(address(hook), 7);
        assertEq(hook.skim(currency0), 7);
        assertEq(hook.claimable(PROTOCOL, currency0), 7);
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.NothingToSkim.selector, currency0));
        hook.skim(currency0);
    }

    function test_redeem_isPermissionlessAndPaysNobody() public {
        _swap(key, true, AMOUNT);
        vm.prank(makeAddr("keeper"));
        uint256 claims = _buyFee(0.003 ether, 1 ether, FINAL_FEE) + 0.05 ether;
        assertEq(hook.redeem(currency0), claims);
        assertEq(token0.balanceOf(address(hook)), claims);
        assertEq(vault.balanceOf(address(hook), currency0), 0);
        assertEq(hook.totalOwed(currency0), claims);
        assertEq(hook.redeem(currency1), 0);
        _assertSolvent(currency0);
    }

    function test_native_quoteOnBin() public {
        vm.deal(address(this), 10_000 ether);
        Currency n = CurrencyLibrary.NATIVE;
        Pool memory p = _reserve(n, currency1, false); // native sorts to currency0: the quote
        uint40 start = uint40(vm.getBlockTimestamp() + 10);
        _open(p, _defaultConfigAt(start), _defaultFeeSplit(), _validTax());
        vm.warp(start + DECAY_SECONDS);

        (, Outcome memory o) = _assertShape(p, true, true, 1 ether, FINAL_FEE, BUY_BPS);
        assertEq(o.traderQuote, -1 ether);
        _assertShape(p, false, true, 1 ether, FINAL_FEE, SELL_BPS);
        _assertShape(p, true, false, 1 ether, FINAL_FEE, BUY_BPS);
        (, o) = _assertShape(p, false, false, 1 ether, FINAL_FEE, SELL_BPS);
        assertEq(o.traderQuote, 1 ether);
        assertEq(vault.balanceOf(address(hook), currency1), 0);

        uint256 feePot = hook.pendingFee(p.id, n);
        uint256 taxPot = hook.pendingTax(p.id, n);
        hook.settleFee(p.id, n);
        hook.settleTax(p.id, n);
        vm.prank(feeCreator);
        hook.claim(n, feeCreator);
        assertEq(feeCreator.balance, feePot * FEE_CREATOR_BPS / 10_000);
        vm.prank(creator);
        hook.claim(n, creator);
        assertEq(creator.balance, taxPot * 7_000 / 10_000);
        _assertSolvent(n);
    }

    /*//////////////////////////////////////////////////////////////
                           SOLVENCY AND FUZZ
    //////////////////////////////////////////////////////////////*/

    function testFuzz_SOLVENCY_backingCoversObligationsAfterEveryStep(uint256 seed) public {
        address[5] memory parties = [creator, integrator, feeCreator, feeIntegrator, PROTOCOL];
        for (uint256 step; step < 24; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seed, step)));
            uint256 op = r % 10;
            if (op == 0) _swap(key, true, -int128(uint128(1_000 + (r >> 8) % 0.05 ether)));
            else if (op == 1) _swap(key, false, -int128(uint128(1_000 + (r >> 8) % 0.05 ether)));
            else if (op == 2) _swap(key, true, int128(uint128(1_000 + (r >> 8) % 0.02 ether)));
            else if (op == 3) _swap(key, false, int128(uint128(1_000 + (r >> 8) % 0.02 ether)));
            else if (op == 4) hook.settleTax(poolId, (r >> 8) % 2 == 0 ? currency0 : currency1);
            else if (op == 5) hook.settleFee(poolId, (r >> 8) % 2 == 0 ? currency0 : currency1);
            else if (op == 6) {
                address who = parties[(r >> 8) % 5];
                Currency c = (r >> 16) % 2 == 0 ? currency0 : currency1;
                if (hook.claimable(who, c) != 0) {
                    vm.prank(who);
                    hook.claim(c, who);
                }
            } else if (op == 7) hook.redeem((r >> 8) % 2 == 0 ? currency0 : currency1);
            else if (op == 8) {
                token0.transfer(address(hook), 1 + (r >> 8) % 1000);
                hook.skim(currency0);
            } else vm.warp(vm.getBlockTimestamp() + (r >> 8) % 400);
            _assertSolvent(currency0);
            _assertSolvent(currency1);
            _assertLedgerSums(currency0);
            _assertLedgerSums(currency1);
            assertEq(hook.grossTaken(currency1), 0, "the launch token was taken");
            assertEq(vault.balanceOf(address(hook), currency1), 0, "a launch-token claim appeared");
        }
    }

    struct FuzzIn {
        uint256 amount;
        bool tokenIs0;
        bool isBuy;
        bool exactIn;
        uint24 initialFee;
        uint24 finalFee;
        uint16 buyBps;
        uint16 sellBps;
        uint32 decaySeconds;
        uint32 elapsed;
        bool enabled;
    }

    function testFuzz_take_everyShapeEveryRate(FuzzIn memory f) public {
        // From 1_000 wei up: below that core itself refuses swaps whose other side rounds to zero.
        f.amount = bound(f.amount, 1_000, 1 ether);
        f.finalFee = uint24(bound(f.finalFee, 0, hook.MAX_FINAL_FEE()));
        f.initialFee = uint24(bound(f.initialFee, f.finalFee, hook.MAX_INITIAL_FEE()));
        f.buyBps = uint16(bound(f.buyBps, 0, hook.MAX_TAX_BPS()));
        f.sellBps = uint16(bound(f.sellBps, 0, hook.MAX_TAX_BPS()));
        f.decaySeconds = uint32(bound(f.decaySeconds, hook.MIN_DECAY_SECONDS(), 5_000));
        f.elapsed = uint32(bound(f.elapsed, 0, uint256(f.decaySeconds) + 100));

        uint40 start = uint40(vm.getBlockTimestamp() + 10);
        BinLaunchGuardHook.LaunchConfig memory c = _defaultConfigAt(start);
        c.initialFeeBips = f.initialFee;
        c.finalFeeBips = f.finalFee;
        c.decaySeconds = f.decaySeconds;
        c.enabled = f.enabled;
        LaunchTaxModule.TaxConfig memory t = _validTax();
        t.buyBps = f.buyBps;
        t.sellBps = f.sellBps;
        t.expiresAt = uint40(uint256(start) + f.decaySeconds + 50);
        if (f.buyBps == 0 && f.sellBps == 0) t = _zeroTax();
        Pool memory p = _launch(f.tokenIs0, c, t);

        vm.warp(uint256(start) + f.elapsed);
        uint24 feePips = f.enabled ? _decayed(f.initialFee, f.finalFee, f.elapsed, f.decaySeconds) : f.finalFee;
        uint16 taxBps = vm.getBlockTimestamp() < t.expiresAt ? (f.isBuy ? f.buyBps : f.sellBps) : 0;
        assertEq(hook.currentFee(p.id), feePips, "the view agrees with the schedule");

        (Expected memory e, Outcome memory o) = _assertShape(p, f.isBuy, f.exactIn, f.amount, feePips, taxBps);
        assertLe(o.fee + o.tax, e.base * 2 / 10, "never more than 20% of the quote amount on Bin");
        if (f.exactIn == f.isBuy) assertEq(_abs(o.traderQuote), f.amount, "the trader moves exactly what it named");
        else assertEq(_abs(o.traderToken), f.amount, "the trader moves exactly what it named");
    }

    /*//////////////////////////////////////////////////////////////
        THE LIQUIDITY PROVIDERS' SHARE (owner decision, 2026-09-28).
        Every test here holds under every share, zero included.
    //////////////////////////////////////////////////////////////*/

    function test_lpShare_isTheOneTheGuardWasBuiltWith() public view {
        assertEq(hook.LP_SHARE_BPS(), _lpShareBps());
        assertEq(hook.MAX_LP_SHARE_BPS(), 5_000);
    }

    function test_lpShare_aboveTheCapIsRefusedAtConstruction() public {
        vm.expectRevert(abi.encodeWithSelector(LaunchTaxModule.LpShareTooHigh.selector, uint16(5_001)));
        new BinLaunchGuardHook(poolManager, ILaunchTokenOrigin(address(0)), PROTOCOL, 5_001);

        BinLaunchGuardHook atCap = new BinLaunchGuardHook(poolManager, ILaunchTokenOrigin(address(0)), PROTOCOL, 5_000);
        assertEq(atCap.LP_SHARE_BPS(), 5_000);
        BinLaunchGuardHook none = new BinLaunchGuardHook(poolManager, ILaunchTokenOrigin(address(0)), PROTOCOL, 0);
        assertEq(none.LP_SHARE_BPS(), 0);
    }

    function test_lpShare_thePartsOfTheFeeSumToTheFeeAtEverySecond() public view {
        for (uint256 t = START_TIME; t <= uint256(START_TIME) + DECAY_SECONDS + 3; t++) {
            uint24 fee = _decayed(INITIAL_FEE, FINAL_FEE, t - START_TIME, DECAY_SECONDS);
            assertEq(hook.feeAt(poolId, t), fee, "the fee");
            (uint24 buyLp, uint24 buyGuard, uint24 sellGuard) = hook.feePartsAt(poolId, t);
            assertEq(buyLp, uint256(fee) * _lpShareBps() / 10_000, "the pool's part of a buy");
            assertEq(uint256(buyLp) + buyGuard, fee, "the two parts of a buy");
            assertEq(sellGuard, fee, "a sell has one part");
        }
        (uint24 lp, uint24 guard, uint24 sell) = hook.currentFeeParts(poolId);
        assertEq(lp, _lpPips(FINAL_FEE, true));
        assertEq(guard, _guardPips(FINAL_FEE, true));
        assertEq(sell, FINAL_FEE);
    }

    /// @dev A buy's two parts are never more than the fee, on either shape, in either orientation,
    /// at the open where the fee is largest.
    function test_lpShare_aBuyNeverPaysMoreThanTheFee() public {
        for (uint256 i = 0; i < 2; i++) {
            Pool memory p = _launch(i == 1, _defaultConfigAt(uint40(vm.getBlockTimestamp())), _zeroTax());
            (Expected memory e, Outcome memory o) = _assertShape(p, true, true, 1 ether, INITIAL_FEE, 0);
            uint256 lpPaid = (_abs(o.poolQuote) * e.lpFee + 999_999) / 1_000_000;
            assertLe(o.fee + lpPaid, uint256(1 ether) * INITIAL_FEE / 1_000_000, "exact input");

            (e, o) = _assertShape(p, true, false, 0.5 ether, INITIAL_FEE, 0);
            lpPaid = (_abs(o.poolQuote) * e.lpFee + 999_999) / 1_000_000;
            assertLe(o.fee + lpPaid, _abs(o.poolQuote) * INITIAL_FEE / 1_000_000 + 1, "exact output");

            // A sell pays the pool nothing: `_assertMatches` has checked the LP fee core applied.
            (e, o) = _assertShape(p, false, true, 0.5 ether, INITIAL_FEE, 0);
            assertEq(e.lpFee, 0);
            assertEq(o.fee, _abs(o.poolQuote) * INITIAL_FEE / 1_000_000, "the whole fee, to the guard");
        }
    }

    function test_GAS_swapByShape() public {
        _setControlFee(0);
        _swap(key, true, AMOUNT);
        uint256 g = gasleft();
        _swap(key, true, AMOUNT);
        uint256 buyIn = g - gasleft();
        g = gasleft();
        _swap(key, false, AMOUNT);
        uint256 sellIn = g - gasleft();
        g = gasleft();
        _swap(key, true, 1 ether);
        uint256 buyOut = g - gasleft();
        g = gasleft();
        _swap(key, false, 1 ether);
        uint256 sellOut = g - gasleft();
        vm.warp(EXPIRES_AT);
        g = gasleft();
        _swap(key, true, AMOUNT);
        uint256 expired = g - gasleft();
        _swap(control, true, AMOUNT);
        g = gasleft();
        _swap(control, true, AMOUNT);
        uint256 noHook = g - gasleft();
        console2.log("Bin swap gas, fee + tax, buy exact-in   (beforeSwap):", buyIn);
        console2.log("Bin swap gas, fee + tax, sell exact-in  (afterSwap): ", sellIn);
        console2.log("Bin swap gas, fee + tax, buy exact-out  (afterSwap): ", buyOut);
        console2.log("Bin swap gas, fee + tax, sell exact-out (beforeSwap):", sellOut);
        console2.log("Bin swap gas, fee only (tax expired), buy exact-in:  ", expired);
        console2.log("Bin swap gas, the same pool with no hook:            ", noHook);
    }
}

/*//////////////////////////////////////////////////////////////
    THE WHOLE SUITE AGAIN, UNDER A SHARE.

    2,000 is the share the release is proposed at; 5,000 is the cap, where the
    pool's part is as large as it can be; 3,333 does not divide a fee evenly,
    so the rounding pip is in every number.
//////////////////////////////////////////////////////////////*/

contract LaunchTaxCLShare2000Test is LaunchTaxCLTest {
    function _lpShareBps() internal pure override returns (uint16) {
        return 2_000;
    }
}

contract LaunchTaxCLShare3333Test is LaunchTaxCLTest {
    function _lpShareBps() internal pure override returns (uint16) {
        return 3_333;
    }
}

contract LaunchTaxCLShareCapTest is LaunchTaxCLTest {
    function _lpShareBps() internal pure override returns (uint16) {
        return 5_000;
    }
}

contract LaunchTaxBinShare2000Test is LaunchTaxBinTest {
    function _lpShareBps() internal pure override returns (uint16) {
        return 2_000;
    }
}

contract LaunchTaxBinShare3333Test is LaunchTaxBinTest {
    function _lpShareBps() internal pure override returns (uint16) {
        return 3_333;
    }
}

contract LaunchTaxBinShareCapTest is LaunchTaxBinTest {
    function _lpShareBps() internal pure override returns (uint16) {
        return 5_000;
    }
}
