// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCore Protocol
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

import {LaunchGuardHook} from "deepcore-hooks/src/launch/LaunchGuardHook.sol";
import {BinLaunchGuardHook} from "deepcore-hooks/src/launch/BinLaunchGuardHook.sol";
import {
    IDeepCoreLaunchRegistry,
    LaunchRecord,
    LaunchOrigin,
    LaunchpadMetadata,
    LaunchpadRecord,
    LaunchpadOrigin
} from "deepcore-registry/src/IDeepCoreLaunchRegistry.sol";

import {Lock} from "../../src/interfaces/IDeepCoreLPLocker.sol";
import {BinLock, IDeepCoreBinLPLocker} from "../../src/interfaces/IDeepCoreBinLPLocker.sol";
import {LaunchTaxModule} from "deepcore-hooks/src/launch/LaunchTaxModule.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {TickMath} from "infinity-core/src/pool-cl/libraries/TickMath.sol";
import {CLPoolManagerRouter} from "infinity-core/test/pool-cl/helpers/CLPoolManagerRouter.sol";
import {
    ILaunchpadKitV2,
    LegKind,
    BinShape,
    LegParams,
    ScheduleParams,
    LaunchParamsV2,
    LaunchResultV2,
    LegRecord,
    LaunchRecordV2
} from "../../src/interfaces/ILaunchpadKitV2.sol";
import {Preset} from "../../src/libraries/LaunchPresets.sol";

import {KitV2Fixture} from "./KitV2Fixture.sol";

/// @notice The launch paths: CL, CL + Bin, native quote, stock-token quote, and what each leaves behind.
contract LaunchpadKitV2Test is KitV2Fixture {
    using PoolIdLibrary for PoolKey;
    using CLPoolParametersHelper for bytes32;

    function setUp() public {
        _deployAll();
    }

    /*//////////////////////////////////////////////////////////////
                              1-LEG CL
    //////////////////////////////////////////////////////////////*/

    function test_CL_oneLegBornAtZeroLockedAndRegistered() public {
        bytes32 salt = keccak256("cl-1");
        LaunchParamsV2 memory p = _oneCL(salt, address(quote));
        LaunchResultV2 memory r = _launch(p);
        bytes32 id = r.poolIds[0];

        // Token: created at the predicted address, supply distributed, nothing left on the kit.
        assertEq(r.token, _token(salt), "predicted address");
        assertEq(IERC20(r.token).totalSupply(), TOTAL_SUPPLY);
        assertEq(IERC20(r.token).balanceOf(address(kit)), 0, "kit holds no launch token");
        assertEq(factory.deployerOf(r.token), address(kit));
        assertGe(IERC20(r.token).balanceOf(ALLOCATION), TOTAL_SUPPLY - SEED_SUPPLY, "allocation + dust");
        assertLt(IERC20(r.token).balanceOf(ALLOCATION), TOTAL_SUPPLY - SEED_SUPPLY + 1e6, "dust is dust");

        // THE PROPERTY: born at a ZERO core protocol fee, while V2 would have charged 999 per direction.
        assertEq(_clProtocolFee(id), 0, "launch pool protocol fee");
        assertTrue(kit.isLockedLaunch(id));
        assertTrue(v3.isLockedLaunchPool(PoolId.wrap(id)));

        // Locked, with the declared split, owned by the locker.
        uint256 tokenId = r.lockIds[0];
        assertTrue(clLocker.isLocked(tokenId));
        Lock memory lk = clLocker.getLock(tokenId);
        assertEq(PoolId.unwrap(lk.poolId), id);
        assertEq(lk.creator, CREATOR);
        assertEq(lk.creatorBps, 7_000);
        assertEq(lk.integrator, INTEGRATOR);
        assertEq(lk.integratorBps, 1_000);
        assertEq(lk.protocolBps, 2_000);
        assertEq(clPosm.ownerOf(tokenId), address(clLocker));

        // Kit records.
        LegRecord memory leg = kit.getLeg(id);
        assertEq(leg.launchToken, r.token);
        assertEq(uint8(leg.kind), uint8(LegKind.CL));
        assertEq(leg.lockId, tokenId);
        LaunchRecordV2 memory rec = kit.getLaunch(r.token);
        assertEq(rec.creator, CREATOR);
        assertEq(rec.operator, OPERATOR);
        assertEq(rec.legCount, 1);
        assertEq(rec.startTime, uint40(block.timestamp + 120));
        assertEq(kit.legsOf(r.token).length, 1);

        // Guard: the kit is the launch owner, the schedule is FairLaunch in seconds.
        LaunchGuardHook.Launch memory g = clHook.getLaunch(PoolId.wrap(id));
        assertEq(g.owner, address(kit));
        assertEq(g.decaySeconds, 300);
        assertEq(g.initialFeeBips, 100_000);
        assertEq(g.launchTokenIsCurrency0, uint160(r.token) < uint160(address(quote)));

        // Registry: attested by the kit itself, creator from the kit.
        LaunchRecord memory reg = launchRegistry.getLaunch(id);
        assertEq(uint8(reg.origin), uint8(LaunchOrigin.LaunchpadAttested));
        assertEq(reg.launchpad, address(kit));
        assertEq(reg.creator, CREATOR);
        assertEq(reg.steward, STEWARD);
        assertEq(reg.token, r.token);
        assertEq(kit.launchOriginOf(id), CREATOR);

        // Fees: the protocol launch fee is credited, not pushed.
        assertEq(kit.feesOwed(safe), INITIAL_LAUNCH_FEE);
        assertEq(address(kit).balance, kit.totalFeesOwed());
    }

    function test_CL_normalDynamicPoolStillPaysTheCoreFee() public {
        // Control for the test above: same manager, same controller, not a kit launch.
        MockLike a = new MockLike();
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(quote) < address(a) ? address(quote) : address(a)),
            currency1: Currency.wrap(address(quote) < address(a) ? address(a) : address(quote)),
            hooks: IHooks(address(clHook)),
            poolManager: clPM,
            fee: 0x800000,
            parameters: bytes32(uint256(0x0CC1)).setTickSpacing(TICK_SPACING)
        });
        LaunchGuardHook.LaunchConfig memory cfg = LaunchGuardHook.LaunchConfig({
            startTime: uint40(block.timestamp + 10),
            decaySeconds: 60,
            initialFeeBips: 10_000,
            finalFeeBips: 3_000,
            maxBuyPerTx: 0,
            launchTokenIsCurrency0: true,
            enabled: true
        });
        vm.startPrank(ATTACKER);
        clHook.configureLaunch(key, cfg);
        // The guard refuses a pool with no fee split, kit or no kit.
        vm.expectRevert();
        clPM.initialize(key, SQRT_1_1);
        clHook.configureFeeSplit(key, LaunchTaxModule.FeeSplit(ATTACKER, 8_000, 2_000, 0, address(0)));
        clPM.initialize(key, SQRT_1_1);
        vm.stopPrank();
        assertEq(_clProtocolFee(PoolId.unwrap(key.toId())), PACKED_999, "not a kit launch: V2 fee");
        assertFalse(kit.isLockedLaunch(PoolId.unwrap(key.toId())));
    }

    function test_CL_splitsAfterTrading() public {
        LaunchResultV2 memory r = _launch(_oneCL(keccak256("cl-split"), address(quote)));
        PoolKey memory key = _clKey(r.token, _clLeg(r.token, address(quote), 10_000));
        vm.warp(block.timestamp + 120);

        Currency q = Currency.wrap(address(quote));
        PoolId id = PoolId.wrap(r.poolIds[0]);
        uint256 accruedBefore = clPM.protocolFeesAccrued(q);
        uint256 fee = clHook.currentFee(id);
        assertGt(fee, 0, "the schedule charges a fee");
        _buyCL(key, r.token, 100 ether);
        _buyCL(key, r.token, 50 ether);
        assertEq(clPM.protocolFeesAccrued(q), accruedBefore, "no core protocol fee");

        // THE FEE IS THE GUARD'S, IN THE QUOTE: an exact-input buy pays it on what it sends.
        uint256 collected = clHook.pendingFee(id, q);
        assertEq(collected, uint256(100 ether) * fee / 1e6 + uint256(50 ether) * fee / 1e6, "fee on the quote sent");
        assertEq(clHook.pendingFee(id, Currency.wrap(r.token)), 0, "never in the launch token");
        assertEq(clHook.backing(Currency.wrap(r.token)), 0, "the guard holds no launch token");

        // The locked position earned nothing: the pool's own LP fee is zero.
        (uint256 a0, uint256 a1) = clLocker.collectFees(r.lockIds[0]);
        assertEq(a0 + a1, 0, "no LP fee accrued to the locked position");

        // Split by the lock's split, which the kit wrote to the guard once.
        clHook.settleFee(id, q);
        assertEq(clHook.pendingFee(id, q), 0, "the pot drains to zero");
        uint256 c = clHook.claimable(CREATOR, q);
        uint256 i = clHook.claimable(INTEGRATOR, q);
        uint256 pr = clHook.claimable(safe, q);
        assertEq(c + i + pr, collected, "split sums exactly");
        assertEq(c, collected * 7_000 / 10_000);
        assertEq(i, collected * 1_000 / 10_000);
        assertGe(pr, collected * 2_000 / 10_000, "protocol never below its bps");
        assertLe(pr, collected * 2_000 / 10_000 + 2, "dust bounded");

        uint256 before = quote.balanceOf(CREATOR);
        vm.prank(CREATOR);
        assertEq(clHook.claim(q, CREATOR), c);
        assertEq(quote.balanceOf(CREATOR) - before, c, "paid in the quote");
    }

    /// @dev A sell pays its fee in the quote too: on what the pool pays out, taken after the swap.
    function test_CL_aSellPaysItsFeeInTheQuote() public {
        LaunchResultV2 memory r = _launch(_oneCL(keccak256("cl-sell-fee"), address(quote)));
        PoolKey memory key = _clKey(r.token, _clLeg(r.token, address(quote), 10_000));
        vm.warp(block.timestamp + 120);
        Currency q = Currency.wrap(address(quote));
        PoolId id = PoolId.wrap(r.poolIds[0]);
        _buyCL(key, r.token, 100 ether);
        uint256 afterBuy = clHook.pendingFee(id, q);
        uint256 fee = clHook.currentFee(id);

        uint256 quoteBefore = quote.balanceOf(address(this));
        IERC20(r.token).approve(address(clRouter), type(uint256).max);
        bool launchIs0 = Currency.unwrap(key.currency0) == r.token;
        clRouter.swap(
            key,
            ICLPoolManager.SwapParams({
                zeroForOne: launchIs0,
                amountSpecified: -int256(IERC20(r.token).balanceOf(address(this)) / 2),
                sqrtPriceLimitX96: launchIs0 ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1
            }),
            CLPoolManagerRouter.SwapTestSettings({withdrawTokens: true, settleUsingTransfer: true}),
            ""
        );
        uint256 received = quote.balanceOf(address(this)) - quoteBefore;
        uint256 taken = clHook.pendingFee(id, q) - afterBuy;
        assertGt(taken, 0, "a sell paid a fee");
        // The pool paid out `received + taken`; the guard kept `fee` of that, rounded down.
        assertEq(taken, (received + taken) * fee / 1e6, "fee on the quote the pool paid out");
        assertEq(clHook.pendingFee(id, Currency.wrap(r.token)), 0, "never in the launch token");
        assertEq(clHook.backing(Currency.wrap(r.token)), 0, "the guard holds no launch token");
    }

    function test_CL_launchTokenAsCurrency1() public {
        // Mine a salt whose token sorts ABOVE the quote, to cover the below-spot range.
        bytes32 salt;
        for (uint256 k;; ++k) {
            salt = keccak256(abi.encode("c1", k));
            if (uint160(_token(salt)) > uint160(address(quote))) break;
        }
        LaunchResultV2 memory r = _launch(_oneCL(salt, address(quote)));
        assertEq(_clProtocolFee(r.poolIds[0]), 0);
        assertFalse(clHook.getLaunch(PoolId.wrap(r.poolIds[0])).launchTokenIsCurrency0);
        PoolKey memory key = _clKey(r.token, _clLeg(r.token, address(quote), 10_000));
        vm.warp(block.timestamp + 120);
        _buyCL(key, r.token, 10 ether);
        assertGt(IERC20(r.token).balanceOf(address(this)), 0, "bought launch token");
    }

    /*//////////////////////////////////////////////////////////////
                              CL + BIN
    //////////////////////////////////////////////////////////////*/

    function test_CLBin_twoLegsBothBornAtZeroBothLocked() public {
        bytes32 salt = keccak256("cl-bin");
        LaunchParamsV2 memory p = _clAndBin(salt, address(quote));
        LaunchResultV2 memory r = _launch(p);

        assertEq(r.poolIds.length, 2);
        assertEq(_clProtocolFee(r.poolIds[0]), 0, "CL leg at zero");
        assertEq(_binProtocolFee(r.poolIds[1]), 0, "Bin leg at zero");
        assertTrue(kit.isLockedLaunch(r.poolIds[0]));
        assertTrue(kit.isLockedLaunch(r.poolIds[1]));

        BinLock memory lk = binLocker.getLock(r.lockIds[1]);
        assertEq(PoolId.unwrap(lk.poolId), r.poolIds[1]);
        assertEq(lk.binCount, 10);
        assertEq(lk.protocolBps, 2_000);
        (uint24[] memory ids, uint256[] memory shares,) = binLocker.getLockedBins(r.lockIds[1]);
        for (uint256 k; k < ids.length; ++k) {
            if (k != 0) assertGt(ids[k], ids[k - 1], "ascending");
            assertGt(shares[k], 0);
            uint256 tokenId = uint256(keccak256(abi.encode(r.poolIds[1], uint256(ids[k]))));
            assertEq(binPosm.balanceOf(address(kit), tokenId), 0, "kit holds no shares");
            assertEq(binPosm.balanceOf(address(binLocker), tokenId), shares[k]);
        }
        // Linear shape: the bin nearest the price holds the most.
        (uint128 x0, uint128 y0,,) = binPM.getBin(PoolId.wrap(r.poolIds[1]), ids[0]);
        (uint128 x9, uint128 y9,,) = binPM.getBin(PoolId.wrap(r.poolIds[1]), ids[9]);
        bool is0 = uint160(r.token) < uint160(address(quote));
        if (is0) assertGt(x0, x9, "linear, currency0: nearest (lowest id) is deepest");
        else assertGt(y9, y0, "linear, currency1: nearest (highest id) is deepest");

        // Weights: 60/40 of the seed, all of it seeded modulo rounding.
        BinLaunchGuardHook.Launch memory g = binHook.getLaunch(PoolId.wrap(r.poolIds[1]));
        assertEq(g.owner, address(kit));
        assertEq(uint8(launchRegistry.getLaunch(r.poolIds[1]).origin), uint8(LaunchOrigin.LaunchpadAttested));
        assertEq(IERC20(r.token).balanceOf(address(kit)), 0);
    }

    function test_CLBin_binLegTradesAndSplits() public {
        LaunchResultV2 memory r = _launch(_clAndBin(keccak256("bin-trade"), address(quote)));
        (PoolKey memory binKey,,) = kit.computeLegKey(r.token, _binLeg(address(quote), 4_000, BinShape.Linear, 10));
        vm.warp(block.timestamp + 120);
        Currency q = Currency.wrap(address(quote));
        PoolId id = PoolId.wrap(r.poolIds[1]);
        uint256 fee = binHook.currentFee(id);
        _buyBin(binKey, r.token, 1_000 ether);
        _buyBin(binKey, r.token, 1_000 ether);
        assertEq(binPM.protocolFeesAccrued(q), 0, "no core protocol fee on Bin");

        // The guard took the fee in the quote; the locked bins earned no LP fee from the swaps.
        uint256 pot = binHook.pendingFee(id, q);
        assertEq(pot, 2 * (uint256(1_000 ether) * fee / 1e6), "fee on the quote sent");
        assertEq(binHook.pendingFee(id, Currency.wrap(r.token)), 0, "never in the launch token");
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreBinLPLocker.NothingToCollect.selector, r.lockIds[1]));
        binLocker.collectFees(r.lockIds[1]);

        binHook.settleFee(id, q);
        assertEq(binHook.claimable(CREATOR, q), pot * 7_000 / 10_000, "creator credited from the guard's fee");
    }

    function test_Bin_everyNamedShapeInBothOrientations() public {
        BinShape[4] memory shapes = [BinShape.Flat, BinShape.Linear, BinShape.Exponential, BinShape.Stepped];
        for (uint256 s; s < 4; ++s) {
            for (uint256 o; o < 2; ++o) {
                bytes32 salt;
                for (uint256 k;; ++k) {
                    salt = keccak256(abi.encode("shape", s, o, k));
                    if ((uint160(_token(salt)) < uint160(address(quote))) == (o == 0)) break;
                }
                LegParams[] memory legs = new LegParams[](1);
                legs[0] = _binLeg(address(quote), 10_000, shapes[s], 12);
                LaunchResultV2 memory r = _launch(_params(salt, legs));
                assertEq(_binProtocolFee(r.poolIds[0]), 0);
                assertEq(binLocker.getLock(r.lockIds[0]).binCount, 12);
                assertEq(IERC20(r.token).balanceOf(address(kit)), 0);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                              NATIVE QUOTE
    //////////////////////////////////////////////////////////////*/

    function test_Native_CLAndBinQuotedInNative() public {
        LaunchParamsV2 memory p = _clAndBin(keccak256("native"), address(0));
        LaunchResultV2 memory r = _launch(p);
        assertEq(_clProtocolFee(r.poolIds[0]), 0);
        assertEq(_binProtocolFee(r.poolIds[1]), 0);
        // Native always sorts to currency0, so the launch token is currency1 on both legs.
        assertFalse(kit.getLeg(r.poolIds[0]).launchTokenIsCurrency0);
        assertFalse(kit.getLeg(r.poolIds[1]).launchTokenIsCurrency0);
        // The launcher paid exactly the launch fee: no native seed exists in a single-sided launch.
        assertEq(address(kit).balance, INITIAL_LAUNCH_FEE);

        PoolKey memory clKey = _clKey(r.token, p.legs[0]);
        vm.warp(block.timestamp + 120);
        _buyCL(clKey, r.token, 1 ether);
        assertGt(IERC20(r.token).balanceOf(address(this)), 0);
        assertEq(clPM.protocolFeesAccrued(Currency.wrap(address(0))), 0);
    }

    /*//////////////////////////////////////////////////////////////
                         STOCK-TOKEN QUOTE (PAUSABLE)
    //////////////////////////////////////////////////////////////*/

    function test_Stock_launchSucceedsWhileTheQuoteIsPaused() public {
        stock.setPaused(true);
        LaunchResultV2 memory r = _launch(_clAndBin(keccak256("stock-paused"), address(stock)));
        assertEq(_clProtocolFee(r.poolIds[0]), 0);
        assertEq(_binProtocolFee(r.poolIds[1]), 0);
        assertTrue(clLocker.isLocked(r.lockIds[0]));
        assertTrue(binLocker.isLocked(r.lockIds[1]));
    }

    function test_Stock_pausedMidLaunchHaltsTradingNotTheLocks() public {
        LaunchParamsV2 memory p = _clAndBin(keccak256("stock-mid"), address(stock));
        LaunchResultV2 memory r = _launch(p);
        PoolKey memory clKey = _clKey(r.token, p.legs[0]);
        vm.warp(block.timestamp + 120);

        _buyCL(clKey, r.token, 10 ether);

        // The issuer pauses: buying needs a quote transfer, so it reverts; nothing the kit wrote changes.
        stock.setPaused(true);
        vm.expectRevert();
        _buyCL(clKey, r.token, 10 ether);
        // Collection pays the quote out of the Vault, so it reverts too - the fees stay in the position.
        vm.expectRevert();
        clLocker.collectFees(r.lockIds[0]);
        assertTrue(clLocker.isLocked(r.lockIds[0]));
        assertEq(_clProtocolFee(r.poolIds[0]), 0);

        // `uiMultiplier` is display-only: raw units are what core and the locker account in.
        stock.setUiMultiplier(3e18);
        stock.setPaused(false);
        uint256 vaultBefore = stock.balanceOf(address(vault));
        _buyCL(clKey, r.token, 7 ether);
        assertEq(stock.balanceOf(address(vault)) - vaultBefore, 7 ether, "raw units, multiplier ignored");
        clLocker.collectFees(r.lockIds[0]);
        assertGt(clLocker.claimable(CREATOR, Currency.wrap(address(stock))), 0);
    }

    /*//////////////////////////////////////////////////////////////
                         MULTI-QUOTE, REMAINDER, RECORDS
    //////////////////////////////////////////////////////////////*/

    function test_Multi_fourLegsThreeQuotes() public {
        bytes32 salt = keccak256("four");
        address token = _token(salt);
        LegParams[] memory legs = new LegParams[](4);
        legs[0] = _clLeg(token, address(quote), 4_000);
        legs[1] = _clLeg(token, address(0), 2_000);
        legs[2] = _binLeg(address(stock), 3_000, BinShape.Exponential, 16);
        legs[3] = _binLeg(address(0), 1_000, BinShape.Stepped, 12);
        LaunchResultV2 memory r = _launch(_params(salt, legs));
        for (uint256 i; i < 4; ++i) {
            assertTrue(kit.isLockedLaunch(r.poolIds[i]));
            assertEq(kit.getLeg(r.poolIds[i]).lockId, r.lockIds[i]);
        }
        assertEq(kit.legsOf(r.token).length, 4);
        assertEq(IERC20(r.token).balanceOf(address(kit)), 0);
    }

    function test_Remainder_fullSeedDustGoesToCreatorWhenNoAllocation() public {
        LaunchParamsV2 memory p = _clAndBin(keccak256("full-seed"), address(quote));
        p.seedSupply = TOTAL_SUPPLY;
        p.allocationRecipient = address(0);
        LaunchResultV2 memory r = _launch(p);
        assertEq(IERC20(r.token).balanceOf(address(kit)), 0);
        assertLt(IERC20(r.token).balanceOf(CREATOR), 1e6, "only rounding dust reaches the creator");
    }

    function test_Defaults_zeroAddressesMeanTheLauncher() public {
        LaunchParamsV2 memory p = _oneCL(keccak256("defaults"), address(quote));
        p.creator = address(0);
        p.launchOperator = address(0);
        p.launchSteward = address(0);
        LaunchResultV2 memory r = _launch(p);
        assertEq(kit.getLaunch(r.token).creator, LAUNCHER);
        assertEq(kit.getLaunch(r.token).operator, LAUNCHER);
        assertEq(clLocker.getLock(r.lockIds[0]).creator, LAUNCHER);
        assertEq(launchRegistry.getLaunch(r.poolIds[0]).steward, LAUNCHER);
    }

    function test_Event_launchCreated() public {
        bytes32 salt = keccak256("event");
        LaunchParamsV2 memory p = _oneCL(salt, address(quote));
        vm.expectEmit(true, true, true, true, address(kit));
        emit ILaunchpadKitV2.LaunchCreated(
            _token(salt),
            CREATOR,
            address(0),
            LAUNCHER,
            OPERATOR,
            TOTAL_SUPPLY,
            SEED_SUPPLY,
            1,
            uint40(block.timestamp + 120),
            INITIAL_LAUNCH_FEE,
            INTEGRATOR,
            0
        );
        _launchWithValue(p, INITIAL_LAUNCH_FEE);
    }

    /*//////////////////////////////////////////////////////////////
                             RECONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function test_Reconfigure_operatorMovesEveryLegTogether() public {
        LaunchParamsV2 memory p = _clAndBin(keccak256("reconf"), address(quote));
        LaunchResultV2 memory r = _launch(p);
        PoolKey[] memory keys = new PoolKey[](2);
        (keys[0],,) = kit.computeLegKey(r.token, p.legs[0]);
        (keys[1],,) = kit.computeLegKey(r.token, p.legs[1]);

        ScheduleParams memory s = p.schedule;
        s.preset = Preset.Custom;
        s.initialFeeBips = 50_000;
        s.finalFeeBips = 5_000;
        s.decaySeconds = 900;
        s.enabled = true;
        s.startDelaySeconds = 3_600;

        vm.prank(ATTACKER);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.NotLaunchOperator.selector, r.token, ATTACKER));
        kit.reconfigureLaunch(r.token, keys, s, _noTax());

        vm.prank(OPERATOR);
        kit.reconfigureLaunch(r.token, keys, s, _noTax());
        assertEq(clHook.getLaunch(PoolId.wrap(r.poolIds[0])).decaySeconds, 900);
        assertEq(binHook.getLaunch(PoolId.wrap(r.poolIds[1])).decaySeconds, 900);
        assertEq(kit.getLaunch(r.token).startTime, uint40(block.timestamp + 3_600));
        // Never touches the flag.
        assertTrue(kit.isLockedLaunch(r.poolIds[0]));
        assertTrue(kit.isLockedLaunch(r.poolIds[1]));

        // A 50% preset cannot be applied to a launch with a Bin leg.
        s.preset = Preset.Stealth;
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.PresetUnavailableOnBin.selector, Preset.Stealth));
        kit.reconfigureLaunch(r.token, keys, s, _noTax());

        // Keys must be exactly the launch's legs, in order.
        (keys[0], keys[1]) = (keys[1], keys[0]);
        s.preset = Preset.FairLaunch;
        vm.prank(OPERATOR);
        vm.expectRevert(abi.encodeWithSelector(ILaunchpadKitV2.LegKeyMismatch.selector, 0));
        kit.reconfigureLaunch(r.token, keys, s, _noTax());

        // Frozen from startTime, by the guards.
        (keys[0], keys[1]) = (keys[1], keys[0]);
        vm.warp(kit.getLaunch(r.token).startTime);
        vm.prank(OPERATOR);
        vm.expectRevert();
        kit.reconfigureLaunch(r.token, keys, s, _noTax());
    }

    /*//////////////////////////////////////////////////////////////
                           LAUNCHPAD LISTING
    //////////////////////////////////////////////////////////////*/

    function test_RegisterLaunchpad_selfRegisteredWithTheImmutableSteward() public {
        LaunchpadMetadata memory m;
        m.name = "DeepCore Launchpad";
        m.description = "kit v2";
        vm.prank(ATTACKER);
        kit.registerLaunchpad(m);
        LaunchpadRecord memory rec = launchRegistry.getLaunchpad(address(kit));
        assertEq(uint8(rec.origin), uint8(LaunchpadOrigin.SelfRegistered));
        assertEq(rec.steward, LAUNCHPAD_STEWARD, "caller cannot choose the steward");
    }

    function test_RegisterLaunchpad_claimsAStrangersListing() public {
        LaunchpadMetadata memory m;
        m.name = "Squatted";
        vm.prank(ATTACKER);
        launchRegistry.registerLaunchpad(address(kit), ATTACKER, m);
        assertEq(uint8(launchRegistry.getLaunchpad(address(kit)).origin), uint8(LaunchpadOrigin.Claimed));
        kit.registerLaunchpad(m);
        LaunchpadRecord memory rec = launchRegistry.getLaunchpad(address(kit));
        assertEq(uint8(rec.origin), uint8(LaunchpadOrigin.SelfRegistered));
        assertEq(rec.steward, LAUNCHPAD_STEWARD);
    }

    /*//////////////////////////////////////////////////////////////
                  THE THREE LINKS, THROUGH THE KIT

        `LaunchParamsV2.listing` is a pass-through: the kit does not
        read, validate or store the metadata, it hands it to
        `registerLaunch` once per leg. These tests pin that hop, so a
        future refactor of `LaunchLegs` that drops a field is caught
        here rather than by a token page with no Telegram link.
    //////////////////////////////////////////////////////////////*/

    function test_LISTING_allThreeLinksReachEveryLegsRegistryRecord() public {
        bytes32 salt = keccak256("listing-links");
        LaunchParamsV2 memory p = _clAndBin(salt, address(quote));
        p.listing.websiteURI = "https://project.invalid";
        p.listing.xHandle = "project";
        p.listing.telegramHandle = "project_chat";
        LaunchResultV2 memory r = _launch(p);

        assertEq(r.poolIds.length, 2, "two legs");
        for (uint256 i = 0; i < r.poolIds.length; i++) {
            LaunchRecord memory reg = launchRegistry.getLaunch(r.poolIds[i]);
            assertEq(reg.metadata.websiteURI, "https://project.invalid");
            assertEq(reg.metadata.xHandle, "project");
            assertEq(reg.metadata.telegramHandle, "project_chat");
        }
    }

    /// @notice All three links are optional, through the kit as well as directly.
    function test_LISTING_emptyLinksAreLegalThroughTheKit() public {
        bytes32 salt = keccak256("listing-empty");
        LaunchParamsV2 memory p = _oneCL(salt, address(quote));
        p.listing.websiteURI = "";
        p.listing.xHandle = "";
        p.listing.telegramHandle = "";
        LaunchResultV2 memory r = _launch(p);

        LaunchRecord memory reg = launchRegistry.getLaunch(r.poolIds[0]);
        assertEq(reg.metadata.xHandle, "");
        assertEq(reg.metadata.telegramHandle, "");
    }

    /// @notice The registry's handle rules are the kit's too, by inheritance rather than by a second
    /// copy of the rule. The kit adds no validation of its own and must not: two places to change a
    /// limit is one place for the limits to disagree.
    function test_LISTING_kitInheritsTheRegistrysHandleRules() public {
        uint256 max = launchRegistry.MAX_X_HANDLE_BYTES();
        bytes32 salt = keccak256("listing-bad-handle");
        LaunchParamsV2 memory p = _oneCL(salt, address(quote));
        // A leading '@' — the single most likely thing a front end forgets to strip.
        p.listing.xHandle = "@project";

        uint256 value = kit.launchFeeWei() + p.integratorLaunchFeeWei;
        vm.deal(LAUNCHER, LAUNCHER.balance + value);
        vm.prank(LAUNCHER);
        vm.expectRevert(
            abi.encodeWithSelector(IDeepCoreLaunchRegistry.InvalidHandle.selector, "@project", max)
        );
        kit.createLaunch{value: value}(p);
    }

    /// @notice The string bound survives the move to handles, on the field that is still a string.
    function test_LISTING_kitInheritsTheRegistrysLengthBound() public {
        uint256 max = launchRegistry.MAX_URI_BYTES();
        bytes32 salt = keccak256("listing-oversize");
        LaunchParamsV2 memory p = _oneCL(salt, address(quote));
        p.listing.websiteURI = string(new bytes(max + 1));

        uint256 value = kit.launchFeeWei() + p.integratorLaunchFeeWei;
        vm.deal(LAUNCHER, LAUNCHER.balance + value);
        vm.prank(LAUNCHER);
        vm.expectRevert(abi.encodeWithSelector(IDeepCoreLaunchRegistry.StringTooLong.selector, max + 1, max));
        kit.createLaunch{value: value}(p);
    }
}

/// @dev Any contract with code, standing in for a non-factory token.
contract MockLike {
    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}
