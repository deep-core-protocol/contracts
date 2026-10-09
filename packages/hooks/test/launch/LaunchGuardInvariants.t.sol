// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {BinPoolManager} from "infinity-core/src/pool-bin/BinPoolManager.sol";
import {IBinPoolManager} from "infinity-core/src/pool-bin/interfaces/IBinPoolManager.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "infinity-core/src/types/Currency.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";
import {BinPoolParametersHelper} from "infinity-core/src/pool-bin/libraries/BinPoolParametersHelper.sol";
import {LiquidityConfigurations} from "infinity-core/src/pool-bin/libraries/math/LiquidityConfigurations.sol";
import {PackedUint128Math} from "infinity-core/src/pool-bin/libraries/math/PackedUint128Math.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";

import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {BinSwapHelper} from "infinity-core/test/pool-bin/helpers/BinSwapHelper.sol";
import {BinLiquidityHelper} from "infinity-core/test/pool-bin/helpers/BinLiquidityHelper.sol";

import {LaunchGuardHook, ILaunchTokenOrigin} from "../../src/launch/LaunchGuardHook.sol";
import {BinLaunchGuardHook} from "../../src/launch/BinLaunchGuardHook.sol";
import {LaunchTaxModule} from "../../src/launch/LaunchTaxModule.sol";

/*//////////////////////////////////////////////////////////////
    STATEFUL INVARIANTS OF THE LAUNCH GUARDS' LEDGER

    Two pools on one guard and ONE pair of currencies, mirrored: currency1 is the launch token of
    pool 0 and the quote of pool 1, and the other way round for currency0. So both currencies
    collect fees, each from the pool where it is the quote, and a take in the launch token on
    either pool would land in a currency the guard legitimately holds - which is exactly the case
    a balance check alone would miss, and the reason the handler measures every swap on its own.

    The handler calls everything a trader, a fee party or a stranger can reach: the four swap
    shapes, both settlements, claim and claimFrom, redeem, skim, a stray transfer in, the fee
    creator's handover, and the clock.

      1. backing(c) >= totalOwed(c)
      2. totalOwed(c) == sum over pools of (pendingFee + pendingTax) + sum over parties of claimable
      3. grossTaken(c) == sum over pools of (feeTaken + totalTaken)
      4. no swap ever takes the launch token, and core never applies an LP fee
//////////////////////////////////////////////////////////////*/

abstract contract GuardHandler is Test {
    using CurrencyLibrary for Currency;

    LaunchTaxModule public guard;
    IVault public vault;
    address public poolManager;
    Currency[2] public currencies;
    /// @dev ids[0]: the launch token is currency1. ids[1]: the launch token is currency0.
    PoolId[2] public ids;

    address[] internal _parties;
    address internal immutable _suite;

    // ---- ghosts ----
    uint256 public swaps;
    uint256 public swapsByShape0; // buy,  exact input
    uint256 public swapsByShape1; // sell, exact input
    uint256 public swapsByShape2; // buy,  exact output
    uint256 public swapsByShape3; // sell, exact output
    /// @dev Growth, summed over every swap, of everything the guard holds or counts in the swapped
    /// pool's LAUNCH TOKEN. Must stay zero.
    uint256 public launchTokenTaken;
    /// @dev Swaps on which core's own event reported an LP fee other than zero. Must stay zero.
    uint256 public swapsWithAnLpFee;
    uint256 public handovers;

    constructor(LaunchTaxModule guard_, IVault vault_, address poolManager_, Currency c0, Currency c1, PoolId a, PoolId b) {
        guard = guard_;
        vault = vault_;
        poolManager = poolManager_;
        currencies[0] = c0;
        currencies[1] = c1;
        ids[0] = a;
        ids[1] = b;
        _suite = msg.sender;
    }

    /// @dev The suite's, while it sets up. Not a fuzz target: a party listed twice would be counted
    /// twice by the ledger sum.
    function addParty(address who) external {
        require(msg.sender == _suite, "addParty: not the suite");
        _parties.push(who);
    }

    /// @dev What the campaign calls, and nothing else (the getters are not targets). The four swap
    /// shapes are four entries so that a run of 48 calls all but certainly trades.
    function targets() external pure returns (bytes4[] memory t) {
        t = new bytes4[](14);
        t[0] = this.buyExactIn.selector;
        t[1] = this.sellExactIn.selector;
        t[2] = this.buyExactOut.selector;
        t[3] = this.sellExactOut.selector;
        t[4] = this.settleFee.selector;
        t[5] = this.settleTax.selector;
        t[6] = this.claim.selector;
        t[7] = this.claimFrom.selector;
        t[8] = this.redeem.selector;
        t[9] = this.strayTransfer.selector;
        t[10] = this.skim.selector;
        t[11] = this.handover.selector;
        t[12] = this.warp.selector;
        t[13] = this.strayThenSkim.selector;
    }

    function parties() external view returns (address[] memory) {
        return _parties;
    }

    /// @dev `forward` is `zeroForOne` on CL and `swapForY` on Bin: currency0 in, currency1 out.
    function _swap(uint256 pool, bool forward, int256 amountSpecified) internal virtual;

    /// @dev The LP fee out of core's `Swap` event data.
    function _lpFee(bytes memory data) internal pure virtual returns (uint24);

    function _swapTopic() internal pure virtual returns (bytes32);

    function _footprint(PoolId id, Currency c) internal view returns (uint256) {
        return guard.feeTaken(id, c) + guard.totalTaken(id, c) + guard.grossTaken(c) + guard.totalOwed(c)
            + vault.balanceOf(address(guard), c) + c.balanceOf(address(guard));
    }

    function buyExactIn(uint256 poolSeed, uint256 amount) external {
        _trade(poolSeed, true, true, amount);
    }

    function sellExactIn(uint256 poolSeed, uint256 amount) external {
        _trade(poolSeed, false, true, amount);
    }

    function buyExactOut(uint256 poolSeed, uint256 amount) external {
        _trade(poolSeed, true, false, amount);
    }

    function sellExactOut(uint256 poolSeed, uint256 amount) external {
        _trade(poolSeed, false, false, amount);
    }

    function _trade(uint256 poolSeed, bool isBuy, bool exactIn, uint256 amount) internal {
        uint256 i = poolSeed % 2;
        bool tokenIs0 = i == 1;
        Currency token = tokenIs0 ? currencies[0] : currencies[1];
        amount = bound(amount, 1_000, exactIn ? 0.05 ether : 0.02 ether);

        uint256 before = _footprint(ids[i], token);
        vm.recordLogs();
        // A buy is quote in: currency0 in (forward) when the launch token is currency1.
        _swap(i, isBuy ? !tokenIs0 : tokenIs0, exactIn ? -int256(amount) : int256(amount));
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 l = 0; l < logs.length; l++) {
            if (logs[l].emitter == poolManager && logs[l].topics[0] == _swapTopic()) {
                if (_lpFee(logs[l].data) != 0) swapsWithAnLpFee++;
            }
        }
        launchTokenTaken += _footprint(ids[i], token) - before;

        swaps++;
        if (isBuy && exactIn) swapsByShape0++;
        else if (!isBuy && exactIn) swapsByShape1++;
        else if (isBuy) swapsByShape2++;
        else swapsByShape3++;
    }

    function settleFee(uint256 poolSeed, uint256 currencySeed) external {
        guard.settleFee(ids[poolSeed % 2], currencies[currencySeed % 2]);
    }

    function settleTax(uint256 poolSeed, uint256 currencySeed) external {
        guard.settleTax(ids[poolSeed % 2], currencies[currencySeed % 2]);
    }

    function claim(uint256 partySeed, uint256 currencySeed) external {
        address who = _parties[partySeed % _parties.length];
        Currency c = currencies[currencySeed % 2];
        if (guard.claimable(who, c) == 0) return;
        vm.prank(who);
        guard.claim(c, who);
    }

    function claimFrom(uint256 partySeed, uint256 currencySeed) external {
        address who = _parties[partySeed % _parties.length];
        Currency c = currencies[currencySeed % 2];
        PoolId[] memory both = new PoolId[](2);
        both[0] = ids[0];
        both[1] = ids[1];
        vm.prank(who);
        try guard.claimFrom(both, c, who) {} catch (bytes memory why) {
            // The only refusal a listed party can meet: both pots settled to it nothing.
            require(bytes4(why) == LaunchTaxModule.NothingToClaim.selector, "claimFrom: unexpected revert");
            // The revert rolled the settlement back with it; settle for real so the walk goes on.
            guard.settleFee(ids[0], c);
            guard.settleFee(ids[1], c);
            guard.settleTax(ids[0], c);
            guard.settleTax(ids[1], c);
        }
    }

    function redeem(uint256 currencySeed) external {
        guard.redeem(currencies[currencySeed % 2]);
    }

    /// @dev A token sent to the guard by mistake. It stays surplus until somebody skims it.
    function strayTransfer(uint256 currencySeed, uint256 amount) external {
        Currency c = currencies[currencySeed % 2];
        MockERC20(Currency.unwrap(c)).transfer(address(guard), bound(amount, 1, 1 ether));
    }

    function skim(uint256 currencySeed) external {
        Currency c = currencies[currencySeed % 2];
        if (guard.backing(c) <= guard.totalOwed(c)) return;
        guard.skim(c);
    }

    function strayThenSkim(uint256 currencySeed, uint256 amount) external {
        Currency c = currencies[currencySeed % 2];
        MockERC20(Currency.unwrap(c)).transfer(address(guard), bound(amount, 1, 1 ether));
        guard.skim(c);
    }

    /// @dev The fee creator of a pool hands over, two steps, to an address nobody has used.
    function handover(uint256 poolSeed) external {
        PoolId id = ids[poolSeed % 2];
        address current = guard.getFeeSplit(id).creator;
        address next = address(uint160(uint256(keccak256(abi.encode("fee creator", handovers++)))));
        vm.prank(current);
        guard.transferCreator(uint256(PoolId.unwrap(id)), next);
        vm.prank(next);
        guard.acceptCreator(uint256(PoolId.unwrap(id)));
        _parties.push(next);
    }

    function warp(uint256 secs) external {
        vm.warp(vm.getBlockTimestamp() + bound(secs, 1, 2 days));
    }
}

contract CLGuardHandler is GuardHandler {
    CLPoolManagerRouter public router;
    PoolKey[2] internal _keys;

    constructor(
        LaunchGuardHook guard_,
        IVault vault_,
        CLPoolManager pm,
        CLPoolManagerRouter router_,
        PoolKey memory a,
        PoolKey memory b
    ) GuardHandler(guard_, vault_, address(pm), a.currency0, a.currency1, a.toId(), b.toId()) {
        router = router_;
        _keys[0] = a;
        _keys[1] = b;
        MockERC20(Currency.unwrap(a.currency0)).approve(address(router_), type(uint256).max);
        MockERC20(Currency.unwrap(a.currency1)).approve(address(router_), type(uint256).max);
    }

    function _swap(uint256 pool, bool forward, int256 amountSpecified) internal override {
        router.swap(
            _keys[pool],
            ICLPoolManager.SwapParams({
                zeroForOne: forward,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: forward ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
    }

    function _lpFee(bytes memory data) internal pure override returns (uint24 fee) {
        (,,,,, fee,) = abi.decode(data, (int128, int128, uint160, uint128, int24, uint24, uint16));
    }

    function _swapTopic() internal pure override returns (bytes32) {
        return ICLPoolManager.Swap.selector;
    }
}

contract BinGuardHandler is GuardHandler {
    BinSwapHelper public swapHelper;
    PoolKey[2] internal _keys;

    constructor(
        BinLaunchGuardHook guard_,
        IVault vault_,
        BinPoolManager pm,
        BinSwapHelper swapHelper_,
        PoolKey memory a,
        PoolKey memory b
    ) GuardHandler(guard_, vault_, address(pm), a.currency0, a.currency1, a.toId(), b.toId()) {
        swapHelper = swapHelper_;
        _keys[0] = a;
        _keys[1] = b;
        MockERC20(Currency.unwrap(a.currency0)).approve(address(swapHelper_), type(uint256).max);
        MockERC20(Currency.unwrap(a.currency1)).approve(address(swapHelper_), type(uint256).max);
    }

    function _swap(uint256 pool, bool forward, int256 amountSpecified) internal override {
        // forge-lint: disable-next-line(unsafe-typecast)
        swapHelper.swap(_keys[pool], forward, int128(amountSpecified), BinSwapHelper.TestSettings(true, true), "");
    }

    function _lpFee(bytes memory data) internal pure override returns (uint24 fee) {
        (,,, fee,) = abi.decode(data, (int128, int128, uint24, uint24, uint16));
    }

    function _swapTopic() internal pure override returns (bytes32) {
        return IBinPoolManager.Swap.selector;
    }
}

/// @dev The assertions, shared by the two suites below.
abstract contract GuardInvariants is Test {
    using CurrencyLibrary for Currency;

    address constant PROTOCOL = address(0xFEE);

    Vault vault;
    LaunchTaxModule guard;
    GuardHandler handler;
    MockERC20 token0;
    MockERC20 token1;
    Currency currency0;
    Currency currency1;
    PoolId[2] ids;

    function _tokens() internal {
        token0 = new MockERC20("TestA", "A", 18);
        token1 = new MockERC20("TestB", "B", 18);
        (token0, token1) = address(token0) < address(token1) ? (token0, token1) : (token1, token0);
        currency0 = Currency.wrap(address(token0));
        currency1 = Currency.wrap(address(token1));
        token0.mint(address(this), 1_000_000 ether);
        token1.mint(address(this), 1_000_000 ether);
    }

    /// @dev Two tax splits and two fee splits, all four different, so every pot has its own parties.
    function _tax(uint256 i) internal returns (LaunchTaxModule.TaxConfig memory) {
        return LaunchTaxModule.TaxConfig({
            buyBps: i == 0 ? 500 : 1_000,
            sellBps: i == 0 ? 300 : 700,
            expiresAt: uint40(vm.getBlockTimestamp() + 20 days),
            creator: makeAddr(i == 0 ? "taxCreator0" : "taxCreator1"),
            integrator: makeAddr(i == 0 ? "taxIntegrator0" : "taxIntegrator1"),
            creatorBps: i == 0 ? 7_000 : 3_000,
            protocolBps: i == 0 ? 1_000 : 5_000,
            integratorBps: 2_000
        });
    }

    function _split(uint256 i) internal returns (LaunchTaxModule.FeeSplit memory) {
        return LaunchTaxModule.FeeSplit({
            creator: makeAddr(i == 0 ? "feeCreator0" : "feeCreator1"),
            creatorBps: i == 0 ? 6_500 : 4_777,
            protocolBps: i == 0 ? 2_000 : 3_223,
            integratorBps: i == 0 ? 1_500 : 2_000,
            integrator: makeAddr(i == 0 ? "feeIntegrator0" : "feeIntegrator1")
        });
    }

    function _enlist() internal {
        for (uint256 i; i < 2; ++i) {
            LaunchTaxModule.TaxConfig memory t = _tax(i);
            LaunchTaxModule.FeeSplit memory f = _split(i);
            handler.addParty(t.creator);
            handler.addParty(t.integrator);
            handler.addParty(f.creator);
            handler.addParty(f.integrator);
        }
        handler.addParty(PROTOCOL);
        token0.transfer(address(handler), 100_000 ether);
        token1.transfer(address(handler), 100_000 ether);

        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: handler.targets()}));
    }

    function _currency(uint256 i) internal view returns (Currency) {
        return i == 0 ? currency0 : currency1;
    }

    function invariant_backingCoversEveryObligation() public view {
        for (uint256 i; i < 2; ++i) {
            Currency c = _currency(i);
            assertGe(guard.backing(c), guard.totalOwed(c), "backing < totalOwed");
        }
    }

    function invariant_potsAndClaimableAreTheWholeObligation() public view {
        address[] memory parties = handler.parties();
        for (uint256 i; i < 2; ++i) {
            Currency c = _currency(i);
            uint256 ledger;
            uint256 taken;
            for (uint256 p; p < 2; ++p) {
                // `pendingFee` and `pendingTax` are subtractions: a settled counter above its taken
                // counter would revert here, which is the check that they never cross.
                ledger += guard.pendingFee(ids[p], c) + guard.pendingTax(ids[p], c);
                taken += guard.feeTaken(ids[p], c) + guard.totalTaken(ids[p], c);
            }
            for (uint256 p; p < parties.length; ++p) {
                ledger += guard.claimable(parties[p], c);
            }
            assertEq(ledger, guard.totalOwed(c), "pots + claimable != totalOwed");
            assertEq(taken, guard.grossTaken(c), "grossTaken != fee taken + tax taken");
        }
    }

    function invariant_theLaunchTokenIsNeverTakenAndTheLpFeeIsZero() public view {
        assertEq(handler.launchTokenTaken(), 0, "a swap took launch token");
        assertEq(handler.swapsWithAnLpFee(), 0, "core applied an LP fee");
        // Pool 0's launch token is currency1; pool 1's is currency0. Neither pool ever counted a
        // unit of its own launch token, as fee or as tax.
        assertEq(guard.feeTaken(ids[0], currency1) + guard.totalTaken(ids[0], currency1), 0);
        assertEq(guard.feeTaken(ids[1], currency0) + guard.totalTaken(ids[1], currency0), 0);
    }

    /// @dev Not an invariant of the contract but of the campaign: it fails if the handler stopped
    /// reaching the swap path, which would make the three above vacuous.
    function afterInvariant() public view {
        assertGt(
            handler.swapsByShape0() + handler.swapsByShape1() + handler.swapsByShape2() + handler.swapsByShape3(),
            0,
            "the campaign never swapped"
        );
    }
}

/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 48
/// forge-config: legacy.invariant.runs = 32
/// forge-config: legacy.invariant.depth = 48
contract LaunchGuardInvariantCLTest is GuardInvariants {
    function setUp() public {
        vault = new Vault();
        CLPoolManager pm = new CLPoolManager(IVault(address(vault)));
        vault.registerApp(address(pm));
        LaunchGuardHook hook = new LaunchGuardHook(pm, ILaunchTokenOrigin(address(0)), PROTOCOL, 0);
        guard = hook;
        CLPoolManagerRouter router = new CLPoolManagerRouter(vault, pm);
        _tokens();
        token0.approve(address(router), type(uint256).max);
        token1.approve(address(router), type(uint256).max);

        PoolKey[2] memory keys;
        for (uint256 i; i < 2; ++i) {
            keys[i] = PoolKey({
                currency0: currency0,
                currency1: currency1,
                hooks: hook,
                poolManager: pm,
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                parameters: CLPoolParametersHelper.setTickSpacing(
                    bytes32(uint256(hook.getHooksRegistrationBitmap())), int24(int256(i + 1))
                )
            });
            ids[i] = keys[i].toId();
            hook.configureLaunch(
                keys[i],
                LaunchGuardHook.LaunchConfig({
                    startTime: uint40(vm.getBlockTimestamp()),
                    decaySeconds: 1 days,
                    initialFeeBips: i == 0 ? 500_000 : 120_000,
                    finalFeeBips: i == 0 ? 10_000 : 100_000,
                    maxBuyPerTx: 0,
                    launchTokenIsCurrency0: i == 1,
                    enabled: true
                })
            );
            hook.configureFeeSplit(keys[i], _split(i));
            hook.configureTax(keys[i], _tax(i));
            pm.initialize(keys[i], 79228162514264337593543950336); // 1:1
            router.modifyPosition(
                keys[i],
                ICLPoolManager.ModifyLiquidityParams({
                    tickLower: -600, tickUpper: 600, liquidityDelta: 10_000 ether, salt: 0
                }),
                ""
            );
        }

        handler = new CLGuardHandler(hook, IVault(address(vault)), pm, router, keys[0], keys[1]);
        _enlist();
    }
}

/// forge-config: default.invariant.runs = 32
/// forge-config: default.invariant.depth = 48
/// forge-config: legacy.invariant.runs = 32
/// forge-config: legacy.invariant.depth = 48
contract LaunchGuardInvariantBinTest is GuardInvariants {
    using BinPoolParametersHelper for bytes32;

    uint24 constant ACTIVE_ID = 2 ** 23;

    function setUp() public {
        vault = new Vault();
        BinPoolManager pm = new BinPoolManager(IVault(address(vault)));
        vault.registerApp(address(pm));
        BinLaunchGuardHook hook = new BinLaunchGuardHook(pm, ILaunchTokenOrigin(address(0)), PROTOCOL, 0);
        guard = hook;
        BinSwapHelper swapHelper = new BinSwapHelper(pm, vault);
        BinLiquidityHelper liquidityHelper = new BinLiquidityHelper(pm, vault);
        _tokens();
        token0.approve(address(liquidityHelper), type(uint256).max);
        token1.approve(address(liquidityHelper), type(uint256).max);

        // Seeded as the kit seeds while a tax is live: either side of the active bin, never in it.
        bytes32[] memory cfgs = new bytes32[](4);
        cfgs[0] = LiquidityConfigurations.encodeParams(0, 0.5e18, ACTIVE_ID - 2);
        cfgs[1] = LiquidityConfigurations.encodeParams(0, 0.5e18, ACTIVE_ID - 1);
        cfgs[2] = LiquidityConfigurations.encodeParams(0.5e18, 0, ACTIVE_ID + 1);
        cfgs[3] = LiquidityConfigurations.encodeParams(0.5e18, 0, ACTIVE_ID + 2);

        PoolKey[2] memory keys;
        for (uint256 i; i < 2; ++i) {
            keys[i] = PoolKey({
                currency0: currency0,
                currency1: currency1,
                hooks: hook,
                poolManager: pm,
                fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
                parameters: bytes32(uint256(hook.getHooksRegistrationBitmap())).setBinStep(uint16(10 + i))
            });
            ids[i] = keys[i].toId();
            hook.configureLaunch(
                keys[i],
                BinLaunchGuardHook.LaunchConfig({
                    startTime: uint40(vm.getBlockTimestamp()),
                    decaySeconds: 1 days,
                    initialFeeBips: i == 0 ? 100_000 : 60_000,
                    finalFeeBips: i == 0 ? 3_000 : 20_000,
                    maxBuyPerTx: 0,
                    launchTokenIsCurrency0: i == 1,
                    enabled: true
                })
            );
            hook.configureFeeSplit(keys[i], _split(i));
            hook.configureTax(keys[i], _tax(i));
            pm.initialize(keys[i], ACTIVE_ID);
            liquidityHelper.mint(
                keys[i],
                IBinPoolManager.MintParams({
                    liquidityConfigs: cfgs, amountIn: PackedUint128Math.encode(1_000 ether, 1_000 ether), salt: 0
                }),
                ""
            );
        }

        handler = new BinGuardHandler(hook, IVault(address(vault)), pm, swapHelper, keys[0], keys[1]);
        _enlist();
    }
}
