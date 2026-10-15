// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.26;

import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "infinity-core/src/interfaces/IPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

import {DeepCoreManagedVault} from "../src/DeepCoreManagedVault.sol";
import {VaultFixture} from "./VaultFixture.sol";
import {MockOracle, FeeOnTransferToken, ReadingReceiver} from "./mocks/Mocks.sol";

contract DeepCoreManagedVaultTest is VaultFixture {
    /*//////////////////////////////////////////////////////////////
                               INITIALIZE
    //////////////////////////////////////////////////////////////*/

    function test_initialize_frozenValues() public view {
        assertEq(mv.curator(), CURATOR);
        assertEq(mv.performanceFeeBps(), PERF_BPS);
        assertEq(mv.protocolFeeRecipient(), SAFE);
        assertEq(address(mv.oracle()), address(oracle));
        assertEq(mv.tickSpacing(), SPACING);
        assertEq(mv.config().curatorFeeBps, CURATOR_BPS);
        assertEq(mv.name(), "DeepCore Managed Vault Share");
        assertEq(mv.symbol(), "dcVAULT");
    }

    function test_initialize_cannotBeCalledAgain() public {
        DeepCoreManagedVault.VaultParams memory p =
            DeepCoreManagedVault.VaultParams({key: key, oracleKey: key, config: _config()});
        vm.prank(address(factory));
        vm.expectRevert(DeepCoreManagedVault.AlreadyInitialized.selector);
        mv.initialize(p, STRANGER, STRANGER, 0);
        vm.prank(STRANGER);
        vm.expectRevert(DeepCoreManagedVault.NotFactory.selector);
        mv.initialize(p, STRANGER, STRANGER, 0);
    }

    function test_initialize_implementationIsLocked() public {
        DeepCoreManagedVault.VaultParams memory p =
            DeepCoreManagedVault.VaultParams({key: key, oracleKey: key, config: _config()});
        vm.prank(address(factory));
        vm.expectRevert(DeepCoreManagedVault.AlreadyInitialized.selector);
        impl.initialize(p, STRANGER, STRANGER, 0);
    }

    function _expectCreateRevert(PoolKey memory k, PoolKey memory ok, DeepCoreManagedVault.Config memory cfg, bytes memory err)
        internal
    {
        vm.prank(ALICE);
        vm.expectRevert(err);
        factory.createVault{value: CREATE_FEE}(DeepCoreManagedVault.VaultParams({key: k, oracleKey: ok, config: cfg}), "x");
    }

    function test_initialize_refusesWrongManager() public {
        PoolKey memory k = key;
        k.poolManager = IPoolManager(address(0xBEEF));
        _expectCreateRevert(k, key, _config(), abi.encodeWithSelector(DeepCoreManagedVault.WrongPoolManager.selector));
    }

    function test_initialize_refusesCurrencyMismatch() public {
        _expectCreateRevert(key, keyNative, _config(), abi.encodeWithSelector(DeepCoreManagedVault.CurrencyMismatch.selector));
    }

    function test_initialize_refusesHookThatCanTrapRemoval() public {
        uint16[4] memory bits = [uint16(1 << 4), uint16(1 << 5), uint16(1 << 12), uint16(1 << 13)];
        for (uint256 i; i < bits.length; ++i) {
            PoolKey memory k = key;
            k.parameters = bytes32(uint256(k.parameters) | bits[i]);
            _expectCreateRevert(
                k, key, _config(), abi.encodeWithSelector(DeepCoreManagedVault.HookCanTrapLiquidity.selector, bits[i])
            );
        }
    }

    function test_initialize_refusesUninitializedPool() public {
        PoolKey memory k = key;
        k.fee = 500;
        PoolKey memory ok = k;
        _expectCreateRevert(k, ok, _config(), abi.encodeWithSelector(DeepCoreManagedVault.PoolNotInitialized.selector));
    }

    function test_initialize_refusesPoolWithoutOracle() public {
        PoolKey memory plain = _key(c0, c1, address(0));
        cl.initialize(plain, SQRT_1_1);
        _expectCreateRevert(plain, plain, _config(), abi.encodeWithSelector(DeepCoreManagedVault.OracleKindMismatch.selector));
        oracle.setKind(keccak256("something else"));
        _expectCreateRevert(key, key, _config(), abi.encodeWithSelector(DeepCoreManagedVault.OracleKindMismatch.selector));
    }

    function test_initialize_refusesBadConfig() public {
        DeepCoreManagedVault.Config memory c;
        c = _config();
        c.baseHalfWidth = 5;
        _expectCreateRevert(key, key, c, abi.encodeWithSelector(DeepCoreManagedVault.InvalidConfig.selector, 1));
        c = _config();
        c.baseHalfWidth = 1005;
        _expectCreateRevert(key, key, c, abi.encodeWithSelector(DeepCoreManagedVault.InvalidConfig.selector, 1));
        c = _config();
        c.limitWidth = 0;
        _expectCreateRevert(key, key, c, abi.encodeWithSelector(DeepCoreManagedVault.InvalidConfig.selector, 2));
        c = _config();
        c.maxDeviation = 501; // more than half the base half-width
        _expectCreateRevert(key, key, c, abi.encodeWithSelector(DeepCoreManagedVault.InvalidConfig.selector, 3));
        c = _config();
        c.maxDeviation = 0;
        _expectCreateRevert(key, key, c, abi.encodeWithSelector(DeepCoreManagedVault.InvalidConfig.selector, 3));
        c = _config();
        c.rebalanceThreshold = 1001;
        _expectCreateRevert(key, key, c, abi.encodeWithSelector(DeepCoreManagedVault.InvalidConfig.selector, 4));
        c = _config();
        c.twapWindow = 599;
        _expectCreateRevert(key, key, c, abi.encodeWithSelector(DeepCoreManagedVault.InvalidConfig.selector, 5));
        oracle.setMinWindow(3600);
        c = _config(); // 1800 < the oracle's own minimum
        _expectCreateRevert(key, key, c, abi.encodeWithSelector(DeepCoreManagedVault.InvalidConfig.selector, 5));
        oracle.setMinWindow(600);
        c = _config();
        c.cooldown = 599;
        _expectCreateRevert(key, key, c, abi.encodeWithSelector(DeepCoreManagedVault.InvalidConfig.selector, 6));
        c = _config();
        c.curatorFeeBps = 2001;
        _expectCreateRevert(key, key, c, abi.encodeWithSelector(DeepCoreManagedVault.FeeAboveCap.selector, uint16(2001)));
    }

    /*//////////////////////////////////////////////////////////////
                             FIRST DEPOSIT
    //////////////////////////////////////////////////////////////*/

    function test_depositInitial_placesBaseAroundTwapAndMintsDeadShares() public {
        oracle.setTick(37); // TWAP 37, spot 0: within the 100-tick deviation
        uint256 b0 = t0.balanceOf(ALICE);
        uint256 shares = _seed(mv, ALICE, 1e18);
        (int24 lo, int24 hi) = mv.base();
        assertEq(lo, 30 - 1000);
        assertEq(hi, 30 + 1000);
        assertEq(mv.balanceOf(mv.DEAD()), 1000);
        assertEq(mv.totalSupply(), shares + 1000);
        (uint128 lb,) = mv.positionLiquidity();
        assertEq(uint256(lb), shares + 1000);
        assertLe(b0 - t0.balanceOf(ALICE), 1e18);
        assertEq(mv.lastRebalanceAt(), block.timestamp);
    }

    function test_depositInitial_refusedWhenSpotFarFromTwap() public {
        oracle.setTick(101);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreManagedVault.DeviationTooHigh.selector, int24(0), int24(101)));
        mv.depositInitial(1e18, 1e18, 0, ALICE, block.timestamp);
    }

    function test_depositInitial_refusedWhenOracleUnreadable() public {
        MockOracle.Mode[5] memory modes = [
            MockOracle.Mode.Revert,
            MockOracle.Mode.LongAnswer,
            MockOracle.Mode.BadTick,
            MockOracle.Mode.BurnGas,
            MockOracle.Mode.ShortAnswer
        ];
        for (uint256 i; i < modes.length; ++i) {
            oracle.setMode(modes[i]);
            vm.prank(ALICE);
            try mv.depositInitial(1e18, 1e18, 0, ALICE, block.timestamp) {
                revert("accepted a broken oracle");
            } catch (bytes memory err) {
                assertEq(bytes4(err), DeepCoreManagedVault.OracleUnreadable.selector, "mode");
            }
        }
    }

    function test_depositInitial_refusesDustAndSecondCall() public {
        vm.prank(ALICE);
        vm.expectPartialRevert(DeepCoreManagedVault.BelowMinimum.selector);
        mv.depositInitial(100, 100, 0, ALICE, block.timestamp);
        _seed(mv, ALICE, 1e18);
        vm.prank(BOB);
        vm.expectRevert(DeepCoreManagedVault.VaultNotEmpty.selector);
        mv.depositInitial(1e18, 1e18, 0, BOB, block.timestamp);
    }

    function test_depositInitial_minSharesAndDeadline() public {
        vm.prank(ALICE);
        vm.expectPartialRevert(DeepCoreManagedVault.BelowMinimum.selector);
        mv.depositInitial(1e18, 1e18, type(uint256).max, ALICE, block.timestamp);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreManagedVault.Expired.selector, block.timestamp - 1));
        mv.depositInitial(1e18, 1e18, 0, ALICE, block.timestamp - 1);
    }

    /*//////////////////////////////////////////////////////////////
                          DEPOSIT / WITHDRAW
    //////////////////////////////////////////////////////////////*/

    function test_deposit_refusedBeforeFirstDeposit() public {
        vm.prank(ALICE);
        vm.expectRevert(DeepCoreManagedVault.VaultEmpty.selector);
        mv.deposit(1e6, 1e18, 1e18, ALICE, block.timestamp);
    }

    function test_deposit_proRata() public {
        uint256 s = _seed(mv, ALICE, 1e18);
        (uint256 t0b, uint256 t1b) = mv.totalAmounts();
        uint256 supply = mv.totalSupply();
        (uint256 a0, uint256 a1) = _deposit(mv, BOB, s / 2);
        assertApproxEqAbs(a0, t0b * (s / 2) / supply, 3);
        assertApproxEqAbs(a1, t1b * (s / 2) / supply, 3);
        assertEq(mv.balanceOf(BOB), s / 2);
    }

    function test_deposit_respectsMaxAndValue() public {
        uint256 s = _seed(mv, ALICE, 1e18);
        vm.prank(BOB);
        vm.expectPartialRevert(DeepCoreManagedVault.AboveMaximum.selector);
        mv.deposit(s, 1, type(uint256).max, BOB, block.timestamp);
        vm.prank(BOB);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreManagedVault.WrongValue.selector, 0, 1));
        mv.deposit{value: 1}(s, type(uint256).max, type(uint256).max, BOB, block.timestamp);
        vm.prank(BOB);
        vm.expectRevert(DeepCoreManagedVault.ZeroShares.selector);
        mv.deposit(0, type(uint256).max, type(uint256).max, BOB, block.timestamp);
    }

    function test_withdraw_proRataAndMins() public {
        uint256 s = _seed(mv, ALICE, 1e18);
        (uint256 t0a, uint256 t1a) = mv.totalAmounts();
        (uint256 p0, uint256 p1) = (t0a * (s / 4) / mv.totalSupply(), t1a * (s / 4) / mv.totalSupply());
        vm.prank(ALICE);
        vm.expectPartialRevert(DeepCoreManagedVault.BelowMinimum.selector);
        mv.withdraw(s / 4, p0 + 10, 0, ALICE, block.timestamp);
        (uint256 a0, uint256 a1) = _withdraw(mv, ALICE, s / 4);
        assertApproxEqAbs(a0, p0, 2);
        assertApproxEqAbs(a1, p1, 2);
        assertEq(mv.balanceOf(ALICE), s - s / 4);
    }

    function test_withdraw_fullExitLeavesOnlyDeadShares() public {
        uint256 s = _seed(mv, ALICE, 1e18);
        _withdraw(mv, ALICE, s);
        assertEq(mv.totalSupply(), 1000);
        (uint256 t0b, uint256 t1b) = mv.totalAmounts();
        assertLt(t0b, 1e18 / 1e5);
        assertLt(t1b, 1e18 / 1e5);
    }

    function test_withdraw_worksWhenOracleIsBroken() public {
        uint256 s = _seed(mv, ALICE, 1e18);
        MockOracle.Mode[5] memory modes = [
            MockOracle.Mode.Revert,
            MockOracle.Mode.LongAnswer,
            MockOracle.Mode.BadTick,
            MockOracle.Mode.BurnGas,
            MockOracle.Mode.ShortAnswer
        ];
        for (uint256 i; i < modes.length; ++i) {
            oracle.setMode(modes[i]);
            (uint256 a0, uint256 a1) = _withdraw(mv, ALICE, s / 10);
            assertGt(a0 + a1, 0);
        }
    }

    function test_withdraw_worksWhilePoolManagerPaused() public {
        uint256 s = _seed(mv, ALICE, 1e18);
        cl.pause();
        (uint256 a0, uint256 a1) = _withdraw(mv, ALICE, s);
        assertGt(a0, 0);
        assertGt(a1, 0);
        // adds are refused while paused, so deposits are too
        vm.prank(BOB);
        vm.expectRevert();
        mv.deposit(1e6, type(uint256).max, type(uint256).max, BOB, block.timestamp);
    }

    function test_withdraw_worksInsideCooldownAndAfterRebalance() public {
        uint256 s = _seed(mv, ALICE, 1e18);
        _withdraw(mv, ALICE, s / 3); // the cooldown has just started
        vm.warp(vm.getBlockTimestamp() + 3600);
        _swapToTick(key, 700);
        oracle.setTick(690);
        mv.rebalance();
        _withdraw(mv, ALICE, mv.balanceOf(ALICE));
        assertEq(mv.balanceOf(ALICE), 0);
    }

    function test_withdraw_refusesBadInputs() public {
        _seed(mv, ALICE, 1e18);
        vm.startPrank(ALICE);
        vm.expectRevert(DeepCoreManagedVault.ZeroShares.selector);
        mv.withdraw(0, 0, 0, ALICE, block.timestamp);
        vm.expectRevert(DeepCoreManagedVault.ZeroAddress.selector);
        mv.withdraw(1, 0, 0, address(0), block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreManagedVault.Expired.selector, block.timestamp - 1));
        mv.withdraw(1, 0, 0, ALICE, block.timestamp - 1);
        vm.stopPrank();
        vm.prank(BOB);
        vm.expectRevert(); // ERC20InsufficientBalance
        mv.withdraw(1, 0, 0, BOB, block.timestamp);
    }

    function test_sharesCannotBeSentToTheVault() public {
        _seed(mv, ALICE, 1e18);
        vm.prank(ALICE);
        vm.expectRevert(DeepCoreManagedVault.SharesToVault.selector);
        mv.transfer(address(mv), 1);
    }

    function testFuzz_depositThenWithdrawNeverProfits(uint96 seed, uint96 shares, int16 moveTo) public {
        _seed(mv, ALICE, uint256(seed) % 1e24 + 1e16);
        int24 t = int24(moveTo) % 900;
        _swapToTick(key, t);
        uint256 s = bound(uint256(shares), 1, mv.totalSupply() * 3);
        uint256 b0 = t0.balanceOf(BOB);
        uint256 b1 = t1.balanceOf(BOB);
        _deposit(mv, BOB, s);
        _withdraw(mv, BOB, s);
        assertLe(t0.balanceOf(BOB), b0, "token0 profit");
        assertLe(t1.balanceOf(BOB), b1, "token1 profit");
    }

    /// Rounding is always against the actor: a deposit adds ceil(L * s / S) liquidity and pulls ceil(idle * s / S);
    /// a withdrawal takes floor(idle * s / S).
    function test_rounding_depositLiquidityRoundsUp() public {
        _seed(mv, ALICE, 1e20);
        _churn(key, 5, 1e20);
        mv.harvest(); // compounding makes liquidity per share > 1
        (uint128 l0,) = mv.positionLiquidity();
        uint256 supply = mv.totalSupply();
        assertGt(uint256(l0), supply);
        uint256 shares = 3;
        uint256 expected = (uint256(l0) * shares + supply - 1) / supply;
        assertGt(expected, uint256(l0) * shares / supply, "the case must round");
        _deposit(mv, BOB, shares);
        (uint128 l1,) = mv.positionLiquidity();
        assertEq(uint256(l1 - l0), expected);
    }

    function test_rounding_idlePartsRoundAgainstTheActor() public {
        _seed(mv, ALICE, 1e20);
        t0.transfer(address(mv), 1_000_007);
        t1.transfer(address(mv), 1_000_007);
        (uint256 i0, uint256 i1) = _idleOf(mv);
        uint256 supply = mv.totalSupply();
        uint256 shares = supply / 1e9; // idle * shares / supply = 0.001...: ceil 1, floor 0
        _deposit(mv, BOB, shares);
        (uint256 j0, uint256 j1) = _idleOf(mv);
        assertEq(j0 - i0, 1, "deposit pulls the idle part rounded up");
        assertEq(j1 - i1, 1);
        _withdraw(mv, BOB, shares);
        (uint256 k0, uint256 k1) = _idleOf(mv);
        assertEq(k0, j0, "withdraw takes the idle part rounded down");
        assertEq(k1, j1);
    }

    function test_donationBeforeFirstDepositGoesToFirstDepositor() public {
        t0.transfer(address(mv), 5e17);
        uint256 s = _seed(mv, ALICE, 1e18);
        uint256 before = t0.balanceOf(ALICE);
        _withdraw(mv, ALICE, s);
        assertGt(t0.balanceOf(ALICE) - before, 5e17 + 4e17);
    }

    function test_donationCannotRoundADepositToNothing() public {
        uint256 s = _seed(mv, ALICE, 1e18);
        _withdraw(mv, ALICE, s - 1); // leave 1 share + the dead shares
        t0.transfer(address(mv), 1e24); // inflate the share price
        t1.transfer(address(mv), 1e24);
        (uint256 a0, uint256 a1) = _deposit(mv, BOB, 1);
        // Bob paid for exactly one of 1,001 shares, rounded up
        assertGt(a0, 0);
        assertGt(a1, 0);
        (uint256 o0, uint256 o1) = _withdraw(mv, BOB, 1);
        assertLe(o0, a0);
        assertLe(o1, a1);
        assertApproxEqRel(o0, a0, 1e15);
    }

    function test_feeOnTransferTokenRefused() public {
        FeeOnTransferToken fot = new FeeOnTransferToken();
        MockERC20 other = new MockERC20("O", "O", 18);
        (Currency a, Currency b) = address(fot) < address(other)
            ? (Currency.wrap(address(fot)), Currency.wrap(address(other)))
            : (Currency.wrap(address(other)), Currency.wrap(address(fot)));
        PoolKey memory k = _key(a, b, address(oracle));
        cl.initialize(k, SQRT_1_1);
        DeepCoreManagedVault v = _create(CURATOR, k, k, _config(), "fot");
        fot.mint(ALICE, 1e24);
        other.mint(ALICE, 1e24);
        vm.startPrank(ALICE);
        fot.approve(address(v), type(uint256).max);
        other.approve(address(v), type(uint256).max);
        vm.expectPartialRevert(DeepCoreManagedVault.FeeOnTransferUnsupported.selector);
        v.depositInitial(1e18, 1e18, 0, ALICE, block.timestamp);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                 NATIVE
    //////////////////////////////////////////////////////////////*/

    function test_native_depositRefundsAndWithdrawPays() public {
        DeepCoreManagedVault v = _create(CURATOR, keyNative, keyNative, _config(), "nat");
        _approveAll(address(v));
        uint256 eth0 = ALICE.balance;
        vm.prank(ALICE);
        (uint256 s, uint256 a0,) = v.depositInitial{value: 2e18}(1e18, 1e18, 0, ALICE, block.timestamp);
        assertEq(eth0 - ALICE.balance, a0, "surplus refunded");
        vm.prank(BOB);
        (uint256 b0,) = v.deposit{value: 5e18}(s / 2, 5e18, type(uint256).max, BOB, block.timestamp);
        assertGt(b0, 0);
        uint256 bobEth = BOB.balance;
        vm.prank(BOB);
        (uint256 o0,) = v.withdraw(s / 2, 0, 0, BOB, block.timestamp);
        assertEq(BOB.balance - bobEth, o0);
        assertLe(o0, b0);
        vm.prank(BOB);
        vm.expectPartialRevert(DeepCoreManagedVault.WrongValue.selector);
        v.deposit{value: 0}(s / 2, type(uint256).max, type(uint256).max, BOB, block.timestamp);
    }

    function test_native_refusedFromAnyoneButTheCoreVault() public {
        vm.prank(ALICE);
        (bool ok,) = address(mv).call{value: 1}("");
        assertFalse(ok);
    }

    function test_readOnlyReentrancy_totalAmountsRevertsMidWithdraw() public {
        DeepCoreManagedVault v = _create(CURATOR, keyNative, keyNative, _config(), "ro");
        _approveAll(address(v));
        vm.prank(ALICE);
        (uint256 s,,) = v.depositInitial{value: 2e18}(1e18, 1e18, 0, ALICE, block.timestamp);
        ReadingReceiver r = new ReadingReceiver(address(v));
        vm.prank(ALICE);
        v.withdraw(s / 2, 0, 0, address(r), block.timestamp);
        assertTrue(r.readReverted(), "read during execution must revert");
    }

    /*//////////////////////////////////////////////////////////////
                               REBALANCE
    //////////////////////////////////////////////////////////////*/

    function test_rebalance_cooldownDriftDeviation() public {
        _seed(mv, ALICE, 1e18);
        vm.expectPartialRevert(DeepCoreManagedVault.CooldownActive.selector);
        mv.rebalance();
        vm.warp(vm.getBlockTimestamp() + 3600);
        vm.expectRevert(DeepCoreManagedVault.NoDrift.selector);
        mv.rebalance();
        oracle.setTick(400); // drift under the 500 threshold
        _swapToTick(key, 400);
        vm.expectRevert(DeepCoreManagedVault.NoDrift.selector);
        mv.rebalance();
        oracle.setTick(800);
        vm.expectRevert(abi.encodeWithSelector(DeepCoreManagedVault.DeviationTooHigh.selector, _tick(key), int24(800)));
        mv.rebalance();
        _swapToTick(key, 750);
        vm.prank(STRANGER); // permissionless
        mv.rebalance();
        (int24 lo, int24 hi) = mv.base();
        assertEq(lo, -200);
        assertEq(hi, 1800);
        vm.expectPartialRevert(DeepCoreManagedVault.CooldownActive.selector);
        mv.rebalance();
    }

    /// With a zero threshold the only trigger is a CHANGED range: an identical one is refused.
    function test_rebalance_zeroThresholdStillNeedsAChangedRange() public {
        DeepCoreManagedVault.Config memory c = _config();
        c.rebalanceThreshold = 0;
        DeepCoreManagedVault v = _create(CURATOR, key, key, c, "zero");
        _approveAll(address(v));
        _seed(v, ALICE, 1e18);
        vm.warp(vm.getBlockTimestamp() + 3600);
        oracle.setTick(7); // same aligned centre (0)
        vm.expectRevert(DeepCoreManagedVault.NoDrift.selector);
        v.rebalance();
        oracle.setTick(12); // the aligned centre moves to 10
        v.rebalance();
        (int24 lo,) = v.base();
        assertEq(lo, 10 - 1000);
    }

    function test_rebalance_placesRemainderAsLimitOnTheRightSide() public {
        _seed(mv, ALICE, 1e18);
        vm.warp(vm.getBlockTimestamp() + 3600);
        _swapToTick(key, 700); // price up: the vault sold token0, holds more token1
        oracle.setTick(700);
        mv.rebalance();
        (int24 llo, int24 lhi) = mv.limit();
        (, uint128 ll) = mv.positionLiquidity();
        assertGt(ll, 0);
        // excess token1 rests BELOW spot
        assertEq(lhi, 700);
        assertEq(llo, -300);
        (uint256 i0, uint256 i1) = _idleOf(mv);
        assertLt(i0, 1e12);
        assertLt(i1, 1e12);
    }

    function test_rebalance_refusedWhenOracleUnreadableOrEmpty() public {
        vm.expectRevert(DeepCoreManagedVault.NothingToManage.selector);
        mv.rebalance();
        _seed(mv, ALICE, 1e18);
        vm.warp(vm.getBlockTimestamp() + 3600);
        oracle.setMode(MockOracle.Mode.Revert);
        vm.expectRevert(DeepCoreManagedVault.OracleUnreadable.selector);
        mv.rebalance();
    }

    /// @dev A flash move of spot cannot steer a rebalance: the guard compares spot with the TWAP.
    function test_rebalance_sandwichRefused() public {
        _seed(mv, ALICE, 1e18);
        vm.warp(vm.getBlockTimestamp() + 3600);
        oracle.setTick(600);
        _swapToTick(key, 600);
        // attacker pushes spot 300 ticks away just before the keeper's rebalance
        _swapToTick(key, 900);
        vm.expectPartialRevert(DeepCoreManagedVault.DeviationTooHigh.selector);
        mv.rebalance();
    }

    /// @dev A sandwich inside the bound costs the vault at most a bounded slice.
    function test_rebalance_sandwichInsideBoundIsBounded() public {
        _seed(mv, ALICE, 1e18);
        vm.warp(vm.getBlockTimestamp() + 3600);
        oracle.setTick(600);
        _swapToTick(key, 600);
        (uint256 v0, uint256 v1) = mv.totalAmounts();
        uint256 valueBefore = v0 * 10_618 / 10_000 + v1; // price at tick 600 ~ 1.0618
        _swapToTick(key, 699); // inside maxDeviation 100
        mv.rebalance();
        _swapToTick(key, 600);
        (uint256 w0, uint256 w1) = mv.totalAmounts();
        uint256 valueAfter = w0 * 10_618 / 10_000 + w1;
        // loss bounded by about the IL of a 1% move: well under 1% of value
        assertGt(valueAfter, valueBefore * 99 / 100);
    }

    /*//////////////////////////////////////////////////////////////
                                HARVEST
    //////////////////////////////////////////////////////////////*/

    function test_harvest_booksPerformanceAndCuratorFees() public {
        _seed(mv, ALICE, 1e20);
        _churn(key, 5, 1e20);
        uint256 supplyBefore = mv.totalSupply();
        mv.harvest();
        uint256 p0 = mv.protocolOwed0();
        uint256 p1 = mv.protocolOwed1();
        uint256 c0 = mv.curatorOwed0();
        uint256 c1 = mv.curatorOwed1();
        assertGt(p0, 0);
        assertGt(p1, 0);
        // curator 5%, protocol 10%: the curator credit is half the protocol credit (+-1 rounding)
        assertApproxEqAbs(c0 * 2, p0, 2);
        assertApproxEqAbs(c1 * 2, p1, 2);
        assertEq(mv.totalSupply(), supplyBefore, "no shares minted for fees");
    }

    function test_harvest_compoundsWhenGuardPassesAndStillBooksWhenNot() public {
        _seed(mv, ALICE, 1e20);
        _churn(key, 5, 1e20);
        (uint128 lb0,) = mv.positionLiquidity();
        mv.harvest();
        (uint128 lb1,) = mv.positionLiquidity();
        assertGt(lb1, lb0, "compounded");
        _churn(key, 5, 1e20);
        oracle.setMode(MockOracle.Mode.Revert);
        uint256 pBefore = mv.protocolOwed0();
        mv.harvest(); // never reverts for an oracle reason
        assertGt(mv.protocolOwed0(), pBefore);
        (uint128 lb2,) = mv.positionLiquidity();
        assertEq(lb2, lb1, "not compounded without a TWAP");
    }

    function test_harvest_refusedWithNothing() public {
        vm.expectRevert(DeepCoreManagedVault.NothingToHarvest.selector);
        mv.harvest();
    }

    function test_feesAccrueToHoldersNotToLateDepositors() public {
        uint256 s = _seed(mv, ALICE, 1e20);
        _churn(key, 5, 1e20);
        // Bob buys in after fees accrued but before any harvest: he pays for them
        (uint256 d0, uint256 d1) = _deposit(mv, BOB, s);
        (uint256 o0, uint256 o1) = _withdraw(mv, BOB, s);
        assertLe(o0, d0);
        assertLe(o1, d1);
    }

    /*//////////////////////////////////////////////////////////////
                           FEES OUT, CURATOR
    //////////////////////////////////////////////////////////////*/

    function test_flushProtocolFees_paysOnlyTheSafe() public {
        vm.expectRevert(DeepCoreManagedVault.NothingToFlush.selector);
        mv.flushProtocolFees();
        _seed(mv, ALICE, 1e20);
        _churn(key, 3, 1e20);
        mv.harvest();
        uint256 p0 = mv.protocolOwed0();
        uint256 s0 = t0.balanceOf(SAFE);
        vm.prank(STRANGER);
        mv.flushProtocolFees();
        assertEq(t0.balanceOf(SAFE) - s0, p0);
        assertEq(mv.protocolOwed0(), 0);
        vm.expectRevert(DeepCoreManagedVault.NothingToFlush.selector);
        mv.flushProtocolFees();
    }

    function test_curator_claimAndTwoStepTransfer() public {
        _seed(mv, ALICE, 1e20);
        _churn(key, 3, 1e20);
        mv.harvest();
        vm.prank(STRANGER);
        vm.expectRevert(DeepCoreManagedVault.NotCurator.selector);
        mv.claimCuratorFees(STRANGER);
        uint256 c0 = mv.curatorOwed0();
        vm.prank(CURATOR);
        mv.claimCuratorFees(BOB);
        assertEq(mv.curatorOwed0(), 0);
        assertGe(t0.balanceOf(BOB), 1e30 + c0);
        vm.prank(CURATOR);
        vm.expectRevert(DeepCoreManagedVault.NothingToClaim.selector);
        mv.claimCuratorFees(BOB);

        vm.prank(STRANGER);
        vm.expectRevert(DeepCoreManagedVault.NotCurator.selector);
        mv.transferCurator(STRANGER);
        vm.prank(CURATOR);
        mv.transferCurator(BOB);
        vm.prank(STRANGER);
        vm.expectRevert(DeepCoreManagedVault.NotPendingCurator.selector);
        mv.acceptCurator();
        vm.prank(BOB);
        mv.acceptCurator();
        assertEq(mv.curator(), BOB);
        assertEq(mv.pendingCurator(), address(0));
    }

    function test_curatorCannotTouchPrincipal() public {
        uint256 s = _seed(mv, ALICE, 1e18);
        vm.prank(CURATOR);
        vm.expectRevert(); // no shares
        mv.withdraw(1, 0, 0, CURATOR, block.timestamp);
        vm.prank(CURATOR);
        vm.expectRevert(DeepCoreManagedVault.NothingToClaim.selector);
        mv.claimCuratorFees(CURATOR);
        assertEq(mv.balanceOf(ALICE), s);
    }

    /*//////////////////////////////////////////////////////////////
                                 SWEEP
    //////////////////////////////////////////////////////////////*/

    function test_sweep_foreignTokenGoesToSafe_poolTokenStaysWithHolders() public {
        _seed(mv, ALICE, 1e18);
        MockERC20 stray = new MockERC20("S", "S", 18);
        stray.mint(address(mv), 7e18);
        vm.prank(STRANGER);
        mv.sweep(Currency.wrap(address(stray)));
        assertEq(stray.balanceOf(SAFE), 7e18);
        vm.expectRevert(DeepCoreManagedVault.NothingToSweep.selector);
        mv.sweep(Currency.wrap(address(stray)));
        vm.expectRevert(DeepCoreManagedVault.NothingToSweep.selector);
        mv.sweep(c0); // a plain transfer of a pool token needs no sweep: it is already idle
    }

    function test_sweep_redeemsVaultClaimsIntoIdle() public {
        _seed(mv, ALICE, 1e18);
        _giveClaims(address(mv), c0, 3e17);
        (uint256 i0,) = _idleOf(mv);
        mv.sweep(c0);
        (uint256 j0,) = _idleOf(mv);
        assertEq(j0 - i0, 3e17);
    }

    function test_sweep_forcedNativeGoesToSafeWhenPoolHasNone() public {
        vm.deal(address(mv), 1 ether);
        uint256 s = SAFE.balance;
        mv.sweep(Currency.wrap(address(0)));
        assertEq(SAFE.balance - s, 1 ether);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _idleOf(DeepCoreManagedVault v) internal view returns (uint256 i0, uint256 i1) {
        i0 = t0.balanceOf(address(v)) - v.protocolOwed0() - v.curatorOwed0();
        i1 = t1.balanceOf(address(v)) - v.protocolOwed1() - v.curatorOwed1();
    }

    function _giveClaims(address to, Currency c, uint256 amount) internal {
        ClaimMinter m = new ClaimMinter(vault);
        MockERC20(Currency.unwrap(c)).transfer(address(m), amount);
        m.mintTo(to, c, amount);
    }
}

import {IVault} from "infinity-core/src/interfaces/IVault.sol";
import {Vault} from "infinity-core/src/Vault.sol";

/// @dev Pays `amount` into the core Vault and mints the claims to `to`.
contract ClaimMinter {
    Vault internal immutable v;
    address internal to_;
    Currency internal c_;
    uint256 internal amount_;

    constructor(Vault vault_) {
        v = vault_;
    }

    function mintTo(address to, Currency c, uint256 amount) external {
        to_ = to;
        c_ = c;
        amount_ = amount;
        v.lock("");
    }

    function lockAcquired(bytes calldata) external returns (bytes memory) {
        v.sync(c_);
        MockERC20(Currency.unwrap(c_)).transfer(address(v), amount_);
        v.settle();
        v.mint(to_, c_, amount_);
        return "";
    }
}
