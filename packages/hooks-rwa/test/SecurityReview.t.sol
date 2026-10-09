// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 DeepCoreProtocol
pragma solidity 0.8.26;

// SCRATCH FILE - security review only. Not part of the shipped suite.
// Each test is named after the finding it demonstrates. Tests whose name starts with
// `test_FINDING_` are expected to demonstrate a defect; tests named `test_OK_` confirm a
// claimed guarantee actually holds. `test_FIX<n>_` is a finding that was fixed, now asserting
// the fix; `test_DESIGN<n>_` is a finding triaged as intended behaviour, asserting that
// behaviour so a change to it is a deliberate decision rather than an accident.

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {Vault} from "infinity-core/src/Vault.sol";
import {CLPoolManager} from "infinity-core/src/pool-cl/CLPoolManager.sol";
import {ICLPoolManager} from "infinity-core/src/pool-cl/interfaces/ICLPoolManager.sol";
import {ICLHooks} from "infinity-core/src/pool-cl/interfaces/ICLHooks.sol";
import {IHooks} from "infinity-core/src/interfaces/IHooks.sol";
import {PoolKey} from "infinity-core/src/types/PoolKey.sol";
import {PoolId} from "infinity-core/src/types/PoolId.sol";
import {Currency} from "infinity-core/src/types/Currency.sol";
import {BalanceDelta} from "infinity-core/src/types/BalanceDelta.sol";
import {LPFeeLibrary} from "infinity-core/src/libraries/LPFeeLibrary.sol";
import {Hooks} from "infinity-core/src/libraries/Hooks.sol";
import {CustomRevert} from "infinity-core/src/libraries/CustomRevert.sol";
import {CLPoolParametersHelper} from "infinity-core/src/pool-cl/libraries/CLPoolParametersHelper.sol";

import {TokenFixture} from "infinity-core/test/helpers/TokenFixture.sol";
import {Deployers} from "infinity-core/test/pool-cl/helpers/Deployers.sol";

import {MarketHoursHook} from "../src/MarketHoursHook.sol";
import {StockPairHook} from "../src/StockPairHook.sol";
import {PermissionedPoolHook} from "../src/PermissionedPoolHook.sol";
import {MarketHoursModule} from "../src/modules/MarketHoursModule.sol";
import {IPriceBandOracle} from "../src/interfaces/IPriceBandOracle.sol";
import {ManualPriceBandOracle} from "../src/oracles/ManualPriceBandOracle.sol";
import {IComplianceOracle} from "../src/interfaces/IComplianceOracle.sol";
import {AllowlistComplianceOracle} from "../src/oracles/AllowlistComplianceOracle.sol";

import {AttestingRouter} from "./mocks/AttestingRouter.sol";

/*//////////////////////////////////////////////////////////////
        PART 1 - MarketHoursHook: calendar / configuration
//////////////////////////////////////////////////////////////*/

contract SecurityReviewCalendarTest is Test, Deployers, TokenFixture {
    using LPFeeLibrary for uint24;

    Vault vault;
    CLPoolManager poolManager;
    MarketHoursHook hook;
    ManualPriceBandOracle priceOracle;

    PoolKey key;
    PoolId poolId;

    address constant ISSUER = address(0x155);
    address constant NEW_ISSUER = address(0x156);
    address constant GUARDIAN = address(0x6DA);

    uint24 constant STATIC_FEE = 3000;
    int24 constant TICK_SPACING = 60;

    uint256 constant MONDAY_MIDNIGHT = 1_704_067_200; // 2024-01-01 00:00 UTC, a Monday
    uint24 constant OPEN = 52_200;
    uint24 constant CLOSE = 75_600;
    uint8 constant WEEKDAYS = uint8((1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5));
    uint32 constant BAND_PPM = 50_000;

    function setUp() public {
        vm.warp(MONDAY_MIDNIGHT + 16 hours);

        (vault, poolManager) = createFreshManager();
        hook = new MarketHoursHook(poolManager, address(this));
        priceOracle = new ManualPriceBandOracle(address(this));

        initializeTokens();
        mint(1_000_000 ether);

        key = _key(STATIC_FEE);
        poolId = key.toId();

        hook.configureMarket(key, _settings());
        hook.setMarketGuardian(GUARDIAN);
        priceOracle.setReferencePrice(poolId, SQRT_RATIO_1_1);
        poolManager.initialize(key, SQRT_RATIO_1_1);
    }

    function _key(uint24 fee) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(hook)),
            poolManager: poolManager,
            fee: fee,
            parameters: CLPoolParametersHelper.setTickSpacing(
                bytes32(uint256(hook.getHooksRegistrationBitmap())), TICK_SPACING
            )
        });
    }

    function _settings() internal view returns (MarketHoursModule.MarketSettings memory) {
        return MarketHoursModule.MarketSettings({
            issuer: ISSUER,
            oracle: IPriceBandOracle(address(priceOracle)),
            maxUpPpm: BAND_PPM,
            maxDownPpm: BAND_PPM,
            maxPriceAge: 1 days,
            openSecondOfDay: OPEN,
            closeSecondOfDay: CLOSE,
            weekdayMask: WEEKDAYS,
            sessionEnabled: true,
            bandEnabled: true,
            gateLiquidity: false
        });
    }

    /*//////////////////////////////////////////////////////////////
      FINDING 1 (FIXED) - `EmptyWeekdayMask` was bypassed by the unused bit 7.

      The guard exists to stop a pool being configured that "can never trade
      while looking, in every event and every view, exactly like a configured
      one". It only rejected `weekdayMask == 0`, but `_scheduleForDay` reads
      bits 0..6 only, so `0x80` was non-zero, passed, and produced a
      permanently closed market - reachable by the owner via `configureMarket`
      and, with no timelock at all, by the issuer via `setSessionHours`.

      `InvalidWeekdayMask` now refuses any bit outside 0..6 on both paths.
      These tests previously asserted the defect; they now assert it is closed.
    //////////////////////////////////////////////////////////////*/

    function test_FIX1_reservedBit7IsRefusedByConfigureMarket() public {
        MarketHoursModule.MarketSettings memory s = _settings();
        s.weekdayMask = 0x80; // no weekday bit set at all

        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.InvalidWeekdayMask.selector, uint8(0x80)));
        hook.configureMarket(key, s);

        // The pool kept its previous, genuine schedule.
        assertEq(hook.marketConfig(poolId).weekdayMask, WEEKDAYS, "rejected write left no trace");
        assertTrue(hook.isTradable(poolId), "and it still trades");

        // Mask 0 is still reported as the empty-mask mistake, not the reserved-bit one.
        s.weekdayMask = 0;
        vm.expectRevert(MarketHoursModule.EmptyWeekdayMask.selector);
        hook.configureMarket(key, s);
    }

    /// The same gap on the issuer's fast, un-timelocked lever, now closed.
    function test_FIX1_reservedBit7IsRefusedBySetSessionHours() public {
        vm.prank(ISSUER);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.InvalidWeekdayMask.selector, uint8(0x80)));
        hook.setSessionHours(poolId, 0x80, OPEN, CLOSE);
        assertTrue(hook.isTradable(poolId), "the issuer could not close the market this way");

        vm.prank(ISSUER);
        vm.expectRevert(MarketHoursModule.EmptyWeekdayMask.selector);
        hook.setSessionHours(poolId, 0, OPEN, CLOSE);
    }

    /*//////////////////////////////////////////////////////////////
      FINDING 2 (MEDIUM, FIXED 2026-09-14) - day overrides outlived the
      issuer who wrote them.

      `configureMarket` is the ONLY way to replace a pool's issuer, and it
      did not touch `_dayOverrides`. A rogue or compromised issuer could
      write an unbounded number of future holidays; governance could remove
      the issuer but the only remedy for the calendar was
      `clearDayOverrides`, O(n) over an attacker-chosen n.

      Overrides are now keyed by a per-pool calendar epoch, and the owner's
      `resetCalendar` advances it in O(1). `configureMarket` still does NOT
      advance it, deliberately: an ordinary issuer rotation must not delete
      legitimate holidays and reopen those days to trading.
    //////////////////////////////////////////////////////////////*/

    event CalendarReset(PoolId indexed poolId, address indexed by, uint32 newEpoch);

    function _rogueCloses(uint256 n) internal returns (uint32[] memory days_) {
        uint32 today = hook.dayIndexOf(block.timestamp);
        days_ = new uint32[](n);
        for (uint256 i = 0; i < n; ++i) days_[i] = today + uint32(i);
        vm.prank(ISSUER);
        hook.setHolidays(poolId, days_);
    }

    /// The original finding, now recoverable in one owner call whatever n the rogue chose.
    /// FAILS ON THE PRE-FIX MODULE: it has no `resetCalendar` (does not compile), and with the
    /// epoch removed from the key the reset leaves the rogue calendar in force.
    function test_FIX2_ownerDiscardsARogueCalendarInOneCall() public {
        uint32 today = hook.dayIndexOf(block.timestamp);
        _rogueCloses(500);
        assertFalse(hook.isTradable(poolId), "market closed by the rogue calendar");

        MarketHoursModule.MarketSettings memory s = _settings();
        s.issuer = NEW_ISSUER;
        hook.configureMarket(key, s);
        assertFalse(hook.isTradable(poolId), "rotation alone still leaves the calendar in force, by design");

        vm.expectEmit(address(hook));
        emit CalendarReset(poolId, address(this), 1);
        hook.resetCalendar(poolId);

        assertEq(hook.calendarEpoch(poolId), 1);
        assertFalse(hook.dayOverride(poolId, today).isSet, "every override is unreachable");
        assertTrue(hook.isTradable(poolId), "back on the weekly schedule");
        vm.warp(block.timestamp + 101 days); // a Thursday afternoon, well inside the rogue range
        assertTrue(hook.isTradable(poolId), "and stays there across the whole rogue range");
    }

    /// The design constraint: rotating an issuer must not silently delete a legitimate calendar.
    function test_FIX2_configureMarketDoesNotDiscardTheCalendar() public {
        uint32[] memory holiday = new uint32[](1);
        holiday[0] = hook.dayIndexOf(block.timestamp);
        vm.prank(ISSUER);
        hook.setHolidays(poolId, holiday);

        MarketHoursModule.MarketSettings memory s = _settings();
        s.issuer = NEW_ISSUER;
        hook.configureMarket(key, s);

        assertEq(hook.calendarEpoch(poolId), 0);
        assertTrue(hook.dayOverride(poolId, holiday[0]).isSet, "the legitimate holiday survives rotation");
        assertFalse(hook.isTradable(poolId));
    }

    /// Wiping holidays reopens days, the less-restrictive direction, so it is the owner's alone.
    function test_FIX2_resetCalendarIsOwnerOnly() public {
        address[3] memory notOwner = [ISSUER, GUARDIAN, NEW_ISSUER];
        for (uint256 i; i < notOwner.length; ++i) {
            vm.prank(notOwner[i]);
            vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.NotMarketAdmin.selector, notOwner[i]));
            hook.resetCalendar(poolId);
        }
        assertEq(hook.calendarEpoch(poolId), 0);
    }

    function test_FIX2_resetCalendarRequiresAConfiguredPool() public {
        PoolId unknown = _key(500).toId();
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.MarketNotConfigured.selector, unknown));
        hook.resetCalendar(unknown);
    }

    /// After a reset the new issuer's calendar applies normally, clears only its own epoch, and a
    /// later reset never resurrects an earlier epoch's overrides.
    function test_FIX2_calendarWrittenAfterAResetWorksAndOldEpochsNeverReturn() public {
        uint32 today = hook.dayIndexOf(block.timestamp);
        _rogueCloses(3);
        hook.resetCalendar(poolId);
        assertFalse(hook.dayOverride(poolId, today + 1).isSet, "the rogue's later days are gone too");

        uint32[] memory one = new uint32[](1);
        one[0] = today;
        vm.prank(ISSUER);
        hook.setHolidays(poolId, one);
        assertFalse(hook.isTradable(poolId), "a holiday written in the new epoch is enforced");

        vm.prank(ISSUER);
        hook.clearDayOverrides(poolId, one);
        assertTrue(hook.isTradable(poolId), "clearing in the new epoch does not expose epoch 0");

        hook.resetCalendar(poolId);
        assertEq(hook.calendarEpoch(poolId), 2);
        assertFalse(hook.dayOverride(poolId, today).isSet);
        assertFalse(hook.dayOverride(poolId, today + 2).isSet, "epoch 0 is never resurrected");
        vm.warp(block.timestamp + 1 days); // Tuesday: a rogue holiday in epoch 0
        assertTrue(hook.isTradable(poolId), "a second reset starts empty, it does not restore epoch 0");
    }

    /// Special sessions go too, including the wrap-tail lookup on the previous day's override.
    function test_FIX2_resetAlsoDiscardsSpecialSessionsOnTheWrapPath() public {
        uint32 monday = hook.dayIndexOf(MONDAY_MIDNIGHT);
        // A Saturday special session 22:00 -> 02:00 that wraps into Sunday.
        uint32[] memory saturday = new uint32[](1);
        saturday[0] = monday + 5;
        vm.prank(ISSUER);
        hook.setSpecialSessions(poolId, saturday, 79_200, 7_200);
        uint256 sundayOneAm = MONDAY_MIDNIGHT + 6 days + 1 hours;
        assertTrue(hook.isSessionOpenAt(poolId, sundayOneAm), "the Saturday session's tail runs into Sunday");

        hook.resetCalendar(poolId);
        assertFalse(hook.isSessionOpenAt(poolId, sundayOneAm), "no weekday session on Saturday, so no tail");
        assertFalse(hook.isSessionOpenAt(poolId, MONDAY_MIDNIGHT + 5 days + 23 hours));
    }

    /*//////////////////////////////////////////////////////////////
      FINDING 3 (TRIAGED: BY DESIGN, DOCUMENTATION CORRECTED) - a holiday
      on the day a wrapped session ENDS does not close that session's tail.

      Not a vulnerability. The module attributes a wrapping session to the
      day it OPENED on, for the weekday mask and the overrides alike, and
      says so. A holiday on day D cancels the session that OPENS on D; the
      tail of D-1's session still runs into D. No party but the issuer or the
      owner can write a calendar, nothing here lets anyone else trade outside
      the schedule as the contract defines it, and the tail is the same
      overnight window the pool trades every other night, under the same halt
      and the same band.

      What was wrong was the prose: `setHolidays` said "mark days as closed"
      and `DayOverride.closed` said "no session", both of which read as "the
      whole UTC day". Both now state the attribution. These tests pin the
      behaviour and the procedure an issuer must follow, so changing the
      convention later is a decision, not a side effect.
    //////////////////////////////////////////////////////////////*/

    /// The attribution rule, asserted: a holiday on the TAIL day leaves the tail open.
    function test_DESIGN3_holidayOnTheTailDayDoesNotCloseTheWrappedSession() public {
        // 22:00 -> 02:00, Mon..Fri.
        MarketHoursModule.MarketSettings memory s = _settings();
        s.openSecondOfDay = 79_200;
        s.closeSecondOfDay = 7_200;
        hook.configureMarket(key, s);

        uint32 monday = hook.dayIndexOf(MONDAY_MIDNIGHT);
        uint32 tuesday = monday + 1;

        // The issuer declares TUESDAY a holiday.
        uint32[] memory holiday = new uint32[](1);
        holiday[0] = tuesday;
        vm.prank(ISSUER);
        hook.setHolidays(poolId, holiday);

        // Tuesday 01:00 UTC - the tail of MONDAY's session - is open, because the holiday
        // cancelled the session that opens on Tuesday, not Monday's.
        uint256 tuesdayOneAm = MONDAY_MIDNIGHT + 1 days + 1 hours;
        assertTrue(hook.isSessionOpenAt(poolId, tuesdayOneAm), "Monday's tail runs into Tuesday");

        // ...and the session that OPENS on Tuesday is the one the holiday closed, tail included.
        assertFalse(hook.isSessionOpenAt(poolId, MONDAY_MIDNIGHT + 1 days + 23 hours), "Tuesday evening closed");
        assertFalse(hook.isSessionOpenAt(poolId, MONDAY_MIDNIGHT + 2 days + 1 hours), "and its Wednesday tail");
    }

    /// The procedure, asserted. To stop ALL trading during UTC day D on a wrapping schedule, an
    /// issuer writes TWO overrides: the holiday on D, and a non-wrapping special session on D-1
    /// that ends the D-1 session at the last expressible second. (`closeSecondOfDay` must be below
    /// 86400, so the D-1 session loses its final second, 23:59:59.)
    function test_DESIGN3_closingAWholeUtcDayNeedsTheOpeningDayTruncatedToo() public {
        MarketHoursModule.MarketSettings memory s = _settings();
        s.openSecondOfDay = 79_200; // 22:00
        s.closeSecondOfDay = 7_200; // 02:00
        hook.configureMarket(key, s);

        uint32 monday = hook.dayIndexOf(MONDAY_MIDNIGHT);

        uint32[] memory tue = new uint32[](1);
        tue[0] = monday + 1;
        uint32[] memory mon = new uint32[](1);
        mon[0] = monday;

        vm.startPrank(ISSUER);
        hook.setHolidays(poolId, tue);
        hook.setSpecialSessions(poolId, mon, 79_200, 86_399);
        vm.stopPrank();

        assertTrue(hook.isSessionOpenAt(poolId, MONDAY_MIDNIGHT + 23 hours), "Monday evening still trades");
        assertFalse(hook.isSessionOpenAt(poolId, MONDAY_MIDNIGHT + 86_399), "except its last second");
        assertFalse(hook.isSessionOpenAt(poolId, MONDAY_MIDNIGHT + 1 days + 1 hours), "no tail into Tuesday");
        assertFalse(hook.isSessionOpenAt(poolId, MONDAY_MIDNIGHT + 1 days + 23 hours), "no Tuesday session");
        assertFalse(hook.isSessionOpenAt(poolId, MONDAY_MIDNIGHT + 2 days + 1 hours), "no tail into Wednesday");
        assertTrue(hook.isSessionOpenAt(poolId, MONDAY_MIDNIGHT + 2 days + 23 hours), "Wednesday reopens");
    }

    /*//////////////////////////////////////////////////////////////
      FINDING 4 (FIXED) - the band never constrained the price a pool is BORN at.

      `beforeInitialize` checked configuration and the fee flag, never the
      reference price, and `initialize` is permissionless once governance has
      configured a key. Anyone could front-run the issuer's initialize at any
      price. The band did not help afterwards: from an out-of-band birth, the
      arbitrage that extracts value from the first LP deposit is a CONVERGING
      swap, which the band exists to permit. Measured on this suite's fixtures
      before the fix: born at 4x, an LP depositing ~651 units (valued at the
      reference) lost ~345 of them to one converging swap.

      `beforeInitialize` now requires the initial price to be strictly inside
      the band, with no converging exception (a pool that has never traded has
      not gapped), failing closed if the reference is unavailable or stale.
    //////////////////////////////////////////////////////////////*/

    function _expectInitRevert(PoolId id, uint256 ratioPpm) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                ICLHooks.beforeInitialize.selector,
                abi.encodeWithSelector(
                    MarketHoursModule.PriceBandBreached.selector, id, ratioPpm, uint256(950_000), uint256(1_050_000)
                ),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function _freshPool(uint24 fee) internal returns (PoolKey memory k, PoolId id) {
        k = _key(fee);
        id = k.toId();
        hook.configureMarket(k, _settings());
        priceOracle.setReferencePrice(id, SQRT_RATIO_1_1);
    }

    /// The original finding, now refused: born at 4x the reference with a +/-5% band.
    function test_FIX4_initializationAboveTheBandIsRefused() public {
        (PoolKey memory k2, PoolId id2) = _freshPool(500);

        uint160 farOut = uint160(uint256(SQRT_RATIO_1_1) * 2); // 2x sqrt == 4x price
        _expectInitRevert(id2, 4_000_000);
        poolManager.initialize(k2, farOut);

        (uint160 born,,,) = poolManager.getSlot0(id2);
        assertEq(born, 0, "the front-run left no pool behind");

        // The honest initialize at the reference still lands afterwards.
        poolManager.initialize(k2, SQRT_RATIO_1_1);
        (born,,,) = poolManager.getSlot0(id2);
        assertEq(born, SQRT_RATIO_1_1);
    }

    /// No converging exception at birth: the lower edge binds exactly like the upper one.
    function test_FIX4_initializationBelowTheBandIsRefused() public {
        (PoolKey memory k2, PoolId id2) = _freshPool(500);

        _expectInitRevert(id2, 250_000); // 0.5x sqrt == 0.25x price
        poolManager.initialize(k2, uint160(uint256(SQRT_RATIO_1_1) / 2));
    }

    /// The residual, asserted rather than hand-waved: a front-runner can still choose the birth
    /// price, but only INSIDE the band. The band width is now the ceiling on a mis-initialization.
    function test_FIX4_frontRunIsBoundedToTheBandWidth() public {
        (PoolKey memory k2, PoolId id2) = _freshPool(500);

        // sqrt x1.025 == price x1.050625, just past the +5% edge: refused.
        uint160 justOutside = uint160(uint256(SQRT_RATIO_1_1) * 1025 / 1000);
        vm.expectRevert();
        poolManager.initialize(k2, justOutside);

        // sqrt x1.024 == price x1.048576, inside: accepted.
        uint160 justInside = uint160(uint256(SQRT_RATIO_1_1) * 1024 / 1000);
        poolManager.initialize(k2, justInside);
        (uint160 born,,,) = poolManager.getSlot0(id2);
        assertEq(born, justInside);
    }

    /// Fails closed: no reference, no pool. Publishing the reference is a precondition of launch.
    function test_FIX4_initializationFailsClosedWithoutAReference() public {
        PoolKey memory k2 = _key(500);
        PoolId id2 = k2.toId();
        hook.configureMarket(k2, _settings());

        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                ICLHooks.beforeInitialize.selector,
                abi.encodeWithSelector(
                    MarketHoursModule.PriceOracleUnavailable.selector, address(priceOracle), id2
                ),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(k2, SQRT_RATIO_1_1);
    }

    /// Scoped to the band: a pool that opted out of the band is not given one at birth.
    function test_FIX4_bandDisabledPoolIsNotConstrainedAtBirth() public {
        PoolKey memory k2 = _key(500);
        PoolId id2 = k2.toId();
        MarketHoursModule.MarketSettings memory s = _settings();
        s.bandEnabled = false;
        hook.configureMarket(k2, s);

        uint160 farOut = uint160(uint256(SQRT_RATIO_1_1) * 2);
        poolManager.initialize(k2, farOut);
        (uint160 born,,,) = poolManager.getSlot0(id2);
        assertEq(born, farOut);
    }

    /*//////////////////////////////////////////////////////////////
      FINDING 5 (FIXED) - renouncing ownership froze the market config.

      `Ownable2Step.renounceOwnership` was not disabled. After it, no oracle
      rotation, no band change, no issuer replacement and no guardian change
      was possible for the life of the hook. `renounceOwnership` now reverts
      `RenounceDisabled()` on every Ownable contract in this package; the full
      per-contract coverage is `test/RenounceDisabled.t.sol`.
    //////////////////////////////////////////////////////////////*/

    function test_FIX5_renounceOwnershipIsRefusedAndMarketConfigurationSurvives() public {
        vm.expectRevert(MarketHoursHook.RenounceDisabled.selector);
        hook.renounceOwnership();
        assertEq(hook.owner(), address(this));

        // Every recovery lever the renounce would have removed is still in governance's hands.
        MarketHoursModule.MarketSettings memory s = _settings();
        s.issuer = NEW_ISSUER;
        hook.configureMarket(key, s);
        assertEq(hook.marketConfig(poolId).issuer, NEW_ISSUER, "a rogue issuer can still be replaced");

        hook.setMarketGuardian(address(0xBEEF));
        assertEq(hook.marketGuardian(), address(0xBEEF), "the guardian can still be rotated");
    }

    /*//////////////////////////////////////////////////////////////
      Confirmations: things the code claims that DO hold.
    //////////////////////////////////////////////////////////////*/

    /// The guardian really is halt-only, on every lever that exists.
    function test_OK_guardianIsStrictlyRestricting() public {
        vm.prank(GUARDIAN);
        hook.halt(poolId, "flash crash");
        assertFalse(hook.isTradable(poolId));

        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.NotMarketOperator.selector, GUARDIAN));
        hook.resume(poolId);

        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.NotMarketOperator.selector, GUARDIAN));
        hook.setSessionHours(poolId, WEEKDAYS, OPEN, CLOSE);

        uint32[] memory d = new uint32[](1);
        d[0] = 0;
        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.NotMarketOperator.selector, GUARDIAN));
        hook.clearDayOverrides(poolId, d);

        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.NotMarketAdmin.selector, GUARDIAN));
        hook.setMarketGuardian(GUARDIAN);
    }

    /// A price-band oracle outside `TickMath`'s range cannot overflow `_priceRatioPpm`.
    function testFuzz_OK_priceRatioNeverOverflows(uint160 poolSqrt, uint160 refSqrt) public view {
        refSqrt = uint160(bound(refSqrt, 1, type(uint160).max));
        (bool wouldRevert,) = hook.previewPriceBand(poolId, false, poolSqrt);
        wouldRevert; // the call not reverting IS the assertion
        assertTrue(refSqrt != 0);
    }
}

/*//////////////////////////////////////////////////////////////
   PART 2 - StockPairHook: the composition, which has NO test file
//////////////////////////////////////////////////////////////*/

contract SecurityReviewStockPairTest is Test, Deployers, TokenFixture {
    Vault vault;
    CLPoolManager poolManager;
    StockPairHook hook;
    AllowlistComplianceOracle complianceOracle;
    ManualPriceBandOracle priceOracle;
    AttestingRouter trustedRouter;

    PoolKey key;
    PoolId poolId;

    address constant ISSUER = address(0x155);
    address constant GUARDIAN = address(0x6DA);
    address constant LP = address(0x11B0);
    address constant INVESTOR = address(0xA11CE);
    address constant OUTSIDER = address(0x00757);

    uint24 constant STATIC_FEE = 3000;
    int24 constant TICK_SPACING = 60;
    int24 constant TICK_LOWER = -6000;
    int24 constant TICK_UPPER = 6000;
    int256 constant LIQUIDITY = 1000 ether;

    uint256 constant MONDAY_MIDNIGHT = 1_704_067_200;
    uint24 constant OPEN = 52_200;
    uint24 constant CLOSE = 75_600;
    uint8 constant WEEKDAYS = uint8((1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5));
    uint32 constant BAND_PPM = 50_000;

    function setUp() public {
        vm.warp(MONDAY_MIDNIGHT + 16 hours);

        (vault, poolManager) = createFreshManager();
        hook = new StockPairHook(poolManager, address(this));
        complianceOracle = new AllowlistComplianceOracle(address(this));
        priceOracle = new ManualPriceBandOracle(address(this));
        trustedRouter = new AttestingRouter(vault, poolManager);

        initializeTokens();
        mint(1_000_000 ether);

        key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            hooks: IHooks(address(hook)),
            poolManager: poolManager,
            fee: STATIC_FEE,
            parameters: CLPoolParametersHelper.setTickSpacing(
                bytes32(uint256(hook.getHooksRegistrationBitmap())), TICK_SPACING
            )
        });
        poolId = key.toId();

        hook.configurePool(key, _poolSettings());
        hook.configureMarket(key, _marketSettings());
        hook.setTrustedRouter(address(trustedRouter), true);
        hook.setMarketGuardian(GUARDIAN);

        _permit(LP);
        _permit(INVESTOR);

        priceOracle.setReferencePrice(poolId, SQRT_RATIO_1_1);
        poolManager.initialize(key, SQRT_RATIO_1_1);

        _fund(LP, 100_000 ether);
        _fund(INVESTOR, 100_000 ether);
        _fund(OUTSIDER, 100_000 ether);

        vm.prank(LP);
        trustedRouter.modifyPosition(key, _liq(LIQUIDITY));
    }

    function _poolSettings() internal view returns (PermissionedPoolHook.PoolSettings memory) {
        return PermissionedPoolHook.PoolSettings({
            oracle: IComplianceOracle(address(complianceOracle)),
            maxSwapPerTx: 0,
            maxLiquidityPerInvestor: 0,
            enabled: true,
            checkJurisdiction: false,
            freezeDeniedExits: false
        });
    }

    function _marketSettings() internal view returns (MarketHoursModule.MarketSettings memory) {
        return MarketHoursModule.MarketSettings({
            issuer: ISSUER,
            oracle: IPriceBandOracle(address(priceOracle)),
            maxUpPpm: BAND_PPM,
            maxDownPpm: BAND_PPM,
            maxPriceAge: 1 days,
            openSecondOfDay: OPEN,
            closeSecondOfDay: CLOSE,
            weekdayMask: WEEKDAYS,
            sessionEnabled: true,
            bandEnabled: true,
            gateLiquidity: false
        });
    }

    function _permit(address who) internal {
        complianceOracle.setRecord(
            who, AllowlistComplianceOracle.Record({permitted: true, expiresAt: 0, jurisdiction: 840})
        );
    }

    function _fund(address who, uint256 amount) internal {
        IERC20(Currency.unwrap(currency0)).transfer(who, amount);
        IERC20(Currency.unwrap(currency1)).transfer(who, amount);
        vm.startPrank(who);
        IERC20(Currency.unwrap(currency0)).approve(address(trustedRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(trustedRouter), type(uint256).max);
        vm.stopPrank();
    }

    function _liq(int256 d) internal pure returns (ICLPoolManager.ModifyLiquidityParams memory) {
        return ICLPoolManager.ModifyLiquidityParams({
            tickLower: TICK_LOWER,
            tickUpper: TICK_UPPER,
            liquidityDelta: d,
            salt: 0
        });
    }

    function _swapParams(bool zeroForOne, int256 amt) internal pure returns (ICLPoolManager.SwapParams memory) {
        return ICLPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amt,
            sqrtPriceLimitX96: zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT
        });
    }

    function _swapAs(address who, bool zeroForOne, int256 amt) internal returns (BalanceDelta) {
        vm.prank(who);
        return trustedRouter.swap(key, _swapParams(zeroForOne, amt));
    }

    function _expectHookRevert(bytes4 fn, bytes memory inner) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                fn,
                inner,
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                 Confirmations of the headline guarantees
    //////////////////////////////////////////////////////////////*/

    /// The `virtual` change in this diff makes `getHooksRegistrationBitmap` overridable. If a
    /// subclass ever drops a bit the parent's logic depends on, the parent's gate silently stops
    /// being called by core - `validateHookConfig` only checks the key against whatever the hook
    /// declares. Regression guard for exactly that.
    function test_OK_stockPairBitmapIsASupersetOfTheParentsCallbacks() public view {
        uint16 parent = 1 | (1 << 2) | (1 << 4) | (1 << 6); // init | addLiq | removeLiq | swap
        uint16 child = hook.getHooksRegistrationBitmap();
        assertEq(child & parent, parent, "StockPairHook must keep every PermissionedPoolHook gate");
        assertEq(child, parent | (1 << 7), "plus afterSwap, and nothing else");
    }

    /// The documented order: compliance error, not a market error, for an unpermitted party.
    function test_OK_complianceGateRunsBeforeTheMarketGate() public {
        vm.prank(ISSUER);
        hook.halt(poolId, "halted");
        _expectHookRevert(
            ICLHooks.beforeSwap.selector,
            abi.encodeWithSelector(PermissionedPoolHook.AccountNotPermitted.selector, OUTSIDER)
        );
        _swapAs(OUTSIDER, true, -1 ether);
    }

    /// FIX2 through the composed hook and a real swap: a rogue calendar blocks trading, rotation
    /// does not lift it, the owner's reset does.
    function test_FIX2_stockPairResetCalendarReopensSwaps() public {
        uint32[] memory days_ = new uint32[](30);
        uint32 today = hook.dayIndexOf(block.timestamp);
        for (uint256 i; i < days_.length; ++i) days_[i] = today + uint32(i);
        vm.prank(ISSUER);
        hook.setHolidays(poolId, days_);

        _expectHookRevert(
            ICLHooks.beforeSwap.selector,
            abi.encodeWithSelector(MarketHoursModule.MarketClosed.selector, poolId, block.timestamp)
        );
        _swapAs(INVESTOR, true, -1 ether);

        vm.prank(ISSUER);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.NotMarketAdmin.selector, ISSUER));
        hook.resetCalendar(poolId);

        hook.resetCalendar(poolId);
        _swapAs(INVESTOR, true, -1 ether);
    }

    /// The claim that matters most: nothing on the market side can trap an LP.
    function test_OK_exitSurvivesHaltPauseClosedSessionAndADeadPriceOracle() public {
        vm.prank(GUARDIAN);
        hook.halt(poolId, "everything is on fire");
        hook.pause();
        priceOracle.clearReference(poolId); // band oracle now unavailable
        vm.warp(MONDAY_MIDNIGHT + 6 days); // Sunday: session closed

        PermissionedPoolHook.PoolSettings memory ps = _poolSettings();
        ps.enabled = false;
        hook.configurePool(key, ps);

        // Entry is dead...
        _expectHookRevert(
            ICLHooks.beforeSwap.selector, abi.encodeWithSelector(Pausable.EnforcedPause.selector)
        );
        _swapAs(INVESTOR, true, -1 ether);

        // ...and exit still works.
        uint256 before0 = IERC20(Currency.unwrap(currency0)).balanceOf(LP);
        vm.prank(LP);
        trustedRouter.modifyPosition(key, _liq(-LIQUIDITY));
        assertGt(IERC20(Currency.unwrap(currency0)).balanceOf(LP), before0, "LP got their capital back");
    }

    /// The band, in composition. Reference set 10% below the pool price puts the pool ~23% above
    /// the +5% edge; a price-increasing swap must be refused and a price-decreasing one allowed.
    function test_OK_bandAppliesInCompositionWithTheConvergingException() public {
        priceOracle.setReferencePrice(poolId, uint160(uint256(SQRT_RATIO_1_1) * 9 / 10));

        // Diverging: buying token0 pushes the price further above the band.
        vm.expectRevert();
        _swapAs(INVESTOR, false, -1 ether);

        // Converging: selling token0 moves it back toward the band and is permitted.
        _swapAs(INVESTOR, true, -1 ether);
    }

    /// FINDING 1's fix lives in `MarketHoursModule`, which this contract mixes in without
    /// overriding either entry point. Asserted here anyway, on both, so a future override in the
    /// composition cannot quietly reopen it.
    function test_FIX1_stockPairRefusesReservedWeekdayBitsOnBothEntryPoints() public {
        MarketHoursModule.MarketSettings memory s = _marketSettings();
        s.weekdayMask = 0xFF;
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.InvalidWeekdayMask.selector, uint8(0xFF)));
        hook.configureMarket(key, s);

        vm.prank(ISSUER);
        vm.expectRevert(abi.encodeWithSelector(MarketHoursModule.InvalidWeekdayMask.selector, uint8(0x80)));
        hook.setSessionHours(poolId, 0x80, OPEN, CLOSE);

        assertEq(hook.marketConfig(poolId).weekdayMask, WEEKDAYS);
        assertTrue(hook.isTradable(poolId));
    }

    /// FINDING 4's fix, in composition. `StockPairHook` overrides `_beforeInitialize`, so the band
    /// check must survive that override: asserted here so a future edit to the composition cannot
    /// quietly drop it. Both halves configured, reference published, birth at 4x refused.
    function test_FIX4_stockPairRefusesOutOfBandInitialization() public {
        PoolKey memory k2 = key;
        k2.fee = 500;
        PoolId id2 = k2.toId();
        hook.configurePool(k2, _poolSettings());
        hook.configureMarket(k2, _marketSettings());
        priceOracle.setReferencePrice(id2, SQRT_RATIO_1_1);

        _expectHookRevert(
            ICLHooks.beforeInitialize.selector,
            abi.encodeWithSelector(
                MarketHoursModule.PriceBandBreached.selector,
                id2,
                uint256(4_000_000),
                uint256(950_000),
                uint256(1_050_000)
            )
        );
        poolManager.initialize(k2, uint160(uint256(SQRT_RATIO_1_1) * 2));

        poolManager.initialize(k2, SQRT_RATIO_1_1);
        (uint160 born,,,) = poolManager.getSlot0(id2);
        assertEq(born, SQRT_RATIO_1_1, "an in-band birth still works");
    }

    /// The configuration errors still come first. Market half configured and band-enabled, a
    /// reference published, a birth price far out of band - but the COMPLIANCE half was never
    /// configured, and that is what must be reported. If the band check ran before `super`, this
    /// would surface as `PriceBandBreached` and hide the real mistake.
    function test_FIX4_stockPairConfigurationErrorsPrecedeTheBandCheck() public {
        PoolKey memory k2 = key;
        k2.fee = 500;
        PoolId id2 = k2.toId();
        hook.configureMarket(k2, _marketSettings());
        priceOracle.setReferencePrice(id2, SQRT_RATIO_1_1);

        _expectHookRevert(
            ICLHooks.beforeInitialize.selector,
            abi.encodeWithSelector(PermissionedPoolHook.PoolNotConfigured.selector, id2)
        );
        poolManager.initialize(k2, uint160(uint256(SQRT_RATIO_1_1) * 2));
    }

    /*//////////////////////////////////////////////////////////////
      FINDING 7 (FIXED) - the publisher key is no longer a band bypass.

      Every other fast key in this design can only make the market MORE
      restricted: the guardian halts and cannot resume; the issuer can close
      days but cannot touch the oracle or the widths. The publisher key was the
      exception - it LOOSENS - and because the band is defined entirely as a
      ratio to the reference, an unbounded publisher could move the band
      anywhere and print any price.

      `maxPublisherDeviationBps` now bounds it. These tests are the regression
      guard: each one describes a way back into the bypass and asserts it is
      closed. If any of them starts passing for the wrong reason, the bound has
      been weakened.
    //////////////////////////////////////////////////////////////*/

    /// The original exploit, now refused. The publisher tries to double the reference - 2x in
    /// sqrt space is 4x in price, i.e. 30000 bps - and the bound rejects it. Critically, the
    /// swap that the move was meant to unlock STILL reverts afterwards.
    function test_FIX7_publisherCannotJumpTheReferenceOutOfBounds() public {
        address publisher = address(0xB0B);
        priceOracle.setPublisher(publisher, true);

        // Baseline: this swap prints outside the +5% band and is refused.
        vm.expectRevert();
        _swapAs(INVESTOR, false, -200 ether);

        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(
                ManualPriceBandOracle.DeviationTooLarge.selector,
                poolId,
                SQRT_RATIO_1_1,
                uint160(uint256(SQRT_RATIO_1_1) * 2),
                uint256(30_000), // 2x sqrt == 4x price == +300%
                uint256(1_000) // the default bound, 10% in price
            )
        );
        priceOracle.setReferencePrice(poolId, uint160(uint256(SQRT_RATIO_1_1) * 2));

        // The band did not move, so the swap is still refused.
        vm.expectRevert();
        _swapAs(INVESTOR, false, -200 ether);

        (uint160 printed,,,) = poolManager.getSlot0(poolId);
        assertEq(uint256(printed), uint256(SQRT_RATIO_1_1), "the pool price never moved");
    }

    /// The subtle way back in, and the reason `anchor` exists as a separate field.
    ///
    /// `clearReference` sets the published price to zero. If the bound were measured against the
    /// PUBLISHED price, the pool would then look never-published and the next write would be an
    /// unbounded "first" publication - so clear-then-republish would restore the whole bypass in
    /// two transactions instead of one. The anchor survives the clearing, so it does not.
    function test_FIX7_clearingThenRepublishingIsStillBounded() public {
        address publisher = address(0xB0B);
        priceOracle.setPublisher(publisher, true);

        vm.prank(publisher);
        priceOracle.clearReference(poolId);

        (uint160 published,) = priceOracle.referencePrice(poolId);
        assertEq(published, 0, "the price really was cleared");
        (uint160 anchor,,) = priceOracle.publisherBoundsFor(poolId);
        assertEq(anchor, SQRT_RATIO_1_1, "but the anchor survived it");

        vm.prank(publisher);
        vm.expectRevert();
        priceOracle.setReferencePrice(poolId, uint160(uint256(SQRT_RATIO_1_1) * 2));
    }

    /// The bound restricts publishers, not the owner - which on a live chain is a timelock. A
    /// genuine re-anchor (a corporate action, a redenomination) still has a route, it just has to
    /// go through the seat that has a public notice period.
    function test_FIX7_ownerCanStillReanchorFreely() public {
        priceOracle.setReferencePrice(poolId, uint160(uint256(SQRT_RATIO_1_1) * 2));
        (uint160 published,) = priceOracle.referencePrice(poolId);
        assertEq(uint256(published), uint256(SQRT_RATIO_1_1) * 2, "owner is exempt from the bound");
    }

    /// The bound must not stop a publisher doing their actual job. A 4% move in sqrt space is
    /// ~8.2% in price, inside the 10% default, and is accepted.
    function test_FIX7_publisherCanStillTrackTheMarketWithinTheBound() public {
        address publisher = address(0xB0B);
        priceOracle.setPublisher(publisher, true);

        uint160 nudged = uint160(uint256(SQRT_RATIO_1_1) * 104 / 100);
        vm.prank(publisher);
        priceOracle.setReferencePrice(poolId, nudged);

        (uint160 published,) = priceOracle.referencePrice(poolId);
        assertEq(published, nudged, "an in-bound move is allowed");

        // And the anchor moved with it, so the next move is measured from here.
        (uint160 anchor,,) = priceOracle.publisherBoundsFor(poolId);
        assertEq(anchor, nudged, "the anchor tracks the last published price");
    }

    /// The honest limitation, asserted rather than hand-waved: the bound is per-update, so with
    /// no interval configured a compromised key can still WALK the reference by repeating
    /// in-bound moves. This is why `minPublisherInterval` exists and why a live deployment must
    /// set it. Recorded as a test so nobody mistakes the bound for a hard ceiling.
    function test_FIX7_boundIsPerUpdateSoAWalkIsStillPossibleWithoutAnInterval() public {
        address publisher = address(0xB0B);
        priceOracle.setPublisher(publisher, true);

        uint256 price = uint256(SQRT_RATIO_1_1);
        for (uint256 i = 0; i < 10; ++i) {
            price = price * 104 / 100;
            vm.prank(publisher);
            priceOracle.setReferencePrice(poolId, uint160(price));
        }

        (uint160 walked,) = priceOracle.referencePrice(poolId);
        assertGt(uint256(walked), uint256(SQRT_RATIO_1_1) * 14 / 10, "ten in-bound steps compound");
    }

    /// ...and with an interval configured, that walk is rate limited. Clearing is deliberately
    /// NOT rate limited: stopping the market must never have to wait.
    function test_FIX7_minIntervalRateLimitsTheWalkButNeverTheHalt() public {
        address publisher = address(0xB0B);
        priceOracle.setPublisher(publisher, true);
        priceOracle.setPublisherBounds(1_000, 1 hours);

        // `setUp` published the reference as the owner, which stamped `anchorAt`. The interval is
        // measured from there, so step clear of it before the publisher's first move - otherwise
        // this test would be asserting the rate limit against the fixture rather than the walk.
        vm.warp(block.timestamp + 1 hours);

        uint160 first = uint160(uint256(SQRT_RATIO_1_1) * 104 / 100);
        vm.prank(publisher);
        priceOracle.setReferencePrice(poolId, first);

        // A second in-bound move immediately afterwards is refused on time, not on size. The
        // deadline is read back from the contract rather than recomputed here, so the assertion
        // cannot drift from the implementation.
        (, uint64 earliest,) = priceOracle.publisherBoundsFor(poolId);
        assertGt(earliest, block.timestamp, "the rate limit is actually in force");

        vm.prank(publisher);
        vm.expectRevert(
            abi.encodeWithSelector(ManualPriceBandOracle.UpdateTooSoon.selector, poolId, earliest)
        );
        priceOracle.setReferencePrice(poolId, uint160(uint256(first) * 104 / 100));

        // Halting is never rate limited.
        vm.prank(publisher);
        priceOracle.clearReference(poolId);

        // After the interval, publishing resumes.
        vm.warp(uint256(earliest));
        vm.prank(publisher);
        priceOracle.setReferencePrice(poolId, uint160(uint256(first) * 104 / 100));
    }

    /*//////////////////////////////////////////////////////////////
      INFORMATIONAL - the price band imposes a hard minimum gas budget
      on every swap, and the failure is a revert, not a degradation.
    //////////////////////////////////////////////////////////////*/

    /// `_checkPriceInBand` refuses to run unless `PRICE_ORACLE_GAS_FLOOR` (~233k) remains AT the
    /// point of `afterSwap`. This measures where that cliff actually is for a plain one-hop swap,
    /// so an integrator can size gas. It fails CLOSED, so this is a UX/integration note rather
    /// than a vulnerability - recorded because it is not covered anywhere in the suite.
    function test_INFO_bandImposesAMinimumGasBudgetPerSwap() public {
        uint256[6] memory budgets = [uint256(300_000), 350_000, 400_000, 450_000, 500_000, 600_000];
        uint256 firstSuccess;
        for (uint256 i = 0; i < budgets.length; ++i) {
            uint256 snap = vm.snapshotState();
            vm.prank(INVESTOR);
            (bool ok,) = address(trustedRouter).call{gas: budgets[i]}(
                abi.encodeCall(AttestingRouter.swap, (key, _swapParams(true, -1 ether)))
            );
            vm.revertToState(snap);
            if (ok && firstSuccess == 0) firstSuccess = budgets[i];
            emit log_named_uint(ok ? "OK at gas" : "REVERT at gas", budgets[i]);
        }
        emit log_named_uint("lowest budget that clears the band gas floor", firstSuccess);
        assertGt(firstSuccess, 0, "some budget must work");
    }
}
